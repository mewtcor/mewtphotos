# Verify stored files

Verification re-reads every backed-up file from disk and compares it with the SHA-256 recorded when it was stored, reporting missing, corrupted and untracked files. It is available as the dashboard's `Verify now` button and as `npm run verify`.

## Sub-features

- `verify-pass` an intact backup reports every file OK.
- `verify-missing` a deleted file is reported missing.
- `verify-corrupt` a modified file is reported corrupted.

## How to get to it (user POV)

- Dashboard, section `Verify stored files`, button `Verify now`.
- Terminal: `npm run verify` (exit code 1 when problems are found).

## Driving it with the dashboard and the CLI

Preconditions: healthy instance with at least one stored file (run `vs.mjs upload`).

- **Pass.** `POST /api/v1/admin/verify` (or click `Verify now`). Status 202. Poll `GET /api/v1/admin/overview` until `verifyRunning` is false; `lastVerify` reports every file OK and no missing or corrupt entries. The dashboard section shows the result.
- **Corrupt.** Append a byte to the stored file inside `.verify/run/backup` (scratch folder only), run verify again. `lastVerify.corrupt` lists the file.
- **Missing.** Delete the stored file inside `.verify/run/backup`, run verify again. `lastVerify.missing` lists it.
- **CLI.** With the instance still up: `PHOTOSYNC_DATA_DIR=<state.data> npm run verify` (PowerShell: `$env:PHOTOSYNC_DATA_DIR='<state.data>'; npm run verify`). Output ends `Result: PASS` with exit code 0 for an intact backup and `Result: PROBLEMS FOUND` with exit code 1 after the corrupt or missing steps. Capture command, stdout, stderr and exit code.

## Gotchas

- Always set `PHOTOSYNC_DATA_DIR` to the scratch data dir for the CLI form, otherwise it checks the user's real backup database.
- Only damage files inside `.verify/run/backup`. Never edit anything under the user's real backup folder.
- Verification marks files that fail so later duplicate checks stop trusting them; relaunch for a clean state after the corrupt and missing steps.
- The CLI reads the same database the running server uses; run it between drives, not while an upload is in flight.
