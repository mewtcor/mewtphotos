# Phase 2 gate: feasibility on the real iPhone

## Result so far

Byte-identical originals were read from the phone and matched a copy made over USB, for two items:

| Item | Kind | Phone export SHA-256 | USB copy SHA-256 | Size | Result |
|------|------|----------------------|------------------|------|--------|
| IMG_8031.MOV | slow-motion video (+ Adjustments.plist) | `ac26b2ba…7ca1349` | `ac26b2ba…7ca1349` | 81,592,397 B | match |
| IMG_8048.DNG | RAW, probably ProRAW (not confirmed) | `ae4bdc97…c162b3` | `ae4bdc97…c162b3` | 83,834,288 B | match |

The phone's manifest for IMG_8048.DNG (79 bytes) holds the same hash.

## Not tested

- IMG_7918.DNG (the 18.6 MB RAW). Skipped: the user asked to reduce the test to one photo and one video, for time.
- IMG_7986 Live Photo (HEIC + paired MOV). Skipped for the same reason.
- ProRAW for IMG_8048.DNG. Not confirmed on the phone. Both RAW files report `com.adobe.raw-image`.
- FEAS-04 video upload speed (Plan 02-03). Not started.
- FEAS-05 observations (iCloud-only item, hidden item, burst frames). Not tested.

## Bugs found and fixed during the test

- **Empty manifest (builds 8 and 9).** A re-export left the first export's files in the folder, and `writeData` refuses to overwrite an existing file, so the export failed and wrote an empty manifest. Fixed in commit `e8e9a03` (build 10): the export clears its own export folder first, and the screen reports the manifest's byte count. Verified on the phone: 79 bytes, one line.
- **Raw type labels (build 7).** Showed `PHAssetResourceType(rawValue: N)`. Fixed in `8df537f` with `kindName`. Verified on the phone.

## Deviation from the Phase 1 threat register

Phase 2 writes exported originals to the app's Documents folder, so Files and the PC's Apple Devices app can see them. Phase 1 (T-01-15) allowed only the scrubbed run log there. This is a deliberate, temporary exception for the USB test.

Action: delete the `PhotoSyncExport` folder from the phone (Files > On My iPhone > PhotoSync) after the test. The PC copies in `Downloads\phase2-export` and `Downloads\phase2-usb` are test copies and can be deleted too.

## Builds used

| Build | Run | Commit | Purpose |
|-------|-----|--------|---------|
| 7 | 38188191778 | aebe296 | Diagnostics screen (Plan 02-01) |
| 8 | 38195990301 | 8df537f | Export screen (Plan 02-02) |
| 9 | 38235531460 | 078d4b7 | Manifest size on screen |
| 10 | 38236177551 | e8e9a03 | Clear export folder before re-export |

## Decision

Pending the user's sign-off. The two items that matched show that originals can be read byte-identically from the phone and exported with SHA-256 verification. The user chose to stop the test early for time, so the Live Photo, the second RAW and the video-speed test (Plan 02-03) remain open. Phase 3 must not start until the user decides.
