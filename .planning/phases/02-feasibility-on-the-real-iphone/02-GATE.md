# Phase 2 gate: feasibility on the real iPhone

## Result so far

Byte-identical originals were read from the phone and matched a copy made over USB, for two items:

| Item | Kind | Phone export SHA-256 | USB copy SHA-256 | Size | Result |
|------|------|----------------------|------------------|------|--------|
| IMG_8031.MOV | slow-motion video (+ Adjustments.plist) | `ac26b2ba…7ca1349` | `ac26b2ba…7ca1349` | 81,592,397 B | match |
| IMG_8048.DNG | RAW, probably ProRAW (not confirmed) | `ae4bdc97…c162b3` | `ae4bdc97…c162b3` | 83,834,288 B | match |

The phone's manifest for IMG_8048.DNG (79 bytes) holds the same hash.

## Upload speed (FEAS-04, Plan 02-03)

Uploads used the backup's own routes (`/api/v1/sessions`, `/uploads`, `PATCH` chunks, `/finish`) in 8 MiB chunks. The PC re-read each stored file and compared its hash with the one the phone sent.

| File | Size | Speed | Chunks | Server status | End-to-end verified |
|------|------|-------|--------|---------------|---------------------|
| IMG_8069.MOV | 27.1 MB | 20.97 MiB/s (1.3 s) | 8 MiB | verified | yes |
| IMG_8071.MOV | 249.2 MB | 24.44 MiB/s (10.2 s) | 8 MiB | verified | yes |

**Screen lock, foreground upload (build 10):** failed. An ordinary upload stops when the screen locks. The PC stored nothing from that attempt.

**Screen lock, background upload (build 12):** passed. IMG_8075.MOV (910,663,702 bytes) was sent with the phone locked, at 22.58 MiB/s (38.5 s). The PC stored and verified it. The phone's final "finish" reply was lost, so the app showed "not confirmed" until the next tap. Build 13 fixes this: the hash is sent when the upload opens (a file the PC already has is recognised without resending), and an unfinished upload is retried when the app opens.

The background transfer of an 80 MB or larger video works with the screen locked, so the Phase 3 design can rely on it.

## Not tested

- IMG_7918.DNG (the 18.6 MB RAW). Skipped: the user asked to reduce the test to one photo and one video, for time.
- IMG_7986 Live Photo (HEIC + paired MOV). Skipped for the same reason. (IMG_8068 covers the Live Photo case.)
- ProRAW for IMG_8048.DNG. Not confirmed on the phone. Both RAW files report `com.adobe.raw-image`.
- FEAS-05 observations (iCloud-only item, hidden item, burst frames). Not tested.

## Bugs found and fixed during the test

- **Empty manifest (builds 8 and 9).** A re-export left the first export's files in the folder, and `writeData` refuses to overwrite an existing file, so the export failed and wrote an empty manifest. Fixed in commit `e8e9a03` (build 10): the export clears its own export folder first, and the screen reports the manifest's byte count. Verified on the phone: 79 bytes, one line.
- **Raw type labels (build 7).** Showed `PHAssetResourceType(rawValue: N)`. Fixed in `8df537f` with `kindName`. Verified on the phone.

## Deviation from the Phase 1 threat register

Phase 2 writes exported originals to the app's Documents folder, so Files and the PC's Apple Devices app can see them. Phase 1 (T-01-15) allowed only the scrubbed run log there. This is a deliberate, temporary exception for the USB test.

Action: delete the `MewtPhotosExport` folder from the phone (Files > On My iPhone > Mewt Photos) after the test. The PC copies in `Downloads\phase2-export` and `Downloads\phase2-usb` are test copies and can be deleted too.

## Builds used

| Build | Run | Commit | Purpose |
|-------|-----|--------|---------|
| 7 | 38188191778 | aebe296 | Diagnostics screen (Plan 02-01) |
| 8 | 38195990301 | 8df537f | Export screen (Plan 02-02) |
| 9 | 38235531460 | 078d4b7 | Manifest size on screen |
| 10 | 38236177551 | e8e9a03 | Clear export folder before re-export |

## Decision

**Go.** Signed off by the user, 2026-10-13.

Phase 2 answered the feasibility questions:
- **FEAS-03 (originals match):** a RAW-type photo (IMG_8048.DNG), a slow-motion video (IMG_8031.MOV) and a Live Photo's two parts (IMG_8068 HEIC and MOV) all read from the phone byte-identically. The phone's hashes match the USB copies.
- **FEAS-04 (upload speed):** 20–25 MiB/s over home Wi-Fi in 8 MiB chunks (IMG_8069, IMG_8071), and about 22.6 MiB/s for a background upload of 910 MB (IMG_8075).
- **Screen lock:** a foreground upload stops when the screen locks. A background transfer keeps going with the screen locked and completed on the PC (IMG_8075).

Phase 3 must design around these:
1. **Use a background transfer** (`BackgroundUploader` in build 12–13) for every upload, not a foreground request.
2. **Send the hash when an upload opens**, so the PC can answer "already backed up" without a re-send.
3. **Retry an unfinished finish step** when the app becomes active.

Not tested, accepted by the user to skip for time:
- IMG_7918.DNG (the second RAW).
- ProRAW confirmation for IMG_8048.DNG. Both RAW files report `com.adobe.raw-image`.
- FEAS-05 observations: an iCloud-only item, a hidden item, burst frames.

Open clean-up:
- Delete the test exports from the phone: Files > On My iPhone > Mewt Photos > `MewtPhotosExport`. This deviation from the Phase 1 threat notes (T-01-15) was temporary for the USB test.
- Delete the PC test copies in `Downloads\phase2-export` and `Downloads\phase2-usb` once Phase 3 starts.
- The background-upload completion is lost if iOS terminates the app before the transfer ends. The next upload or the retry finishes it. Phase 3 should cover this.
