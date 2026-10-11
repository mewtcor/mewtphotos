# Codebase Concerns

**Analysis Date:** 2026-10-11

Scope: full repository (`server/`, `shared/`, `web/src/`, `tests/`, `scripts/`, `docs/`, config). Verified state at analysis time: `npx tsc --noEmit` passes and `npx vitest run` passes (49 of 49 tests). Items marked *from code reading* were not reproduced by a test.

## Known Bugs

**Upload stuck in `finalizing` when the rename or cross-drive copy fails:**
- Symptoms: the failed file never reaches `failed` or `receiving`. Retries from the phone return 409 `not_receiving` ("This upload is finalizing"). The dashboard counts it as in progress indefinitely, and `npm run verify` reports "upload(s) are stuck mid-save; restart the server". The status clears only on the next app restart.
- Files: `server/engine.ts` (`place()` at lines 330-346 sets `status = 'finalizing'` and then calls `rename`/`copyFile`; `finishUpload()` at lines 381-385 catches and classifies the error without resetting status; `sessionSummary()` at line 449 counts `finalizing` as in progress)
- Trigger: any non-EXDEV error from `rename` (antivirus or OneDrive lock, `EPERM`, `EACCES`) or a failed copy-and-verify after a move to another drive. *From code reading; no test covers it. `tests/engine.test.ts` has no rename-failure or EXDEV case.*
- Workaround: restart the app. `recover()` (engine.ts:401-416) then rolls the record back to `receiving`.
- Fix: in `place()`, wrap the rename/copy block so that on failure it removes any partial `target`, sets the upload back to `receiving` (the temp file still exists), and rethrows. Add a test that forces `rename` to fail.

**Dashboard settings form loses unsaved edits on every refresh:**
- Symptoms: while a backup runs, `change` events arrive constantly. Each one reloads `/admin/overview`, which produces a new `settings` object. `useEffect(() => setDraft(settings), [settings])` then overwrites whatever the user typed. The 60-second poll does the same when idle.
- Files: `web/src/Dashboard.tsx` (line 68 resets the draft; lines 122-127 set new `data`; lines 145-148 refresh on each `change`)
- Fix: reset the draft only when the form is not dirty, or only when the saved values differ from the last saved snapshot.

**Phone page drops the previous batch's failed and cancelled items:**
- Symptoms: choosing more photos after a partial run replaces the whole list. Items that failed or were cancelled earlier vanish from the phone UI and cannot be retried from there. They remain only in the PC dashboard's "Failed uploads" table.
- Files: `web/src/Phone.tsx` (line 234: `items.current = files.map(...)`; `retryFailed()` at lines 238-242 only sees the current list)
- Fix: append the new items to the existing list, or keep an unfinished-items queue that survives a new pick.

**`/assets/check` answers "known" from the database alone:**
- Symptoms: a file deleted from the backup folder after its last verification still counts as known, so the phone skips re-sending it. Only the next "Verify now" run would notice. The one-shot `/files/:sha256` route, by contrast, does check the file on disk.
- Files: `server/app.ts` (`/assets/check` at lines 320-328, `verify_status`-only check and `status IN ('verified','duplicate')` for `assetId`; compare `/files/:sha256` at lines 310-317, which stats the path)
- Fix: for each item, resolve the stored `files.path` and compare its size with `stat`, as `/files/:sha256` does. Document the same semantics in `docs/api.md`.

**Crash recovery can delete a file it did not write:**
- Symptoms: if the temp file still exists and the record is `finalizing`, `recover()` removes whatever sits at `final_path` without comparing hashes. A file placed in that path by hand during the crash window would be deleted.
- Files: `server/engine.ts` (lines 404-407)
- Trigger: rare (requires a crash plus a manual copy into the same name). *From code reading.*
- Fix: remove `final` only if its hash equals `upload.sha256`.

**Recovered records lose their capture date:**
- Files: `server/engine.ts` (line 411 passes `null` capture and `'received'` as the date source when committing a recovered file)
- Impact: the folder choice and `date_source` are wrong for recovered files. Low severity.

**Upload loop can spin forever on `upload_busy`:**
- Files: `web/src/uploader.ts` (lines 127-131: `attempt--; continue` with no cap)
- Impact: the upload stays "Verifying on PC" until the user cancels. Add a cap, such as 10 minutes.

