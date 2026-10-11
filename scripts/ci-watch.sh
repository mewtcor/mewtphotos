#!/usr/bin/env bash
# Push (or dispatch) a workflow, then wait for its run and exit non-zero unless it succeeds.
# Usage: scripts/ci-watch.sh WORKFLOW_FILE [push | dispatch | steps REGEX [COUNT] | log REGEX]
# Exit: 0 success, 1 run failed, 2 uncommitted work, 3 no run appeared, 4 Mac dispatch not confirmed.
set -euo pipefail

FILE="${1:?usage: ci-watch.sh WORKFLOW_FILE [push|dispatch|steps REGEX [COUNT]|log REGEX]}"
MODE="${2:-push}"
SHA=$(git rev-parse HEAD)

die() { echo "$2" >&2; exit "$1"; }

# Planning and docs edits cannot change what CI tests, so they never block a push or a verify.
refuse_if_dirty() {
  git diff --quiet HEAD -- . ':(exclude).planning' ':(exclude)docs' \
    || die 2 "ci-watch: tracked changes are uncommitted; CI would test something other than your working tree. Commit first."
  local untracked
  untracked=$(git ls-files --others --exclude-standard -- .github ios scripts server shared tests web)
  [ -z "$untracked" ] || die 2 "ci-watch: untracked files would not be tested:
$untracked"
}

# Poll until a run for this commit exists (inspection modes use a short limit).
run_for_head() {
  local limit="$1" id="" waited=0
  while [ "$waited" -le "$limit" ]; do
    id=$(gh run list --workflow "$FILE" --commit "$SHA" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
    [ -n "$id" ] && { echo "$id"; return 0; }
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

watch_run() {
  local id="$1"
  if gh run watch "$id" --exit-status; then
    echo "$FILE run $id succeeded"
    exit 0
  fi
  gh run view "$id" --log-failed | tail -n 80 || true
  echo "$FILE run $id failed" >&2
  exit 1
}

case "$MODE" in
  push)
    refuse_if_dirty
    git push -u origin HEAD
    ID=$(run_for_head 120) || die 3 "ci-watch: no run appeared for $SHA. Check that Actions is enabled for the repository and that the push reached origin."
    watch_run "$ID"
    ;;
  dispatch)
    # A dispatch of a Mac workflow spends metered minutes, so it must be an explicit action.
    if grep -qiE 'mac[o]s' ".github/workflows/$FILE" && [ "${CONFIRM_MAC_DISPATCH:-}" != 1 ]; then
      die 4 "ci-watch: $FILE names a Mac runner; a dispatch spends metered minutes. Set CONFIRM_MAC_DISPATCH=1 to proceed. Nothing was pushed."
    fi
    refuse_if_dirty
    git push -u origin HEAD
    BEFORE=$(gh run list --workflow "$FILE" --branch main --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId // 0')
    # A workflow file pushed seconds ago is not always dispatchable yet.
    for i in $(seq 1 10); do
      gh workflow run "$FILE" --ref main && break
      [ "$i" -lt 10 ] || die 3 "ci-watch: gh workflow run $FILE kept failing"
      sleep 3
    done
    ID="" ; waited=0
    while [ "$waited" -le 120 ]; do
      ID=$(gh run list --workflow "$FILE" --branch main --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId // 0')
      [ "$ID" -gt "$BEFORE" ] && break
      ID=""; sleep 3; waited=$((waited + 3))
    done
    [ -n "$ID" ] || die 3 "ci-watch: no new run of $FILE appeared after dispatch"
    mkdir -p .ci-tmp
    echo "$FILE $ID" >> .ci-tmp/dispatches.log
    watch_run "$ID"
    ;;
  steps)
    REGEX="${3:?steps needs a REGEX}"; COUNT="${4:-}"
    ID=$(run_for_head 10) || die 3 "ci-watch: no run found for $SHA"
    ESC=${REGEX//\\/\\\\}; ESC=${ESC//\"/\\\"}
    OUT=$(gh run view "$ID" --json jobs --jq ".jobs[].steps[] | select(.name | test(\"$ESC\")) | \"\(.conclusion)\t\(.name)\"")
    [ -n "$OUT" ] || die 1 "ci-watch: no step matches /$REGEX/ in run $ID"
    echo "$OUT"
    N=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
    [ -z "$COUNT" ] || [ "$N" = "$COUNT" ] || die 1 "ci-watch: $N steps matched, expected $COUNT"
    BAD=$(printf '%s\n' "$OUT" | grep -v '^success' || true)
    [ -z "$BAD" ] || die 1 "ci-watch: matched steps that did not succeed:
$BAD"
    ;;
  log)
    REGEX="${3:?log needs a REGEX}"
    ID=$(run_for_head 10) || die 3 "ci-watch: no run found for $SHA"
    # Capture first: grep -q closing the pipe early would trip pipefail on gh.
    LOG=$(gh run view "$ID" --log)
    printf '%s\n' "$LOG" | grep -Eq "$REGEX" || die 1 "ci-watch: no log line matches /$REGEX/ in run $ID"
    ;;
  *) die 2 "ci-watch: unknown mode '$MODE'" ;;
esac
