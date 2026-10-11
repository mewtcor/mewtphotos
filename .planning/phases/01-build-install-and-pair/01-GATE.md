# Plan 01-05 gate: first unsigned build

## Billing baseline

- Actions budget: $0 with stop usage on (checked on GitHub, Budgets and alerts).
- Metered usage, Oct 1 to Oct 11 2026: billed $0 every day.
- macOS minutes used so far: not recorded. The Usage page shows dollars only. The user replied "ready" without a figure.

## Mac dispatches (cap: 3 to reach the first success)

| # | Run id | Conclusion | Failure cause |
|---|--------|------------|---------------|
| 1 | 38183925466 | failure | Packaging check: `wc -l` padding made the entry-count comparison fail on macOS |
| 2 | 38183995032 | failure | Same check, after a `grep -q` pipe change that did not address the cause |
| 3 | 38184064100 | success | Fix: trim `wc` output with `tr -d ' '` (commit b43c08c) |
| 4 | 38184483981 | success | Second success, from commit f853aa1 (see below) |
| 5 | 38184634926 | success | Same-commit pair, from commit 80b543d |
| 6 | 38184683733 | success | Same-commit pair, from commit 80b543d |

Dispatches used: 6. The plan's cap of three covered the first success; dispatch 4 was approved for a second success, and 5 and 6 were run to get two successes from one commit (see below). Runs 5 and 6 cost about 20 macOS minutes more than the single dispatch that had been approved.

## First success: run 38184064100

- Commit: b43c08c
- Run number (CFBundleVersion): 3
- Job wall time: 30 seconds (23:22:59 to 23:23:29 UTC)
- Billed estimate: 1 minute at the 10x macOS rate, so about 10 macOS minutes
- Artifact: `PhotoSync-ipa`, file `PhotoSync.ipa`, 150,065 bytes
- SHA-256: `db8de958469eb31b7c56a26fd0d769fa50ba5de371659acf8566b551cfaa4577`
- Contents: `Payload/PhotoSync.app/` with `PhotoSync`, `Info.plist`, `PkgInfo`. No provisioning profile.
- Download: `gh run download 38184064100 -n PhotoSync-ipa -D <dir>`

Checks inside the workflow (all passed on run 38184064100):
- Permission texts gate, and the `--built` plist check on the ipa's Info.plist
- CFBundleVersion equals the run number
- Exactly one `.app` at the top level, no embedded provisioning profile

## Second success: run 38184483981

- Commit: f853aa1 (the gate-record commit, not b43c08c)
- Run number (CFBundleVersion): 4
- Job wall time: 27 seconds (23:29:50 to 23:30:17 UTC)
- Billed estimate: 1 minute at the 10x rate, about 10 macOS minutes
- Artifact: `PhotoSync-ipa`, 150,066 bytes
- SHA-256: `2d91cd6f6d73597d7c4214565ddea45a4ae56777cdf494ea0b304eb196811d9d`
- Contents: same five entries as run 3.

## Same final commit: met (runs 5 and 6, both from 80b543d)

| Run | Run number | Commit | Job wall time | ipa bytes | SHA-256 |
|-----|-----------|--------|---------------|-----------|---------|
| 38184634926 | 5 | 80b543d | 28 s | 150,066 | `cc7e38f788ff6adebcdb4ef1c75887bdca3de7d8c69bb8966dc845d42281cc23` |
| 38184683733 | 6 | 80b543d | 28 s | 150,067 | `43376adefe35d058320af76604661f3c06ce9eab521302779378d1a4f77f543a` |

- Billed estimate per run: 1 minute at the 10× rate, about 10 macOS minutes each.
- Download either with `gh run download <run-id> -n PhotoSync-ipa -D <dir>`.
- The two ipas differ by one byte and have different checksums. The build is not byte-for-byte reproducible, though the contents are the same.
- Runs 3 and 4 (commits `b43c08c` and `f853aa1`) are kept above as history. Their only difference is `01-GATE.md`.

## Not verified

- The app's launch and behaviour on a phone (Plan 06). The ipa has not been installed.
