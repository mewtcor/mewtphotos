# Phase 5 gate: back up photos

Status: **open**. Not closed until the device checks below pass on the iPhone. Phase 6 does not start until this is closed.

Builds tested: 18 (first device run), 19 (screen: current item, failure dates), 20 (PC count for this iPhone; the count line
needed a PC server restart before it appeared). Commits: `8e5f50c`, `e517d66`, plus the message change after build 20.

## Checked on the device

| Check | Build | Result |
|-------|-------|--------|
| Back up now sends photos and the totals match the PC log | 18 | Pass: 26 sent, 2 already on PC; PC log agreed |
| Second run sends nothing: verified 0, already on PC 1015, finished | 20 | Pass. 4064 = 1015 + 0 + 0 + 3049. The PC holds 1,015, which matches the phone |
| Stop midway, then Back up now carries on from the same place | 18 | Pass: 989 pending after the stop, then the run continued |
| Current item and item N of M shown while running | 19 | Pass: "Item 4035 of 4064: IMG_7953.JPG" |
| Keep-awake note shown while running | 19 | Pass |
| Failed and unavailable rows show a date | 19 | Pass |
| PC count line shows "The PC holds N of this iPhone's photos." | 20 | Pass after the PC server restart; before the restart the server returned 404 and the line was hidden |
| Failure message when the PC count cannot be checked | after 20 | Not yet on a device; next build |
| Burst of 6 frames: every frame is listed, stored and verified on the PC (IMG_8100 to IMG_8105) | 25 | Pass. Build 24 failed to compile (a name clash) and was fixed; build 25 was the first to carry the fix. Before the fix only IMG_8104 arrived and the other five showed "no longer in the library" |

## Not yet checked on the device


- **RAW (DNG) beside a JPEG or HEIC:** the PC stores the original with its own name.
- **Restricted access (Screen Time):** carried over from Phase 4.
- **Phone totals match the PC's count** after a full run (REP-02). The PC count line is in; the comparison is manual.

## Known gaps, carried into Phase 6

- **Hidden photos are not backed up (accepted limit, not a pass).** On builds 22 and 23 the app sees 0 hidden photos,
  even though the Hidden album holds IMG_4304 and IMG_5959. Reading the Hidden album directly also gave 0. The PC never
  receives them. The owner chose to accept this for now (option 2). Revisit before calling the library "complete".

- Videos are listed as "not supported in this version yet" (about 3000 items).
- Live Photos send only the still photo. IMG_8068.HEIC is a Live Photo and shows as not supported for that reason.
  It is not an iCloud-only item; the phone has the original on device.
- Items that exist only in iCloud are reported as not supported, not as "downloading from iCloud". That is Phase 6 (CLOUD-01..03).

## Decision

Open. The remaining device checks (burst, RAW beside JPEG or HEIC, restricted access) must pass before this gate closes.
Hidden photos are an accepted gap for now, recorded above. Requirements ORIG-01, ORIG-04, ORIG-05, UP-01, UP-02,
UP-04 to UP-09, REP-01, REP-02, REP-03, REP-05, REP-06, REP-07 are covered by the checks marked Pass. ORIG-02 and
ORIG-03 belong to Phase 6.
