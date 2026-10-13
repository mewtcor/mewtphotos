# Phase 6 gate: videos, Live Photos, iCloud and retry

Status: **open** on 2026-10-13. Retry (REP-04) is built but not yet checked on a device, and the RAW and Live Photo
checks are not yet recorded here. Phase 6 does not close until the items under "Still to check" pass.

Parked by owner decision on 2026-10-13: iCloud-only items (CLOUD-01..03), slow-motion, HDR / Dolby Vision, Cinematic
and ProRes clips (criterion 1). They are out of scope for closing this gate and are recorded below as parked, not as passes.

Commits: `71bf953` (06-03 videos and resume), `4130bee` (speed-test upload sends the photo's date), `8d15787` (a re-sent
video waits for the stalled attempt and resumes it). Retry: see "Retry" below for the commit.

## Checked on the device

| Check | Build | Result |
|-------|-------|--------|
| Short video arrives as the original `.MOV` and is verified (IMG_7545, 640,506,434 bytes) | speed test | Pass |
| Longer video arrives verified, end to end (IMG_2280, 117,027,879 bytes) | speed test | Pass |
| Video of about 500 MB verified (IMG_5378, 503,577,770 bytes) | speed test | Pass |
| Interrupted video resumes from the PC's offset (IMG_8116, 2,704,414,288 bytes): the phone sent 2,391,198,600 bytes, so 313,215,688 bytes were already on the PC. One upload row, verified | 8d15787 | Pass |
| Interrupted video resumes, first attempt (IMG_8114, 2.86 GB) | 4130bee | **Not a pass.** The phone sent the whole file again. Cause: the speed test did not send the photo's date, so the resume lookup never ran. Fixed in 4130bee, then tested again with IMG_8116 |
| Video re-sent while the stalled attempt is still open (IMG_8115) | before 8d15787 | **Not a pass.** The phone sent the whole 3.2 GB again. Cause: the server opened a second upload while the first was still open. Fixed in 8d15787 |
| Full library run (Back up photos): 4,075 items, already on PC 3,929, verified 146, failed 0, unavailable 0 | current | Pass. 3,929 + 146 = 4,075. The PC holds 4,077, two more than the phone; one is `copy_19B8A555….mov`. The other is not yet explained |

## Carried from earlier notes, not re-checked for this gate

- **Live Photo, both halves** (IMG_8068): the project notes from build 28 record that the still and the video both arrived.
  Not checked again for this gate. Re-check on the next build.
- **RAW beside JPEG or HEIC** (06-01): the notes record a fix that sends the companion. Not confirmed on a device for this
  gate. Check it on the next build.

## Retry (REP-04)

Built, not yet on a device. A failed item can be retried in two ways:
- **Retry N failed:** on Back up photos, after a run, sends every failed item again. Unavailable items are not retried.
- **Retry** on one row under "Not backed up": sends that item again.

A retried item counts as backed up only when the PC returns `verified` or `duplicate`, the same rule as the normal run.
Unit tests cover the run record (`retryFailed`, `retry(at:)`). The screen buttons and their device behaviour are not yet checked.

## Still to check

1. Retry: force a failure (for example, turn Wi-Fi off during a run, or pick an item that fails), then use **Retry N failed**
   and a single **Retry**. Totals must still add up and match the PC.
2. Live Photo: one Live Photo arrives as two files with the same base name in the same folder, and shows backed up only
   when both are verified.
3. RAW beside JPEG or HEIC: both files arrive and count as backed up only when both are verified.
4. Phone totals match the PC after a full run, as at Phase 5 (REP-02). The first full run is recorded above; the two-file
   difference is open.

## Parked (not checked, recorded as known gaps)

- iCloud-only items: reported as unavailable, not downloaded from iCloud (CLOUD-01..03). Needs its own phase or plan.
- Slow-motion, HDR / Dolby Vision, Cinematic and ProRes clips arriving as originals (criterion 1, part): not checked.
- Edited versions of photos are not backed up; only originals are sent. This is on the Back up photos screen.
- **Switching to another app stops the run** (by design, from the Phase 5 background rule). Pulling down Control Center
  no longer stops it (fixed in build 33). Reopen the app and tap Back up now to continue.
- **No "paused" message and no automatic resume.** ROADMAP Phase 5 criterion 4 and UP-04 ask for a "paused" message and
  for the run to continue when conditions return. The app shows only "Not finished" and needs a tap to continue. Recorded
  as a v1 gap, not a pass.

## Decision

Open. Close the gate when the four "Still to check" items pass on a device. Then decide whether to start a new phase for
the parked iCloud work.
