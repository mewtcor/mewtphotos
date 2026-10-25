---
phase: 01-build-install-and-pair
plan: 01
subsystem: infra
tags: [github-actions, ci, plist, altstore, vitest, bash, python]

requires: []
provides:
  - Private GitHub repository mewtcor/photosync, default branch main, source and package-lock.json tracked
  - ".github/workflows/ci.yml: typecheck on ubuntu-24.04, server vitest on windows-latest, hashFiles-guarded iOS steps"
  - "scripts/ci-watch.sh: push-and-wait, dispatch, steps and log inspection modes, Mac dispatch guard, dispatch log"
  - "ios/scripts/check_info_plist.py: Info.plist gate with 31 built-in negative controls"
  - "ios/MewtPhotos/Info.plist: checked-in app property list (usage texts, ATS local networking only, file sharing)"
affects: [01-02, 01-03, 01-04, 01-05, 01-06]

plan_head_before: 0bb36b60f9a0ef7b2472bd368c6776e3b9fa0149
plan_head_after: 34cadf88842569cf0066bbe93e4d7b735b3d2914

actuals:
  tokens: 9500
  tasks: 4
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Workflow owns its whole shape; later plans activate guarded steps by adding files (hashFiles)"
    - "Verify commands inspect a CI run by step or log line instead of dispatching again"

key-files:
  created:
    - .github/workflows/ci.yml
    - scripts/ci-watch.sh
    - ios/MewtPhotos/Info.plist
    - ios/scripts/check_info_plist.py
    - .gitattributes
  modified:
    - .gitignore

key-decisions:
  - "Server vitest suite runs on windows-latest, not Linux: tests/engine.test.ts asserts Windows case-insensitive filenames (contingency b)"
  - "Repository mewtcor/photosync, private, default branch main (confirmed by the user in Task 1)"
  - "ci-watch.sh dispatch mode filters runs with --event workflow_dispatch so a concurrent push run cannot be mistaken for the dispatched run"

requirements-completed: [BLD-01, BLD-02, BLD-03]

coverage:
  - id: D1
    description: "Source tracked in a private GitHub repo on main with package-lock.json committed"
    requirement: BLD-01
    verification:
      - kind: other
        ref: "gh repo view --json isPrivate (true); git ls-files package-lock.json; origin/main == HEAD"
        status: pass
    human_judgment: false
  - id: D2
    description: "Every push runs typecheck and the full vitest suite and the run concludes success"
    requirement: BLD-02
    verification:
      - kind: integration
        ref: "bash scripts/ci-watch.sh ci.yml (run 38166855693, success)"
        status: pass
    human_judgment: false
  - id: D3
    description: "Permission-text gate fails with the key named and proves its negative controls on every push"
    requirement: BLD-03
    verification:
      - kind: unit
        ref: "python ios/scripts/check_info_plist.py --self-test (SELF-TEST OK: 31 controls); CI steps Info.plist gate and Info.plist gate self-test success"
        status: pass
    human_judgment: false
  - id: D4
    description: "Swift test and contract-suite steps in ci.yml (guarded, skipped until Plan 02 adds Package.swift)"
    requirement: BLD-02
    verification: []
    human_judgment: true
    rationale: "These steps have never executed. They are skipped by hashFiles until Plan 02 adds the Swift package, so their YAML is unproven (swift on PATH, background server surviving between steps)."

