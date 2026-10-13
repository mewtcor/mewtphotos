# Phase 6 gate: videos, Live Photos, iCloud and retry

Status: **closed (go)** on 2026-10-13, with the gaps below recorded. Retry (REP-04) is built and unit-tested but not yet
checked on a device; it is recorded as untested, not as a pass. Live Photo passed. RAW pairing is removed from this gate.

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
| Live Photo IMG_7869 arrives as two files with the same base name in one folder (`.HEIC` and `.MOV`), both verified and paired. The phone shows it as one photo, as expected | before 8d15787 (stored 13:01 on 13 Oct, pairing commit 83eeaad) | Pass |
| Full library run (Back up photos): 4,075 items, already on PC 3,929, verified 146, failed 0, unavailable 0 | current | Pass. 3,929 + 146 = 4,075. The PC count was not compared after the run; photos were deleted from the PC for the retry test, so the counts no longer line up |

## Carried from earlier notes, not re-checked for this gate

- **Live Photo, both halves** (IMG_8068): the project notes from build 28 record that the still and the video both arrived.
  Not checked again for this gate. Re-check on the next build.
- **RAW beside JPEG or HEIC** (06-01): removed from this gate by owner decision on 2026-10-13. The phone's camera is set to
  ProRAW (JPEG Lossless), which saves a single DNG, so there was no companion to test. IMG_8123.DNG arrived alone and
  verified. Not changed, to keep the camera settings as they are. Record of the behaviour only; not a pass.

## Retry (REP-04)

Built, not yet on a device. A failed item can be retried in two ways:
- **Retry N failed:** on Back up photos, after a run, sends every failed item again. Unavailable items are not retried.
- **Retry** on one row under "Not backed up": sends that item again.

A retried item counts as backed up only when the PC returns `verified` or `duplicate`, the same rule as the normal run.
Unit tests cover the run record (`retryFailed`, `retry(at:)`). The screen buttons and their device behaviour are not yet checked.

## Still untested (carried past the gate)

1. Retry: force a failure (for example, turn Wi-Fi off during a run, or pick an item that fails), then use **Retry N failed**
   and a single **Retry**. Totals must still add up and match the PC. Check on the next run that has a real failure.
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

Closed (go) on 2026-10-13, owner decision. Open items carried forward: retry on a device (untested), the parked iCloud and
slow-motion, HDR, ProRes checks, and the v1 gaps above (switching apps stops the run; no "paused" message or automatic
resume). Decide whether to start a new phase for the parked iCloud work.
