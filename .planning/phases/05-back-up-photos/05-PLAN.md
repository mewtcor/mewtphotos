# Phase 5: Back up photos

Goal: "Back up now" sends every photo not on the PC as its untouched original, with live progress and a result the
PC confirms. Videos, Live Photos and iCloud-only items are listed as unavailable ("not supported in this version
yet") and are never counted as backed up (Success criterion 5).

Requirements: ORIG-01, ORIG-04, ORIG-05, UP-01, UP-02, UP-04, UP-05, UP-06, UP-07, UP-08, UP-09, REP-01, REP-02,
REP-03, REP-05, REP-06, REP-07. UP-03 and REP-04 are Phase 6.

Rule for every plan: logic goes in `PhotoSyncCore` and is tested on Linux; the app target only adapts PhotoKit,
the screen and the background transfer.

## Plan 05-01: the planner and the totals (REP-02, UP-01, ORIG-04, REP-07)

Pure logic, no PhotoKit.
- Input: the library items (identifier, file name, kind, hidden flag, a count of parts) and the set of identifiers the
  PC already holds.
- Output: for each item one decision: `alreadyOnPC`, `send` (a photo), or `unavailable` with a plain reason
  (`video`, `livePhoto`, `iCloudOnly`: "not supported in this version yet").
- Totals: considered = already on PC + newly verified + failed + unavailable. The check that the parts add up is a
  function, so the screen cannot show a total that does not add up.
- The result text states that edited versions of photos are not yet backed up (REP-07).
- Tests: every item lands in exactly one bucket; totals add up; a video, a Live Photo and an iCloud-only item are
  never "send"; a burst frame and a hidden item are planned like any other photo.

## Plan 05-02: the run record kept on the phone (UP-07, UP-06, REP-06)

- A run is a list of items with a state each (`pending`, `sent`, `verified`, `failed`, `unavailable`) and a reason.
- The record is written to a file after each item, so a stopped or killed run resumes from the next pending item.
- Only `verified` (or the PC's `duplicate`) is shown as backed up (the project's truthfulness rule).
- The last result is kept so it can be shown when the app is reopened (REP-06).

## Plan 05-03: export, check space, send one item at a time (ORIG-01, ORIG-05, UP-02, UP-06)

- The app checks the phone's free space before each export, exports one original at a time, and deletes its
  temporary copy on every path (success, failure, stop, next launch).
- The hash is computed before sending, so the PC can answer "already backed up" without the bytes moving (UP-01,
  UP-02). This uses the background transfer built in Phase 2.
- One failing item never stops the run. Short network errors are retried.

## Plan 05-04: the screen (REP-01, REP-03, REP-05, UP-05)

- "Back up now", the current item, item N of M, and what is happening.
- The screen stays awake (`isIdleTimerDisabled`) with a "keep this open" message.
- Stop at any time. Failed and unavailable items are listed with name, date and a plain reason.
- A paused state when the app is in the background, the phone locks, or Wi-Fi drops (UP-04).

## Acceptance (device)

- Back up a set of photos, including a RAW (DNG), a HEIC, a hidden photo and a burst. Check the PC stores them as
  originals with their names, and the phone's totals match the PC's count.
- Run it twice. The second run sends nothing.
- Stop midway, then resume. The run carries on from where it stopped.
