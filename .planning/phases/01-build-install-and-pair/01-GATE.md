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

Dispatches used: 4. The plan's cap of three covered the first success; the fourth was approved by the user for the second.

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

## Not met: same final commit

The plan asks for both successful runs from the same commit. They are not:
- Run 3 built `b43c08c`. Run 4 built `f853aa1`.
- The only difference between the two commits is `01-GATE.md`. `project.yml`, the Swift sources and the workflow are identical.
- The two ipas have different SHA-256 values and differ by one byte, so the build output is not byte-for-byte reproducible.

Closing this strictly needs a rebuild from a commit that has no later changes. Not done, since it would cost another ~10 macOS minutes.

## Not verified

- The app's launch and behaviour on a phone (Plan 06). The ipa has not been installed.
