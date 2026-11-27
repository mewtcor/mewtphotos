# Phase 2 plan: Feasibility on the real iPhone

Goal: measure, on the real iPhone, what the app can read and upload before any feature depends on it. Covers FEAS-02 to FEAS-05.

Phase 2 ends with a go/no-go note. A byte mismatch in FEAS-03 stops the project (see ROADMAP.md).

## Scope and limits

- Read-only. The app never changes or deletes library items. Photo access is requested with a clear explanation.
- Measurement code only. This is not the backup feature. Nothing here writes to the library or claims an item is backed up.
- Phase 2 adds the Photos framework to the app target. The pure logic goes into MewtPhotosCore and is tested on Linux, as in Phase 1.
- The Mac build budget applies. Plan for about two Mac builds in this phase: one for the diagnostics and export screens, and one for the upload test.

## Plan 02-01: Diagnostics screen (FEAS-02, FEAS-05)

Build a diagnostics screen that lists every stored part of a chosen item.

Tasks:
1. Core (Linux-tested): a `PartRecord` type with type, filename, format and size, and a function that turns the list of parts into the summary line. Tests cover an item with several parts, an item with none, and sizes of zero.
2. App: a diagnostics screen reached from a button. The user picks an item from the library with the system picker, and the screen lists each part through `PHAssetResource.assetResources(for:)`. Use the part's type, original filename and uniform type identifier. For size, write each part to a temporary file and measure it, because the resource object does not give a size directly.
3. For iCloud-only items, the screen says the item is not on the phone and shows what it would need to download. It does not download anything in this plan.

Acceptance:
- Core tests pass in CI.
- The screen shows every part of a sample item on the device.
- The screen names iCloud-only items and does not present them as complete.

## Plan 02-02: Export and hash comparison (FEAS-03)

The app exports original files from sample items. The user copies the same originals over USB. Both sets are hashed and compared.

Tasks:
1. Core: a comparison function that takes two lists of (name, SHA-256) and reports each match, mismatch or missing file. Tests cover all three outcomes.
2. App: an export action for the picked item. It writes each original part to the app's Documents folder through `PHAssetResourceManager.writeData` with network access allowed for iCloud items, then shows the file list with sizes. The app computes SHA-256 with the Core hashing function and writes a manifest file.
3. Export at least four kinds of item: HEIC, Live Photo (both halves), an edited photo, and a slow-motion or HDR video. The user has RAW and ProRAW photos, so both are included: export one RAW (a DNG from a RAW-capable camera app) and one ProRAW (Apple's DNG from the Camera app). Record which PHAssetResource type each one reports, since the diagnostics screen will show what iOS gives for each.
4. The user copies the same items from the phone over USB and runs the comparison on the PC.

Acceptance:
- The manifest from the phone and the USB copies give the same SHA-256 for every item.
- Any mismatch is recorded with the item name, and the phase stops for re-planning.

## Plan 02-03: Video upload speed (FEAS-04)

Measure how fast the app uploads a large video, and what happens when the screen locks.

Tasks:
1. Core: a timing helper that records bytes sent and seconds elapsed, and reports speed in MB/s. Tests cover a known input and a zero-time case.
2. App: a test screen that picks a video and uploads it to the PC in 8 MiB chunks, reusing the existing `/api/v1` upload routes (`POST /uploads`, `PATCH` chunks, `finish`). The screen shows the chunk size, the speed, and whether the upload finished.
3. Test the screen-lock case: start an upload, lock the phone, unlock it, and record whether the upload continued or stopped.

Acceptance:
- The measured speed is recorded with the chunk size.
- The screen-lock result is recorded.
- The server accepts the upload (`verified`) and the file's SHA-256 matches the source.

## Device test and go/no-go

A device test checklist (`docs/ios-phase2-device-test.md`) is written after Plan 02-01 is built, so it can name the exact screens. It covers the sample items, the USB copy, the video upload, and the iCloud and hidden-item observations.

The go/no-go note goes in `.planning/phases/02-feasibility-on-the-real-iphone/02-GATE.md`. Phase 3 does not start until the note says go.

## Open questions

- Resolved: the phone has RAW and ProRAW, and the video test uses videos already on the phone (including slow-motion or HDR if available).
