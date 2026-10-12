# Phase 3: PC server upgrades

Windows server work, additive, so the Safari page and Shortcut flows stay as they are (SRV-08). Every change is
covered by the existing 49 tests plus new tests. Source: `.planning/ROADMAP.md` (Phase 3) and `REQUIREMENTS.md`.

## Plan 03-01: database upgrade and free space (SRV-06, SRV-07)

- `server/db.ts`: a numbered migration step. A database at `user_version` 0 gains the columns the later plans
  need (`uploads.hidden`, `uploads.pair_id`, `uploads.pair_name`) and moves to version 1. Every existing row is kept.
- `shared/schemas.ts`: the status answer includes `freeBytes`, so the app can stop before it prepares a file that
  will not fit (SRV-07).
- Test: a database written in the old format opens, keeps its rows, and gains the new columns.

## Plan 03-02: Hidden folder and Live Photo pairs (SRV-01, SRV-02)

- The sender may mark an upload `hidden` and may give it a `pairId` and `pairName` (the other part's file name).
- Hidden items go under `Hidden\YYYY\MM\...`. Other items are stored exactly as before.
- A Live Photo's two parts share one stem and one folder: the first part to be placed picks a stem that is free for
  both names; the second part reuses the first part's folder and stem.
- Known limit (ponytail): if another file takes the chosen name between the two parts, the second part fails with
  a clear message rather than picking a different name. A race this narrow is accepted.

## Plan 03-03: truthful "already backed up" and no double counting (SRV-03, SRV-04)

- The "already backed up" check (`/assets/check`, `/files/:sha256`) confirms the stored file is still on disk at the
  recorded size, not only that a record exists (SRV-03).
- Sending the same item again in one session returns the existing result and creates no second upload row, so the
  session counts do not grow (SRV-04).

## Plan 03-04: a failed final move can be retried (SRV-05)

- If the final move fails, the upload goes back to `receiving` with its complete temp file, so a retry completes it
  without restarting the PC app. A partial target from a failed cross-drive copy is removed.

## Acceptance

- `npm test` passes: the 49 existing tests plus the new ones (SRV-08).
- Each requirement has a test that fails without its change.
