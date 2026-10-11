# Troubleshooting

The dashboard's **Log** and **Failed uploads** sections show the reason for most problems.
The full log is `%LOCALAPPDATA%\PhotoSync\server.log`.

## The iPhone cannot open the page

Work down this list:

1. **Is the app running?** The PC window must be open and the dashboard must say *Server running*.
2. **Same network?** iPhone: Settings → Wi-Fi must show the same network name as the PC. Guest networks
   and "client/AP isolation" on a router block phone-to-PC traffic. Turn off any VPN on either device.
3. **Cellular fallback.** If Wi-Fi is weak the iPhone may silently use mobile data, which cannot reach
   the PC. Stay near the router.
4. **Windows Firewall.** If you dismissed the "allow Node.js" prompt, Windows blocks the iPhone.
   Open *Windows Security → Firewall & network protection → Allow an app through firewall*, find
   *Node.js JavaScript Runtime*, and tick **Private**. The app never changes firewall settings itself.
   If you prefer a rule limited to this app's port, run this yourself in an **administrator** PowerShell:

   ```powershell
   New-NetFirewallRule -DisplayName "iPhone Photo Backup" -Direction Inbound -Protocol TCP -LocalPort 8787 -Profile Private -Action Allow
   ```

5. **Network profile.** Settings → Network & internet → Wi-Fi → your network must be **Private**,
   not Public, or the firewall rule above does not apply.
6. **Quick test from the PC:** open `http://<iPhone address shown in the window>/api/v1/health` in the
   PC's browser. If that works but the iPhone cannot connect, the cause is items 2 to 5.

## "Server restart required"

The PC's network address changed (different Wi-Fi, or the router gave a new address). Stop the app,
start it again, and scan the new QR code. The iPhone stays paired, but the page address is different;
re-add it to the Home Screen.

## Port already in use by another program

If the backup app itself is already running, starting it again just opens its dashboard. This message
means a different program has the port. Start on another one:
`.\scripts\start-backup.ps1 -Port 8788`.

## Uploads stop when the screen locks

iOS suspends Safari in the background. The page shows a notice when it notices the pause and resumes
the interrupted files. For large batches: keep Safari in front, plug the phone in, and set
Settings → Display & Brightness → Auto-Lock to *Never* for the duration.

## Messages you may see

| Message | Meaning and fix |
|---|---|
| *This device is not paired* | Scan the QR code again and pair. Happens after removing the device or clearing Safari data. |
| *Pairing code is wrong or has expired* | Codes last 10 minutes and are single-use. Use the one currently on the dashboard. |
| *Too many wrong pairing codes* | Wait five minutes. |
| *Connection lost during upload* / *client disconnected* | Wi-Fi drop or iOS suspension. The sent part is kept; it resumes or tap **Retry**. |
| *Upload timed out* | No data for 60 seconds. Usually weak Wi-Fi. Retry resumes. |
| *Already backed up* | Identical content is already stored; nothing was duplicated. Not an error. |
| *Not enough free space* / *backup drive is full* | Free space on the drive or choose another backup folder. |
| *Backup storage quota is full* | Raise or remove the size limit in the dashboard. |
| *Windows denied access* | The backup folder is not writable. Check folder permissions, antivirus, and Windows Security → Ransomware protection → Controlled folder access (allow Node.js or pick a folder outside protected ones). |
| *Arrived corrupted (SHA-256 differs)* | The bytes on disk did not match what the iPhone hashed. Nothing was stored; send the file again. |
| *Not a supported photo or video type* | Only image and video files are accepted. |
| *Unavailable on iPhone* | iOS could not give Safari the file, typically an iCloud-only original. Open the item in Photos so it downloads, then retry. |
| *Lost when the server stopped mid-save* | Rare crash window; the file was not stored. Send it again. |

## Photos arrive as JPEG instead of HEIC, or videos look re-encoded

That conversion is done by iOS before Safari receives the file. In the photo picker tap **Options** and
choose *Actual Size* and *Current* (not *Most Compatible*) where your iOS version offers them, or use
**Choose from Files instead**. See the [test checklist](iphone-test-checklist.md) to confirm what your
iPhone actually delivers.

## Verification reports a problem

- **Missing / corrupted:** send those photos again from the iPhone; the app stores a fresh copy and
  updates its record. Corrupted files are left in place for you to inspect or delete.
- **Files the app did not store:** harmless; they were put in the folder by something else and are
  simply not covered by verification.

## Starting over

Stop the app and delete `%LOCALAPPDATA%\PhotoSync`. Your photos in the backup folder are untouched,
but hashes, history and pairings are gone, and previously backed-up photos will be stored again
(under collision-safe names only if their content differs; identical files are adopted, not duplicated).
