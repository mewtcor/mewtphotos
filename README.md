# iPhone Photo Backup (PhotoSync)

Back up photos and videos from an iPhone to a Windows 11 PC over your own Wi-Fi.
No cloud, no account, no subscription. Nothing is ever deleted from the iPhone.

- **Windows side:** a small local server plus a dashboard in your browser.
- **iPhone side:** a web page in Safari (scan a QR code), or an optional Apple Shortcut.
- **Priority:** integrity. A file is reported as backed up only after it has been written,
  re-read from disk, hashed with SHA-256, placed in the backup folder, and recorded.

## Quick start

1. Double-click **`Start Backup.cmd`** (or run `.\scripts\start-backup.ps1` in PowerShell).
   The first run installs dependencies into this folder and builds the web pages.
2. The dashboard opens at `http://127.0.0.1:8787/dashboard`. Confirm or change the backup folder
   (default: your Pictures folder, `iPhone Backup`).
3. With the iPhone on the same Wi-Fi, scan the QR code with the Camera app and tap **Pair**.
4. Tap **Choose photos & videos**, pick items, and keep Safari open until the list finishes.
5. Read the result line and, on the PC, press **Verify now** whenever you want to re-check the stored files.

To stop, just close the dashboard tab (the app waits for any running backup) or press **Stop backup app**.

Next time: start the app, open the saved page on the iPhone (Share → Add to Home Screen), pick, done.

Guides: [Windows setup](docs/setup-windows.md) · [Troubleshooting](docs/troubleshooting.md) ·
[Apple Shortcut](docs/ios-shortcut.md) · [iPhone test checklist](docs/iphone-test-checklist.md) ·
[API](docs/api.md) · [Native iOS roadmap](docs/ROADMAP_IOS_COMPANION.md)

## What has and has not been tested

| Area | Status |
|---|---|
| Transfer engine, integrity, recovery, security rules | 49 automated tests (`npm test`), all passing |
| Dashboard and phone page | Exercised in Chrome on the PC (pairing, chunked upload, skipping already-synced files, rejected type, verify) |
| Launcher | Run on this PC, including the port-in-use message |
| **Anything on a real iPhone** (Safari picker, HEIC/Live Photo behaviour, suspension, Shortcuts) | **Not tested.** Work through [docs/iphone-test-checklist.md](docs/iphone-test-checklist.md) |

## iOS limitations you should know about

These come from iOS, not from this app, and the app is built to state them rather than hide them.

- **No whole-library view.** Safari and Shortcuts only hand over the items you pick. The app can prove
  your *selection* is safely stored; it cannot know how many photos the iPhone holds or which ones are new.
  A successful session therefore ends with: *"All selected files transferred successfully. Complete iPhone
  photo library coverage has not been verified."* There is no "100% of library" status anywhere.
- **Originals vs. converted copies.** When picking from the Photo Library, iOS may give Safari a converted
  copy (HEIC → JPEG, re-encoded video) depending on the picker's *Options* and on the iOS version. The app
  stores exactly the bytes iOS delivers and never converts, compresses, or strips metadata itself. Whether
  those bytes are the camera original must be checked on your device (see the checklist).
- **Live Photos** arrive as the still image only. The paired video is not available to web pages.
- **No background uploads.** iOS suspends Safari when the phone locks or you switch apps. The page detects
  this, says so, and resumes interrupted files from where they stopped.
- **Already-synced photos are skipped, but each one is still read on the iPhone.** A browser has no stable
  photo identifier, so the page hashes each selected file locally and asks the PC whether it has that
  content. Known files are not sent. If you turn the check off, files are sent first and recognised as
  duplicates afterwards (still never stored twice).
- **"End-to-end verified"** means the hash computed in Safari matched the bytes on the PC's disk. It proves
  the transfer and the disk write, not that Safari received the original from Photos.

A native iOS app would lift most of these; see the [roadmap](docs/ROADMAP_IOS_COMPANION.md).

## How it works

```
iPhone (Safari / Shortcut)                Windows PC
  pick files ──HTTP on Wi-Fi──►  server/app.ts      routes, pairing, access rules
                                 server/engine.ts   receive → hash → dedupe → place → commit
                                 server/verify.ts   re-hash stored files on demand
                                 SQLite database    %LOCALAPPDATA%\PhotoSync\photosync.db
                                 backup folder      Pictures\iPhone Backup\YYYY\MM\...
```

Per file:

