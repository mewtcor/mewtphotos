# API (version 1)

Base path `/api/v1`. JSON unless noted. Request and response shapes are defined in
[`shared/schemas.ts`](../shared/schemas.ts) (Zod schemas plus TypeScript types) and are the contract
for any client, including a future native iOS app.

- **Sender endpoints** need `Authorization: Bearer <device key>` (obtained by pairing).
- **Admin endpoints** (`/admin/...`) answer only to the PC itself (loopback) and take no key.
- Errors: non-2xx with `{ "error": "<code>", "message": "<human text>", ... }`.

## Pairing and status

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/health` | | `{ ok, name, apiVersion }` (no auth; for discovery) |
| POST | `/pair` | `{ code, deviceName }` | `{ token, deviceId }`. 403 `bad_pairing_code`, 429 `too_many_attempts` |
| GET | `/status` | | `ClientStatus`: chunk size, concurrency, file size limit |

## Sessions

A session is one backup run. Its summary keeps apart: library count (if the sender can know it),
selected, submitted, received, verified, duplicates, failed, unavailable.

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/sessions` | `{ method: "safari"\|"shortcut"\|"native", selectedCount, libraryCount? }` | `SessionSummary` |
| GET | `/sessions/:id` | | `SessionSummary` |
| POST | `/sessions/:id/complete` | `{ unavailableCount? }` | `SessionSummary` |

`libraryCoverageVerified` is always `false` in this version.

## Resumable upload

1. `POST /uploads` with `{ sessionId, filename, size, mimeType?, lastModified?, assetId?, sha256? }`
   - → `{ uploadId, status: "receiving", offset, size }`. `offset > 0` means an interrupted transfer of
     the same file (same device, name, size and `lastModified`) was found; continue from there.
   - → an `UploadResult` with `status: "duplicate"` if `sha256` was given and that content is already
     stored intact. Nothing needs to be sent.
   - 415 `unsupported_type`, 413 `file_too_large`, 507 `insufficient_space` / `quota_exceeded`.
2. `PATCH /uploads/:id` with header `Upload-Offset: <n>` and the raw bytes as body
   (`Content-Type: application/offset+octet-stream`, any chunk size).
   - → `{ offset }` (also in the `Upload-Offset` response header).
   - 409 `offset_mismatch` with the correct `offset`; 409 `upload_busy`; 413 `too_much_data`; 408 `upload_timeout`.
3. `GET /uploads/:id` → `{ uploadId, status, offset, size }`. Call this after any failure; the offset is
   measured from the bytes actually on disk.
4. `POST /uploads/:id/finish` with `{ sha256? }` → `UploadResult`
   `{ uploadId, status: "verified"|"duplicate", sha256, endToEndVerified, path }`.
   - Returned only after the file is flushed, re-read, hashed, placed and committed.
   - Idempotent: repeat it if the response was lost. `upload_busy` means it is still working.
   - 409 `incomplete` (with `offset`), 422 `hash_mismatch` (nothing stored; start a new upload).
5. `DELETE /uploads/:id` cancels and discards a partial upload.

## One-request upload

`POST /files?filename=<name>[&sessionId=<id>][&sha256=<hex>]` with the file as the raw body and a
`Content-Length` header → `UploadResult`. Not resumable. Without `sessionId`, uploads from one device
within 30 minutes are grouped into one `shortcut` session.

## Incremental check

`GET /files/<sha256>` → `{ known: true, status: "stored", path }` or `{ known: false, status: "missing" }`.
Known means recorded, passed its last verification, and present on disk at the recorded size.

`POST /assets/check` with `{ items: [{ assetId?, sha256? }, ...] }` (max 5000) → `{ known: boolean[] }`.
An item is known if its hash is stored and passed its last verification, or if this device already
completed an upload with that `assetId`. Intended for a client with stable asset identifiers.

## Admin (PC only)

| Method | Path | Purpose |
|---|---|---|
| GET | `/admin/overview` | Everything the dashboard shows (`Overview`) |
| GET | `/admin/pairing` | Current pairing code, URL and QR code (SVG) |
| PUT | `/admin/settings` | Partial `Settings` update; validates the backup folder |
| POST | `/admin/verify` | Start verification (202). Result appears in `overview.lastVerify` |
| DELETE | `/admin/devices/:id` | Revoke a paired device |
| POST | `/admin/shutdown` | Stop the app |
| GET | `/admin/events` | Server-Sent Events: `change`, `speed { bytesPerSecond }`, `verify { done, total }` |

## Data model (SQLite)

| Table | Holds |
|---|---|
| `devices` | Paired devices: name, SHA-256 of the key, revoked flag |
| `sessions` | Backup runs: method, selected / unavailable / library counts, times |
| `uploads` | Every transfer attempt: status (`receiving`, `finalizing`, `verified`, `duplicate`, `failed`, `cancelled`, `retried`), size, `asset_id`, hash, error |
| `files` | One row per distinct stored content: SHA-256 (unique), path, size, capture date and its source, last verification |
| `logs` | Events shown in the dashboard |
| `settings` | Settings and the last verification report |
