# Upload and verify

A paired phone sends a photo or video in chunks; the PC stores it only after re-reading it from disk and hashing it, and reports `verified` only then. Interrupted transfers resume, bad bytes are rejected, and nothing is left looking backed up when it is not.

## Sub-features

- `upload-chunked` create, `PATCH` bytes, `finish` returns `verified` with `endToEndVerified: true`.
- `upload-placed` the file lands under the backup folder with the same SHA-256.
- `upload-single` `POST /files` stores a file in one request.
- `upload-resume` an interrupted upload continues from the bytes already on disk.
- `upload-hash-mismatch` a wrong sender hash is refused and nothing is stored.
- `upload-type` an unsupported extension is refused.
- `upload-cancel` `DELETE /uploads/:id` discards a partial upload.

## How to get to it (user POV)

- The iOS app and the Safari phone page upload through `/api/v1/uploads`.
- The Shortcut path uses `POST /api/v1/files`.
- The PC user sees the result on the dashboard under `Backup totals`, `Latest backup session` and `Log`.

## Driving it with the phone API on loopback

Preconditions: healthy instance, one paired device (token from `pairing`), one open session (`POST /sessions` with `{"method":"native","selectedCount":1}`).

- **Happy path.** Run `node .claude/skills/verify-photosync/scripts/vs.mjs upload`. Exit 0 and `passed: true`. `upload.json` shows `server returns verified`, `file placed inside the backup folder`, `stored bytes hash to the original`. The log line on the dashboard reads `Stored and verified "<name>" at <path>`.
- **Single request.** `POST /api/v1/files?filename=one.jpg&sessionId=<id>&sha256=<hex>` with the bytes as body and `Content-Length`. 200 with `status: "verified"`.
- **Resume.** `POST /uploads` for a file of N bytes, `PATCH` only the first half with `Upload-Offset: 0`, then (without finishing) call `POST /uploads` again with the same session, filename, size and `lastModified`. The response has `status: "receiving"` and `offset` equal to the bytes already sent. `PATCH` the remainder at that offset, then `finish`. The stored file hashes to the full original.
- **Wrong hash.** `finish` with a `sha256` that is not the file's. Status 422, error `hash_mismatch`. No new file appears under `.verify/run/backup`, and `Files stored` on the dashboard does not change.
- **Unsupported type.** `POST /uploads` with `filename: "notes.exe"`. Status 415, error `unsupported_type`.
- **Cancel.** Create an upload, send some bytes, `DELETE /uploads/<id>`. A following `GET /uploads/<id>` no longer reports `receiving`, and the backup folder has no completed file for it.
- **Proof.** Save the request/response pairs and a directory listing of `.verify/run/backup` next to `upload.json`; capture the dashboard text (`get_page_text`) and save it as `dashboard-after-upload.txt` in the evidence folder.

## Gotchas

- `PATCH` needs `Content-Type: application/offset+octet-stream` and an exact `Upload-Offset`; a wrong offset returns 409 `offset_mismatch` with the correct one.
- Resume matching uses device, name, size and `lastModified`. Send the same `lastModified` both times or no resume is found.
- A response of `verified` is the only success. Do not treat HTTP 200 on `PATCH` as backed up.
- Files are filed into `Year\Month` subfolders when `organizeByDate` is on (default), so the stored path is not directly under the backup folder.
- Tiny synthetic files are fine here. Large-file limits, quota and free-space errors (413, 507) need settings changes through `PUT /admin/settings` and are not in this recipe.
- Live Photo pairs (image plus video halves) are not covered by this recipe; `tests/pairs.test.ts` holds the logic, and the real-device check is a manual gap tracked in `.planning/`.
