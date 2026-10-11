# Windows setup and daily use

## Requirements

- Windows 11
- Node.js 22.18 or newer (this PC has 24.16). Nothing else: no Python, no build tools.
- iPhone and PC on the same Wi-Fi network.

The app does not use or touch iTunes, Apple Devices, Bonjour, AltServer/AltStore, Apple drivers, or the
iPhone's trust settings. It installs nothing system-wide and adds no firewall rules.

## First run

1. Double-click **`Start Backup.cmd`** in the project folder.
   - First time only: it runs `npm install` and `npm run build` inside this folder.
2. A window shows the dashboard address, the iPhone address, a pairing code and a QR code; the
   dashboard opens in your browser.
3. **Windows Firewall prompt.** The first time, Windows may ask whether to allow *Node.js JavaScript
   Runtime*. Tick **Private networks** only and allow. If you dismissed it, see
   [troubleshooting](troubleshooting.md#the-iphone-cannot-open-the-page).
4. In the dashboard, check **Backup folder & settings**. The default is `iPhone Backup` inside your real
   Pictures folder (redirected Pictures folders, such as OneDrive, are detected). Type another full path
   and press **Save** to change it; the folder is created and write access is checked first.
5. On the iPhone, open the Camera, scan the QR code, open the link in Safari, and tap **Pair**.
6. Tap **Choose photos & videos**, select items, and keep Safari in the foreground with the screen on.
7. When the list finishes, read the result line. On the PC, **Verify now** re-reads every stored file.

## Every day after that

1. Double-click `Start Backup.cmd`.
2. On the iPhone, open the saved page (in Safari: Share → **Add to Home Screen** once, then tap the icon).
   No pairing is needed again unless you remove the device in the dashboard.
3. Pick the next batch. You do not need to remember what you sent before: anything already backed up
   is checked on the iPhone, reported as *Already backed up*, and not sent again.
4. Check the result line; retry anything listed as failed.

## Stopping the app

Any of these works; partially sent files are kept and resume next time.

- **Close the dashboard tab.** About 20 seconds after the last dashboard tab is closed, the app stops
  itself and frees the port. It will not stop in the middle of a backup: it waits while a file is being
  written, a verification is running, or the iPhone talked to it in the last 5 minutes. Refreshing the
  page does not stop it. If you start with `-NoBrowser` and never open the dashboard, it keeps running.
- **Stop backup app** button at the top of the dashboard: stops immediately.
- **Ctrl+C** in the app's window, or close that window.

To keep the app running after you close the dashboard, untick *Stop the backup app when I close this
dashboard* in the settings. Note that a browser may quietly unload a dashboard tab left in the background
for a long time, which counts as closing it.

## Settings

| Setting | Meaning |
|---|---|
| Backup folder | Where new files go. Changing it never moves or forgets files already backed up. |
| Organize into Year\Month | Uses the capture date inside the file; falls back to the file date, then the upload date. |
| Parallel uploads | How many files the phone sends at once (default 2). |
| Largest allowed file | Per-file limit (default 50 GB). |
| Keep free on disk | Uploads are refused if they would leave less than this free (default 1 GB). |
| Backup size limit | Optional cap on the total stored size; 0 = no cap. |
| Stop when the dashboard closes | On by default. See *Stopping the app* above. |

## Where things are

| What | Location |
|---|---|
| Your photos | The backup folder (`...\Pictures\iPhone Backup\YYYY\MM\`) |
| In-progress transfers | `<backup folder>\.incoming\*.part` (cleaned up automatically) |
| Database (records, hashes, history) | `%LOCALAPPDATA%\PhotoSync\photosync.db` |
| Log file | `%LOCALAPPDATA%\PhotoSync\server.log` (safe to delete while the app is stopped) |

Back up the database file together with the photos if you want to keep hashes and history; without it
the photos are still ordinary files, but verification has nothing to compare against.

## Verifying the backup

- Dashboard → **Verify now**, or `npm run verify` in the project folder.
- Reports files that are **missing**, **corrupted** (content no longer matches the recorded SHA-256),
  database problems, and files in the backup folder the app did not store itself.
- A missing or corrupted file is repaired by sending that photo again from the iPhone; the app will not
  treat a damaged copy as "already backed up".

## Using another port

`.\scripts\start-backup.ps1 -Port 8788` (the iPhone page address changes with it, so re-scan the QR code).
