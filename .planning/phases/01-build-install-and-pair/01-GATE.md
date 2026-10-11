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

Dispatches used: 3 of 3. Any further dispatch needs an explicit decision.

## First success: run 38184064100

- Commit: b43c08c
- Run number (CFBundleVersion): 3
- Job wall time: 30 seconds (23:22:59 to 23:23:29 UTC)
- Billed estimate: 1 minute at the 10x macOS rate, so about 10 macOS minutes
- Artifact: `PhotoSync-ipa`, file `PhotoSync.ipa`, 197,121 bytes
- SHA-256: `db8de958469eb31b7c56a26fd0d769fa50ba5de371659acf8566b551cfaa4577`
- Contents: `Payload/PhotoSync.app/` with `PhotoSync`, `Info.plist`, `PkgInfo`. No provisioning profile.
- Download: `gh run download 38184064100 -n PhotoSync-ipa -D <dir>`

Checks inside the workflow (all passed on run 38184064100):
- Permission texts gate, and the `--built` plist check on the ipa's Info.plist
- CFBundleVersion equals the run number
- Exactly one `.app` at the top level, no embedded provisioning profile

## Not done

- **Second successful run from the same commit** (required by the plan). It needs a fourth dispatch, which would cost about 10 more macOS minutes. Not started; needs your go-ahead.
- Not verified: the app's launch and behaviour on a phone (Plan 06). The ipa has not been installed.