**XHR success path can hang on malformed JSON:**
- Files: `web/src/uploader.ts` (line 45: `JSON.parse(xhr.responseText)` inside `onload` with no try/catch, so the promise never settles)
- Impact: low; only if the server returns non-JSON with status 200.

## Security Considerations

**Device key travels over plain HTTP:**
- Risk: the bearer token is sent unencrypted on the LAN for every request. Anyone who can sniff the Wi-Fi can capture it and upload to the backup until the device is revoked.
- Files: `server/app.ts` (`requireDevice`, lines 164-171), `server/main.ts` (line 68 prints the warning), `web/src/Phone.tsx` (`ShortcutSetup`, line 102, displays the key on screen), `web/src/api.ts` (lines 18-28, key in `localStorage`)
- Current mitigation: the README and dashboard disclose it; key is stored hashed on the PC; device removal is possible in the dashboard.
- Recommendations: keep the disclosure; consider showing the key only on request; consider TLS with a locally trusted certificate if the QR flow can tolerate it.

**Dashboard can be framed (clickjacking):**
- Risk: the dashboard actions (Stop backup app, Remove device, Save settings, Verify now) can be triggered through a transparent iframe. The framed request carries the same origin and the loopback address, so the existing Origin, Host and loopback checks pass.
- Files: `server/app.ts` (security headers in the `onRequest` hook, lines 159-161, set `content-security-policy` but no `frame-ancestors`, `x-frame-options`)
- Recommendations: add `frame-ancestors 'none'` to the CSP and `x-frame-options: DENY` in the same hook. Whether a browser lets a public page frame `127.0.0.1` was not verified.

**Dashboard has no authentication:**
- Risk: any process or user account on the PC can call `/api/v1/admin/*`. This is disclosed in `README.md` ("anyone logged into the PC can open the dashboard").
- Files: `server/app.ts` (`requireAdmin`, lines 174-185)
- Recommendation: accept as a known gap, or add a per-launch admin token passed in the dashboard URL fragment.

**Pairing throttle is keyed only by IP:**
- Risk: IPv6 address rotation can evade the 8-attempts-per-5-minutes limit. The 8-character code (about 8.5e11 combinations, valid 10 minutes) keeps this low-risk.
- Files: `server/security.ts` (`Pairing.consume`, lines 89-104)