duration: 15min (this session; the earlier session's time is not recorded)
completed: 2026-10-12
status: complete
---

# Phase 1 Plan 01: CI loop and Info.plist gate Summary

**Private GitHub repo with a green push-triggered CI (typecheck on Linux, server vitest on Windows), a push-and-wait script that cannot dispatch a Mac build by accident, and an Info.plist gate that proves its own negative controls on every push.**

## Performance

- **Duration:** about 15 min in this session (earlier session not timed)
- **Completed:** 2026-10-11T19:11:18Z (shell clock, UTC)
- **Tasks:** 4 of 4
- **Files modified:** 6 (5 created, .gitignore appended)

## Accomplishments

- Source, tests, docs and lockfile are tracked and pushed to the private repo `mewtcor/photosync`; `main` is the default branch and equals local HEAD.
- `ci.yml` runs on every push with no path filter. Final push run for the plan HEAD: 38166855693, success, including the two plist steps. A manual dispatch run, 38166713569, also succeeded and is recorded in `.ci-tmp/dispatches.log`.
- `check_info_plist.py` rejects missing, empty, whitespace-only or non-text usage strings, a widened or missing ATS exception, unset file-sharing keys, non-ASCII app names and unreadable files (one ERROR line, no traceback); `--built` and `.ipa` input work.
- Every iOS-specific step (static checks, swiftc parse, real server, swift test, contract witness) is already in `ci.yml` behind `hashFiles`, so later plans add files rather than editing YAML.

## Task Commits

1. **Task 1: Workflow scope and repo name/privacy** - no commit (done by the user; `gh auth status` lists workflow, repo `mewtcor/photosync` private)
2. **Task 2: Track source and publish** - `0fb321e` (feat, source tracked), `0bb36b6` (chore, .gitignore additions and .gitattributes)
3. **Task 3: CI workflow and ci-watch.sh** - `2c3dc7d` (feat), `06d1a29` (fix, vitest to windows-latest)
4. **Task 4: Info.plist and gate** - `34cadf8` (feat)

**Plan metadata:** recorded in the docs commit that follows this file.

`commits: 3` and `plan_head_before` are measured from the ledger created when this session made its first commit, so the two Task 2 commits (made earlier) are not in that count; five commits belong to the plan in total.

## Run ids

| Run | Event | Commit | Result |
| --- | ----- | ------ | ------ |
| 38166528575 | push | 2c3dc7d | failed: tests/engine.test.ts case-insensitive filename test on Linux |
| 38166611637 | push | 06d1a29 | success (iOS steps skipped) |
| 38166713569 | workflow_dispatch | 06d1a29 | success (logged in .ci-tmp/dispatches.log) |
| 38166855693 | push | 34cadf8 | success; Info.plist gate and self-test steps success |

Push-and-fix iterations used: 1 of 4. No Mac runner was dispatched.

## Verification results

- `npm run typecheck` and `npm test` (49/49) on this PC: pass (Task 2 baseline, earlier session).
- `gh repo view --json isPrivate`: true; `git ls-files package-lock.json`: tracked; branch main; `git ls-remote origin refs/heads/main` equals HEAD (34cadf8): pass.
- `bash scripts/ci-watch.sh ci.yml`: exit 0, "ci.yml run 38166855693 succeeded".
- Dispatch log check (`grep '^ci.yml ' .ci-tmp/dispatches.log`, run 38166713569 conclusion): success.
- `python ios/scripts/check_info_plist.py ios/MewtPhotos/Info.plist`: "OK ... 9 checks passed"; `--self-test`: "SELF-TEST OK: 31 controls".
- `--built` on the source plist: exit 1; three-space NSLocalNetworkUsageDescription: exit 1 naming the key; empty file: exit 1, "not a readable plist", no traceback.
- `bash scripts/ci-watch.sh ci.yml steps '^Info.plist gate' 2`: exit 0, both steps success.
- Task 3 acceptance greps (ubuntu-24.04, cancel-in-progress, contents: read, no paths/paths-ignore, no --filter, Contract Test witness, actions/* only, no macos, CONFIRM_MAC_DISPATCH, dispatches.log): all pass. Mac dispatch guard against a dummy macos workflow exits 4 and pushes nothing.

## Decisions Made

- Server vitest moved to a `server-tests` job on `windows-latest` (contingency b). One test, `keeps both files when the same filename has different contents` in `tests/engine.test.ts`, uploads `image.jpg` and `IMAGE.JPG` and expects Windows case-insensitive collision handling; on Linux the two names are distinct files. The test belongs to the Windows product and was not changed. Cost: that job runs at 2x minutes (about 30 s per run so far).
- `ci-watch.sh dispatch` selects runs with `--event workflow_dispatch`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Vitest fails on Linux (Open Question 3 realised)**
- **Found during:** Task 3, first CI run (38166528575)
- **Issue:** 48 of 49 tests pass on ubuntu-24.04; the case-insensitive filename test fails.
- **Fix:** Plan contingency (b): removed the Server tests step from the Linux `checks` job and added a `server-tests` job on `windows-latest`. Typecheck and all guarded iOS steps stay on Linux. A comment in `ci.yml` records the reason.
- **Files modified:** `.github/workflows/ci.yml`
- **Commit:** `06d1a29`

**2. [Rule 1 - Bug] Dispatch run detection could pick up a push run**
- **Found during:** Task 3 review of the previous session's `ci-watch.sh`
- **Issue:** the "newest run on main" lookups did not filter by event, so a push run started by the same command could be recorded as the dispatched run.
- **Fix:** added `--event workflow_dispatch` to both lookups.
- **Files modified:** `scripts/ci-watch.sh`
- **Commit:** `2c3dc7d`

### Plan-process deviations

- **Task 2 commits differ from the plan.** The source was tracked earlier, at the user's direct request, with one `git add -A` commit (`0fb321e`, message "feat: add Mewt Photos Windows server and web UI") instead of the plan's explicit-path commit and message. The `.gitignore` and `.gitattributes` changes followed in `0bb36b6`. All Task 2 verify commands and the leak scan still passed. The user, not the executor, pushed `main` the first time, switched the default branch to `main` and deleted the old remote `master` branch.
- **Task 3 ran with `ios/` temporarily moved out of the tree.** `ci-watch.sh` refuses to push while untracked files exist under `ios/`, and the Task 4 files already existed untracked. They were moved to the scratchpad (plain `mv`, nothing deleted), the Task 3 verify ran, and they were moved back. This kept the "guarded iOS steps skipped" acceptance criterion testable.
- **Task 4 TDD gate.** The plan puts the negative controls (`--self-test`) and the implementation in one file and one commit, so there are no separate RED and GREEN commits. The controls were exercised against the implementation (31 controls passing, plus manual spot checks of whitespace, empty file and `--built`).
- **Commit guard.** The pre-commit assertion refused commits on `main`; the user chose to allow it and `git.allow_default_branch_commits` was set to true in `.planning/config.json`.

**Total deviations:** 2 auto-fixed (1 blocking, 1 bug), 4 process notes. **Impact:** none on scope; one CI job runs on a Windows runner instead of Linux.

## Auth gates

Task 1 was the planned `human-action` checkpoint (workflow scope for the gh token, repo name and privacy). It completed before this session. No further gates.

## Known Stubs

None.

## Known gaps carried forward

- The guarded Swift steps (`Add Swift to PATH`, `Parse app sources`, `Start the real server`, `swift test`, `Contract suite reached the server`) are skipped and have never run. Plan 02 is where they first execute; the background server surviving across steps and `swift` being on PATH are unproven.
- Actions `checkout@v7` and `setup-node@v7` resolved and ran fine.

## Threat Flags

None. No network endpoints, auth paths or schema changes were added; `permissions: contents: read` and `actions/*` only are in place (T-01-02), the repo is private (T-01-01).

## Self-Check: PASSED

- Files present: `.github/workflows/ci.yml`, `scripts/ci-watch.sh`, `ios/MewtPhotos/Info.plist`, `ios/scripts/check_info_plist.py`, `.gitattributes`.
- Commits reachable from HEAD: `0fb321e`, `0bb36b6`, `2c3dc7d`, `06d1a29`, `34cadf8`; origin/main equals 34cadf8.
