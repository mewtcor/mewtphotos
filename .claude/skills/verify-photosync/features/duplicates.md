# Duplicates and incremental check

Content the PC already holds intact is never stored twice. A phone can ask what the PC already has before it sends anything, and a repeat is reported as `duplicate`, which counts as safely backed up.

## Sub-features

- `dup-announce` creating an upload with a known `sha256` returns `duplicate` and transfers nothing.
- `dup-count` the duplicate shows in the session and on the dashboard as `Duplicates skipped`.
- `dup-lookup` `GET /files/<sha256>` says whether a hash is stored and intact.
- `dup-assets` `POST /assets/check` answers per item for a batch.

## How to get to it (user POV)

- The iOS app and phone page skip files the PC already has by calling these endpoints before uploading.
- The PC user sees `Duplicates skipped` on the dashboard.

## Driving it with the phone API on loopback

Preconditions: paired device and one file already stored (run `vs.mjs upload`, or store a file yourself and keep its SHA-256).

- **Known hash.** `GET /api/v1/files/<sha256>`. Response `{"known":true,"status":"stored","path":"..."}`. For a hash never uploaded: `{"known":false,"status":"missing"}`.
- **Batch check.** `POST /api/v1/assets/check` with `{"items":[{"sha256":"<stored hash>"},{"sha256":"<random 64 hex>"}]}`. Response `{"known":[true,false]}`.
- **Duplicate in a new session.** Create a second session. `POST /uploads` with that session, a new filename, the same `size` and the same `sha256`. Status 200, `status: "duplicate"`, no `PATCH` needed. Complete the session: its summary has `duplicates: 1`, `verified: 0`.
- **Dashboard.** Open `/dashboard`; `Duplicates skipped` reads 1 and the backup folder still holds one file.
- **Missing on disk is not known.** Delete the stored file from `.verify/run/backup`, then call `GET /files/<sha256>` again: `known` must be `false` (known means recorded, intact and present at the recorded size). Re-announcing the hash must not return `duplicate`.

## Gotchas

- Re-announcing a hash inside the **same** session is an idempotent replay (the earlier result is returned as `duplicate` without a new row) and does not raise the duplicate count. Use a second session to test counting.
- The `known` answer for `assets/check` also trusts an `assetId` this device already completed; test `assetId` matching separately from hash matching.
- Deleting files by hand in `.verify/run/backup` is only for the missing-file case, and only inside the scratch folder.