**Any writable absolute path is accepted as the backup folder:**
- Risk: a local admin request can point the backup at a system folder, such as `C:\`. The probe write only proves writability.
- Files: `server/config.ts` (`validateDestination`, lines 47-59)
- Recommendation: refuse paths under `%SystemRoot%` and `%ProgramFiles%`.

**Untrusted files are parsed in-process:**
- Risk: `exifreader` and the QuickTime atom walker run on uploaded bytes inside the server process. Errors are swallowed (`server/metadata.ts` line 89), but a crafted file could still cause a crash or heavy CPU use.
- Files: `server/metadata.ts` (EXIF reads up to 1 MB at lines 15 and 25; atom walk at lines 38-82), `server/engine.ts` (line 373)
- Recommendation: keep the try/catch, and consider running metadata reads in a worker thread.

## Performance Bottlenecks

**Full re-hash of the existing copy on every duplicate check:**
- Problem: a sender that announces a hash for content already stored makes the server read and hash the whole stored file to confirm it is intact. The same happens for each duplicate placed after upload.
- Files: `server/engine.ts` (`fileIntact()` lines 55-58, called from `createUpload()` line 136 and `place()` line 288)
- Cause: intact-ness is re-proved on every use instead of trusting the last verification.
- Improvement path: trust `verify_status` plus a size and mtime match, and rely on `npm run verify` for full checks. At minimum, cache the last full hash by path, size and mtime.

**One large duplicate blocks all placements:**
- Problem: `place()` runs inside the `serialize()` queue, and its first step is the full re-hash in `fileIntact()`. A multi-GB duplicate therefore delays every other file's commit.
- Files: `server/engine.ts` (`serialize()` lines 249-254; call at line 378; `fileIntact()` at line 288)
- Improvement path: move `fileIntact()` out of the queue. Serialize only the duplicate-name choice and the database commit.

**Verification commits and reports once per file:**
- Problem: each `UPDATE files` is its own autocommit transaction. With `synchronous=FULL`, that means one fsync per file. Each file also emits an SSE `verify` event. The run cannot be cancelled, and closing the dashboard does not stop it, because `stopIfDashboardGone()` waits while `verifyRunning` is set.
- Files: `server/verify.ts` (line 24 per-file update; line 26 progress callback), `server/app.ts` (line 384 emits per file; `verifyRunning` gate at line 411)
- Improvement path: batch updates in one transaction (`tx()` in `server/db.ts`), throttle progress events to about once per second, and add a cancel route.

**Verification report is stored whole and returned on every poll:**
- Problem: `missing` and `corrupt` arrays are unbounded (only `untracked` is capped at 200). The whole report is JSON-stored in the settings row and parsed in every `/admin/overview` call. Overview runs every 60 seconds and on every `change` event.
- Files: `server/verify.ts` (line 8 cap applies only to `untracked`; line 52 stores the report), `server/app.ts` (line 336 read, line 355 parse, line 355 returned)
- Improvement path: cap the lists at a few hundred entries, and record the full list in a table.

**Dashboard overview runs full-table aggregates on each refresh:**
- Files: `server/app.ts` (lines 341-347 `SUM(size)` and `COUNT(*)` over `files` and `uploads`; line 351 `sessionSummary` for 30 sessions)
- Impact: acceptable today; grows with library size. Cache the totals and update them on commit.

**Phone hashes every selected file in JavaScript before sending:**
- Problem: the check is on by default. Pure-JS SHA-256 runs in Safari over every selected file, including multi-GB videos, before any bytes are sent, with no network progress during that phase.
- Files: `web/src/uploader.ts` (lines 62-77), `shared/sha256.ts`, `web/src/Phone.tsx` (checkbox default `useState(true)`, line 112)
- Impact: unknown on a real iPhone. The README lists iPhone behaviour as untested. Measure before relying on it for large libraries.

## Fragile Areas

**Upload state machine spread across three functions:**
- Files: `server/engine.ts` (`createUpload`, `place`, `finishUpload`, `recover`), with status strings written in SQL in `server/engine.ts`, `server/app.ts` and `server/db.ts`
- Why fragile: status transitions (`receiving` -> `finalizing` -> `verified`/`failed`/`duplicate`, plus `retried`, `cancelled`, `expired`) are not enforced in one place. The stuck-`finalizing` bug above is a direct result.
- Safe modification: change statuses only through a single helper that checks the allowed transition. Add tests for each failure path of `place()` before changing it.
- Test coverage: rename failure, EXDEV copy, and destination change during a transfer are not tested.

**Destination changes leave transfer state behind:**
- Files: `server/app.ts` (`PUT /admin/settings` lines 368-378), `server/engine.ts` (`recover()` orphan cleanup lines 425-431 scans only the current `.incoming`), `server/verify.ts` (line 49 walks only the current destination)
- Why fragile: `.part` files left in the old folder are never removed; `verify` reports untracked files only for the new folder. Partial uploads keep working because `temp_path` is absolute, but the cleanup is incomplete.
- Safe modification: scan every distinct destination recorded in `uploads.temp_path`, or refuse destination changes while uploads are `receiving`.

**Schema has no migrations:**
- Files: `server/db.ts` (`SCHEMA` lines 5-74, `CREATE ... IF NOT EXISTS` only; `openDb()` lines 76-82)
- Why fragile: any future column or constraint change needs a manual migration. The `settings` row is a JSON blob merged with defaults on read (`server/config.ts` lines 33-40) without validation of stored values.
- Safe modification: add a `PRAGMA user_version` check and numbered migration steps before the first schema change.

**Server runs TypeScript directly through Node's type stripping:**
- Files: `package.json` (`start`, `verify` scripts), `scripts/start-backup.ps1` (line 46), `tsconfig.json` (`erasableSyntaxOnly: true`)
- Why fragile: the start-up path depends on Node 22.18+ type stripping. `erasableSyntaxOnly` prevents enums and parameter properties, so the constraint is enforced by the typechecker. Keep both in place.

**Experimental SQLite API, with warnings suppressed:**
- Files: `server/db.ts` (line 1 imports `node:sqlite`), `package.json` (`--disable-warning=ExperimentalWarning` in `start` and `verify`)
- Why fragile: `node:sqlite` is marked experimental, and the warning is hidden. A Node upgrade could change behaviour without a visible signal. The pinned `engines` minimum (22.18) is the only guard.

**Test seams are mutable module globals:**
- Files: `server/engine.ts` (`timeouts`, line 33), `server/app.ts` (`autoStop`, lines 28-35), used in `tests/engine.test.ts` (lines 305-313, 585-586, 592, 609-615, 630)
- Why fragile: tests mutate and then restore these values. A test that fails before restoring them leaks timing changes into later tests in the same file.

**OneDrive-redirected Pictures folder as the default backup target:**
- Files: `server/config.ts` (`picturesDir()` lines 17-31 uses PowerShell to read the Pictures known folder, which may be OneDrive-redirected; default destination set at line 37)
- Why fragile: OneDrive Files On-Demand can turn stored files into placeholders. Re-hashing or verifying them can trigger downloads or fail with `EPERM` (classified as `permission_denied`). *From code reading; not tested on a OneDrive-enabled machine.*
- Safe modification: detect the OneDrive root and warn in the dashboard, or recommend a non-synced folder.

**Hard-coded Windows behaviour:**
- Files: `server/main.ts` (`cmd /c start` at line 16), `server/config.ts` (`powershell.exe` at line 20, synchronous on first run, blocking the event loop for up to 15 seconds), `server/security.ts` (virtual-adapter regex at line 55)
- Impact: the app is Windows-only by design. The synchronous PowerShell call runs once, during first-run settings creation.

## Scaling Limits

**Per-upload space and quota checks are not reserved:**
- Current capacity: concurrency of 2 by default (`shared/schemas.ts` `Settings.concurrency`), up to 6.
- Limit: parallel large uploads can overshoot the free-space floor or the quota by up to (concurrency - 1) files.
- Scaling path: reserve in-flight sizes in `createUpload` (the trade-off is noted in a `ponytail:` comment at `server/engine.ts` lines 160-162).

**Log table pruned only at start-up:**
- Files: `server/app.ts` (line 115 keeps the last 5000 rows, run once per start)
- Limit: a long-running session grows the table between restarts. The log file `server.log` is never rotated (`README.md` lines 121-123, disclosed).

**Single-writer, single-process design:**
- Files: `server/engine.ts` (`ctx.active` and `ctx.placing` are in-memory)
- Limit: two instances against one database are prevented only by the port check in `server/main.ts` (lines 20-31). By design, but a second process started with a different `PHOTOSYNC_PORT` would share the database and could corrupt in-flight state.

**Only a single copy of each backed-up file:**
- Files: `server/verify.ts` (detects missing and corrupt files; no repair)
- Limit: there is no second copy. Recovery depends on re-sending from the iPhone, which still holds the originals.

## Dependencies at Risk

**`@types/node` major version is ahead of the runtime minimum:**
- Risk: `package.json` pins `@types/node` `^26.6.5` while `engines.node` is `>=22.18`. Typechecking against Node 26 typings can pass with APIs that do not exist on Node 22.18, which would fail only at run time.
- Files: `package.json` (lines 8 and 28)
- Migration plan: align `@types/node` with the minimum supported Node major, and run `npm run typecheck` against it.

**`node:sqlite` is experimental:**
- Risk: API or behaviour changes in future Node releases. Already disclosed in `README.md` (architecture decisions table).
- Files: `server/db.ts`

**No git history for the project:**
- Risk: `git status` shows the whole project as untracked, and the repository has no commits. `package-lock.json` is also untracked, so dependency resolution cannot be reproduced from version control.
- Files: repository root (`.gitignore`, `package-lock.json`)
- Migration plan: make an initial commit that includes the lockfile, then keep `web/dist/` ignored (already in `.gitignore`).

**Build artifact can go stale:**
- Risk: `scripts/start-backup.ps1` builds the web bundle only when `web/dist/index.html` is missing (lines 38-42). Edits to `web/src/` are not picked up by the launcher.
- Files: `scripts/start-backup.ps1`, `web/dist/` (built output present at analysis time)
- Fix: rebuild when any `web/src` file is newer than `web/dist/index.html`, or always run `vite build` before start.

## Missing Critical Features

**No automated test runs against a real iPhone:**
- Problem: Safari picker behaviour, HEIC-to-JPEG conversion, background suspension, and Shortcuts are all untested. `README.md` line 36 says so, and `docs/iphone-test-checklist.md` lists the manual steps.

**No cancel for verification:**
- Problem: once started, "Verify now" runs to completion and blocks the app from stopping (see Performance above).

**No schema migration path:**
- Problem: see Fragile Areas. Blocks any future change to the `files`, `uploads` or `settings` tables without manual surgery.

**No backup-folder health check at start-up beyond writability:**
- Problem: the app does not check free space, OneDrive state, or antivirus locks before the first upload. Failures appear only mid-transfer as `insufficient_space` or `permission_denied`.

## Test Coverage Gaps

**Browser client is untested:**
- What's not tested: `web/src/Phone.tsx`, `web/src/Dashboard.tsx`, `web/src/uploader.ts` (offset-mismatch recovery, retry backoff, `upload_busy` loop), `web/src/api.ts`.
- Files: `tests/` contains only `engine.test.ts`, `units.test.ts` and `helpers.ts`.
- Risk: client-side regressions, such as the settings reset and the batch-replacement bugs above, go unnoticed.
- Priority: High.

**Failure paths of `place()` are untested:**
- What's not tested: `rename` failing with a non-EXDEV error, the cross-drive copy path (`copyFile` plus `syncFile` plus hash check), and the hash-mismatch branch after copy.
- Files: `server/engine.ts` (lines 333-345), `tests/engine.test.ts`
- Risk: the stuck-`finalizing` bug ships unnoticed.
- Priority: High.

**`/assets/check` disk-presence semantics are untested:**
- What's not tested: a deleted backup copy, still listed as verified, is reported as known.
- Files: `server/app.ts` (lines 320-328); compare `tests/engine.test.ts` line 99-109 which covers `/files/:sha256` only.
- Risk: silent skipped backups.
- Priority: High.

**Destination change during active transfers is untested:**
- What's not tested: a `receiving` upload whose temp file is in the old folder, finished after a destination change, including cross-drive placement.
- Files: `server/app.ts` (lines 368-378), `server/engine.ts` (lines 425-431).
- Priority: Medium.

**Start-up and launcher are untested:**
- What's not tested: `server/main.ts` (port-in-use message, existing-instance detection, start-up recovery order) and `scripts/start-backup.ps1`.
- Priority: Medium.

**Memory assertion is environment-dependent:**
- What's not tested: the bounded-memory check (`tests/engine.test.ts` lines 340-351) compares RSS growth against 64 MB. Garbage-collector timing can make it flaky on other machines.
- Priority: Low.

**Stale reference in a comment:**
- Files: `shared/sha256.ts` (line 3) says the check lives in `tests/sha256.test.ts`. That file does not exist; the SHA-256 tests are in `tests/units.test.ts` (lines 8-24).
- Fix: update the comment.

## Technical Debt

**Speculative API fields:**
- Files: `shared/schemas.ts` (`libraryCount` in `SessionCreate` line 23 and `SessionSummary` line 101; `libraryCoverageVerified: false` at line 112 is always false; `apiVersion` in `server/app.ts` line 202)
- Impact: fields kept for a future native client that is only at the roadmap stage (`docs/ROADMAP_IOS_COMPANION.md`). Keep only if that milestone is active; otherwise remove.

**Raw error codes shown to the user:**
- Files: `web/src/Dashboard.tsx` (line 233 shows `f.error` directly, for example `lost_during_finalize`, `hash_mismatch`, `expired`)
- Impact: the failure table is hard to act on. Map codes to the human messages already used in `docs/troubleshooting.md`.

**Single large component files:**
- Files: `web/src/Phone.tsx` (365 lines, one component containing upload orchestration, state and rendering), `web/src/Dashboard.tsx` (274 lines)
- Impact: orchestration is hard to test in isolation. Move the worker loop into a hook or plain module (for example `web/src/uploader.ts`, which already owns the transfer logic).

**Unvalidated session counter on one-shot uploads:**
- Files: `server/app.ts` (line 289 increments `selected_count` before `createUpload` validates the file)
- Impact: rejected files (unsupported type, too large) are counted as selected and reported as "never reached this computer". Accurate, but the counter is incremented before the file is checked. Low.

**Orphan `.part` file cleanup covers only the current folder:**
- See Fragile Areas (destination changes).

---

*Concerns audit: 2026-10-11*
