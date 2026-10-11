# iPhone test checklist

Nothing in this project has been run on a real iPhone yet. Automated tests cover the PC side; this list
covers what only your device can show. Use a small set of photos you also have elsewhere.

Record the iOS version: ____________   iPhone model: ____________

## 1. Connect and pair

- [ ] `Start Backup.cmd` shows an iPhone address and QR code.
- [ ] Camera scans the QR code and Safari opens the page.
- [ ] Pairing code is pre-filled; **Pair** succeeds; page shows "Connected to …".
- [ ] Dashboard → Paired devices lists the iPhone.
- [ ] Close and reopen Safari: still paired (no code needed).
- [ ] Add to Home Screen, open from the icon: still paired.
- [ ] `http://<PC address>:8787/dashboard` on the iPhone says the dashboard is PC-only.

## 2. Basic transfer

- [ ] Pick 5 photos: all end as *Stored & verified*, result line reads "All selected files transferred
      successfully. Complete iPhone photo library coverage has not been verified."
- [ ] Files exist under `Pictures\iPhone Backup\YYYY\MM\` and open normally.
- [ ] Pick the same 5 again: all *Already backed up*; no extra files on disk.
- [ ] Dashboard → **Verify now**: all present and intact.

## 3. What does iOS actually hand over? (the important one)

For each row, compare the stored file with the item on the phone (Photos → swipe up / ⓘ shows format,
resolution and size).

| Test | Via "Choose photos & videos" | Via "Choose from Files instead" |
|---|---|---|
| HEIC photo: stored extension and size | | |
| Same, with picker *Options → Current + Actual Size* | | n/a |
| ProRAW / DNG photo | | |
| 4K or HDR video: resolution, codec, size | | |
| Live Photo: still only, or still + video? | | |
| Edited photo: edited version or original? | | |
| Screenshot (PNG) | | |
| EXIF kept? (date, camera, GPS in file properties) | | |
| Sorted into the correct Year\Month? | | |

- [ ] Note which path preserves originals on your iOS version and use that one.

## 4. Large files and interruptions

- [ ] A video over 1 GB completes and plays; dashboard shows it verified end to end.
- [ ] During a large upload, lock the phone for 30 seconds, unlock: page shows the "iOS paused" notice
      and the file continues from where it was (not from zero).
- [ ] During an upload, switch to another app for a minute and return: same.
- [ ] Turn Wi-Fi off for 20 seconds mid-upload, then on: resumes, or shows **Retry** which completes.
- [ ] Press Ctrl+C on the PC mid-upload, restart the app: on the phone tap **Retry**; file completes and verifies.
- [ ] Reload the Safari page mid-upload and pick the same video again: does it resume (offset kept) or
      restart? (Depends on whether iOS reports the same file date twice. Either way the result must verify.)
- [ ] Tap **Cancel** mid-batch: unfinished items show *Cancelled*; **Retry** finishes them.
- [ ] 200+ photos in one batch: page stays responsive; counts add up.

## 5. Problem reporting

- [ ] Pick an item stored only in iCloud (with *Optimize iPhone Storage* on): is it downloaded and sent,
      or reported *Unavailable*? It must never be shown as stored if it was not.
- [ ] Set *Keep free on disk* absurdly high in the dashboard, upload: clear "not enough free space"
      on the phone and in the dashboard log. Restore the setting.
- [ ] Remove the device in the dashboard: the phone is asked to pair again.

## 6. Shortcut (optional)

- [ ] Follow [ios-shortcut.md](ios-shortcut.md) and complete its "What to check" list.

## 7. Safety

- [ ] After all tests, the Photos library on the iPhone is unchanged (nothing deleted or modified).
- [ ] iTunes, Apple Devices and AltServer still detect the iPhone as before.
