# Phase 7 gate: library coverage report

Status: **closed (go)** on 2026-10-13, with the gap below recorded. Build 34 (commit `728ffb1`) is the first build with the
coverage section.

## What was built

- **PC:** `GET /api/v1/assets/held` returns every asset identifier the PC holds for this iPhone. It shares one rule with
  `/assets/count`: an asset counts only while its stored copy is still on disk at the recorded size. Covered by a test in
  `tests/truthful.test.ts`.
- **Phone:** the Back up photos screen has a **Coverage** section. It shows whether every library photo is on the PC, the
  photos that are not (first 20 by name), how many library photos the PC holds, and how many photos the PC keeps that are
  no longer on the phone. The last number is information only: the PC keeps deleted photos on purpose.
- **Unit tests:** `CoverageTests` in the MewtPhotosCore package cover the comparison, with and without missing items.

## Checked on the device

| Check | Build | Result |
|-------|-------|--------|
| Coverage section appears and lists the photos the PC lacks | 34 | Pass. First read: 3 of 4,083 missing (IMG_8127.PNG, IMG_8125.WEBP, and a UUID-named PNG) |
| The missing photos reach the PC and are verified after a run | 34 | Pass. All three verified in the next run (run considered 4,083, already on PC 4,080, verified 3) |
| Coverage reads "Coverage verified: every photo in the library is on the PC." | 34 | Pass |
| Counts agree: library 4,083, PC holds 4,083 | 34 | Pass |

## Known gap (recorded, not a pass)

- **An unfinished run does not pick up photos taken after it started.** The first run had considered 4,080 items. The
  library grew to 4,083 while that run was unfinished, and continuing it kept the original list, so the three new photos
  were missed until a new run started. Coverage correctly showed them as missing. Fix: when an unfinished run is continued,
  add the library items it does not yet list. Not yet changed.

## Notes for use

- The PC server must be restarted after an update that adds an endpoint. Until it was, the coverage check reported that it
  could not reach the PC.
- Coverage uses the same identifiers as the backup. It does not look at file contents.

## Decision

Closed (go). Phase 7 does the report it was planned for. The unfinished-run gap is carried forward to the next change.
