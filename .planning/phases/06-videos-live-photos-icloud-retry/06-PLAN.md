# Phase 6: Videos, Live Photos, iCloud and Retry

Goal: every part of every item reaches the PC as its original: videos, both halves of Live Photos, the RAW beside its
JPEG or HEIC, and iCloud-only items. Interrupted large videos resume, and failed items can be retried.

Requirements: ORIG-02, ORIG-03, UP-03, LIVE-01, LIVE-02, CLOUD-01, CLOUD-02, CLOUD-03, REP-04.

Starting point (Phase 5 closed as go on 2026-10-13):
- Each item is exported as one file (`PreparedItem`, one `fileURL`), so the run cannot send a second part yet.
- Videos, Live Photos and iCloud-only items are listed as "not supported in this version yet" (`BackupPlanner`).
- The PC already keeps Live Photo pairs under one base name (SRV-01, `pair_id`, `pair_name`), so the server side of
  LIVE-01 is expected to exist. Confirm it with a test before the app relies on it.
- The background transfer resumes from the PC's offset (`beginUpload` returns `offset`), so UP-03 needs the app to
  ask for the offset after a restart, not to start again.

Rule for every plan: logic goes in `MewtPhotosCore` and is tested on Linux; the app target only adapts PhotoKit,
the screen and the background transfer. Every plan ends with one device test on the real iPhone (the build is
dispatched by the owner's go-ahead).

## Plan 06-01: several parts per item (ORIG-02, the RAW pair)

Pure logic first, then the app.
- Change the item model from one file to a list of parts. Each part has a kind (`photo`, `alternatePhoto`, `video`,
  `pairedVideo`, `audio`), a file name, a size and a hash.
- An item is `verified` only when every part is verified. If one part fails, the item is `failed` with the reason
  for that part, and the other parts are not counted as backed up.
- The app exports each part (PhotoKit resource types), one at a time, and deletes each temporary copy after its send.
- Check on the server that the RAW and its JPEG or HEIC land under the same base name in the same folder. If not,
  add it to the existing pair naming (small, additive, with a test).
- Tests: an item with two parts is `verified` only when both are; one failed part makes the item `failed`; a second
  run sends nothing for an item whose parts are all on the PC.
- Device test: take a RAW + JPEG photo (from the Camera app, RAW on), back up, check both files on the PC under one
  base name, and check the phone shows the item as backed up only once both are verified.

## Plan 06-02: Live Photos (LIVE-01, LIVE-02)

- A Live Photo has two parts: the still and the video (`pairedVideo`). It uses the same multi-part path as 06-01.
- Both parts keep the same base name on the PC in the same folder (server pair naming, SRV-01).
- The app shows it as backed up only when both are verified.
- Tests: a Live Photo with a missing video part is `failed`, not backed up; both parts verified makes it backed up.
- Device test: back up IMG_8068 (a Live Photo, listed as not supported today). Check the `.HEIC` and the `.MOV` on the
  PC, same base name, same folder.

## Plan 06-03: videos and large-file resume (ORIG-03, UP-03)

- Videos use the same send path as photos, with the video resource (`video` kind). The original is sent, not a
  transcoded copy (slow-motion, HDR and ProRes keep their format).
- Resume: after a restart or a Wi-Fi drop, the app asks the PC for the upload's offset (`beginUpload` already returns
  it) and sends only the rest. The temporary copy is kept until the item is verified, so the resume can read it. Mark
  the copy with the item, so the run can find it again. Delete it only after verified or after the item is given up.
- Tests: a resumed upload starts at the PC's offset; a copy is deleted only after verified or give-up.
- Device test: back up a video of at least 500 MB. Switch Wi-Fi off partway, switch it back on, and check the upload
  carries on from where it stopped (the PC log shows the offset).

## Plan 06-04: iCloud-only items (CLOUD-01, CLOUD-02, CLOUD-03)

- When the export needs the network (the original is only in iCloud), ask Photos for the download with network access
  on, and show "Downloading from iCloud" with progress (CLOUD-01, CLOUD-02).
- A download that stalls for longer than a timeout is cancelled, marked `unavailable` with a plain reason, and the run
  carries on (CLOUD-03). Unavailable items are listed separately and never counted as backed up.
- Only this one step may use the network for the library. Everything else stays off, as now.
- Tests: a stalled download becomes `unavailable` after the timeout; the run continues to the next item.
- Device test: an item that exists only in iCloud (turn on iCloud Photos "Optimize iPhone Storage" for a test, or use
  an existing iCloud-only item) shows the download progress and is backed up.

## Plan 06-05: retry failed items (REP-04)

- The result screen can retry all failed items, or one item from the list.
- A retry starts a new pass over the failed items only. Verified items are not sent again.
- After a retry, the totals still add up, and the phone's verified count matches the PC's count (REP-02).
- Tests: retry-all and retry-one only touch failed items; totals still add up after a retry.
- Device test: make one item fail (for example by stopping the PC server during its send), retry it, and check that
  its state and the totals update.

## Acceptance for Phase 6 (device)

- The RAW + JPEG pair, a Live Photo, a video, a resumed video and an iCloud-only item each reach the PC as originals,
  with both parts where the item has two.
- The totals still add up and still match the PC's count after a retry.
- Gate note `06-GATE.md`: go or no-go, with any gaps written down (as Phase 5 did).

## Open questions for the owner

- Videos over a size limit: is there a size limit the owner wants? Default: none, but the free space check still runs.
- iCloud timeout: how long is "stalled"? Proposed: 2 minutes without progress.
