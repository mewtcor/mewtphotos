# Phase 3 gate: PC server upgrades

Result: all four plans done and committed. `npm test` passes: 57 tests in 6 files (the 49 existing tests plus 8 new). `npm run typecheck` is clean.

## Requirements and evidence

| Req | What changed | Test |
|-----|--------------|------|
| SRV-01 | Live Photo parts share a stem and folder. The first part reserves the other part's name. | `tests/pairs.test.ts`: month boundary; name clash |
| SRV-02 | Hidden items go under `Hidden\YYYY\MM\`. | `tests/pairs.test.ts`: hidden vs ordinary |
| SRV-03 | "Already backed up" checks the file on disk at its recorded size, on `/assets/check` and `/files/:sha256`. | `tests/truthful.test.ts`: deleted and shortened file |
| SRV-04 | A resend in one session returns the existing record. No new row. Matched by hash, or by asset ID and size. | `tests/truthful.test.ts`: one row after a resend |
| SRV-05 | A failed final move returns the upload to `receiving`. A retry completes it. | `tests/resumable.test.ts` |
| SRV-06 | Numbered migration (`user_version`). Existing rows kept. | `tests/upgrade.test.ts` |
| SRV-07 | `GET /status` returns `freeBytes`. | `tests/upgrade.test.ts` |
| SRV-08 | The 49 existing tests pass unchanged. The Safari and Shortcut payloads are unchanged; new fields are optional. | full suite |

## Decisions to know about

- A re-announced known hash in the same session is reported as `duplicate`, as before. The record it points to may be `verified`.
- Hidden is decided per upload. If an item was first stored as ordinary and is later sent hidden, it counts as a duplicate and stays where it is.
- Live Photo naming: if the other part's name is taken, the first part moves to the next stem. If the second part cannot take the matching name, it fails with `pair_name_taken` and nothing is stored. A race that narrow is accepted.

## Not done here (the app side)

- The phone app does not yet send `hidden`, `pairId` or `pairName`. Phase 4 (pairing and the library scan) and Phase 5 (back up photos) add them.
- The app does not yet read `freeBytes`. Phase 5 adds the check before preparing a file.

## Decision

Phase 3 is complete on the PC side. Phase 4 can start.