1. `POST /uploads` reserves a temp file in `<backup folder>\.incoming`.
2. `PATCH /uploads/:id` appends 8 MB chunks at an explicit offset. After any interruption the client asks
   for the real offset (measured from the file on disk) and continues.
3. `POST /uploads/:id/finish`: flush to disk → re-read and SHA-256 → compare with the sender's hash if given
   → duplicate check by hash (the existing copy is itself re-hashed before being trusted) → pick a
   collision-safe name → record intent → atomic rename → commit. Only then does the client get success.

A crash at any point leaves either a resumable partial upload or a verified file; startup recovery
finishes or rolls back anything in between.

### Folder layout and dates

`YYYY\MM` comes from the capture date embedded in the file (EXIF `DateTimeOriginal`, or the QuickTime
creation time for MOV/MP4). Fallback when there is none: the file's modification time as reported by the
sender, then the upload date. The source used is recorded per file (`date_source`). Organising never
modifies file content; you can turn it off in the dashboard.

Same name, different content → `IMG_0001 (2).HEIC`. Existing files are never overwritten.

## Architecture decisions

| Decision | Why |
|---|---|
| One npm package (`server/`, `web/`, `shared/`) instead of a workspace monorepo | Three small folders share types by relative import; workspaces added tooling without benefit. |
| Server runs TypeScript directly (Node ≥ 22.18), no build step | Fewer moving parts; only the web UI is bundled. |
| Node's built-in `node:sqlite` instead of `better-sqlite3` | Same SQLite engine, nothing to compile on Windows. It is still flagged experimental by Node, hence the pinned minimum version. WAL mode, `synchronous=FULL`. |
| Own offset-based chunk protocol instead of tus | About 100 lines, fully under test, and lets finalization own hashing and placement. Semantics mirror tus (`Upload-Offset`), so a native client is straightforward. |
| SHA-256 implemented in JS for the phone page | Safari disables `crypto.subtle` on `http://` pages, and it cannot hash a multi-GB file in pieces anyway. Verified against `node:crypto`. |
| Plain HTTP, not HTTPS | A self-signed certificate must be manually trusted on iOS and breaks QR-scan simplicity. The trade-off: traffic and the device key are readable by others on the same Wi-Fi. Use a network you trust. |
| Dashboard has no login; it answers only to `127.0.0.1` | It is reachable solely from the PC itself (loopback socket and loopback `Host` header). |
| Database outside the backup folder (`%LOCALAPPDATA%\PhotoSync`) | The backup folder contains only your photos (plus `.incoming` during transfers) and can be changed without losing history. |
| Server-Sent Events for live dashboard updates | One-way, built into browsers, no extra dependency. |
| No Electron | The server exports `buildApp()`; a Tauri shell can later start it as a sidecar and load the same dashboard URL. |

## Security summary

- Listens on `127.0.0.1` and the PC's Wi-Fi/Ethernet address only; every request must also come from a
  private-range address. No port forwarding, tunnelling, or cloud service is used or needed.
- Pairing: one-time 8-character code (10 minutes, rotates on use, wrong guesses throttled per address).
  The iPhone receives a random 256-bit key; the PC stores only its SHA-256. Remove a device from the dashboard to revoke it.
- Filenames are reduced to a safe single name; every write path is checked to be inside the backup folder.
- Only photo/video file types are accepted; per-file size limit, optional total quota, minimum free space.
- Cross-origin browser requests are rejected, so a website you visit cannot drive the API.
- Logs contain filenames and events, never keys, pairing codes, or file content.
- The app adds **no firewall rules**. Windows may ask once whether to allow Node.js; allow *Private* only.

Known gaps, deliberately left: no HTTPS (above); anyone logged into the PC can open the dashboard;
quota and free-space checks are made when an upload starts, so several simultaneous large uploads can
overshoot slightly; the log file is not rotated.

## Commands

| Command | Purpose |
|---|---|
| `Start Backup.cmd` / `scripts\start-backup.ps1 [-Port 8787] [-NoBrowser]` | Start the app |
| `npm run verify` | Re-hash every stored file and check the database (exit code 1 on problems) |
| `npm test` | Automated tests |
| `npm run typecheck` | Strict TypeScript check |
| `npm run build` | Rebuild the web pages after changing `web/` |

Environment variables (optional): `PHOTOSYNC_PORT`, `PHOTOSYNC_HOST` (force a specific local address),
`PHOTOSYNC_DATA_DIR` (database and log location).
