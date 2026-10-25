---
gsd_state_version: "1.0"
current_phase: 08
current_phase_name: Interface Redesign
status: in progress
stopped_at: Phase 8 built (build 38) and awaiting a device check and the merge of PR 1
last_updated: "2026-10-26T00:00:00.000Z"
last_activity: 2026-10-26
last_activity_desc: App redesigned and renamed to Mewt Photos; macOS build 38 succeeded
progress:
  total_phases: 8
  completed_phases: 7
  total_plans: 6
  completed_plans: 6
  percent: 88
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-10-11)

**Core value:** Every photo and video on the iPhone reaches the PC as its untouched original, including both halves of Live Photos, and nothing is ever reported as backed up unless the PC has verified it.
**Current focus:** Phase 8 (interface redesign and rename to Mewt Photos) is built; next is a device check of build 38, then merging PR 1. After that: the iCloud-only downloads decision.

## Current Position

Phase: 08 (Interface Redesign) — built, not yet checked on the phone
Status: Phases 1-7 closed. PR [mewtcor/mewtphotos#1](https://github.com/mewtcor/mewtphotos/pull/1) is open with CI green.
Last activity: 2026-10-26 — redesign, new icon, rename, build 38

Progress: [████████░░] 7 of 8 roadmap phases closed (requirements: 51 of 59 complete, see REQUIREMENTS.md)

## Metrics

Per-plan duration metrics were only kept for Phase 1 and are no longer tracked. Builds and device results are in
`docs/ios-builds.md`; phase evidence is in each phase's `*-GATE.md`.

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: Spikes first. Phase 1 (build, install, pair) and Phase 2 (feasibility on the real iPhone) come before any feature work.
- [Roadmap]: Hard gate after Phase 2. If app-exported files are not byte-identical to the USB originals (FEAS-03), stop and re-plan the whole project.
- [Roadmap]: Server patches are Phase 3, Windows-only, can run alongside Phases 1-2, and must finish before Phase 4.
- [Roadmap]: Photos before videos. Phase 5 backs up photos; videos, Live Photos, iCloud and retry follow in Phase 6.
- [Roadmap]: Research "Conflicts to resolve" adopted as written (JSON store, macos-26 with explicit Xcode, NSAllowsLocalNetworking only, Swift 6 core / Swift 5 app, sequential uploads, 8 MiB chunks).
- [Phase 01]: Server vitest runs on windows-latest (engine test asserts Windows case-insensitive filenames); typecheck and guarded iOS steps stay on ubuntu-24.04
- [Phase 01]: Repo mewtcor/mewtphotos is private with default branch main; commits on main allowed (git.allow_default_branch_commits true). The repo was renamed from photosync on 2026-10-26.
- [Phase 01]: Plan 02: Swift Testing works under swift test on Swift 6.4 Linux; NetworkFailure maps URLError to NSURLErrorDomain explicitly so Linux and iPhone agree

- [Phase 08]: Dark-only card theme (`Theme.swift`), violet accent, arch-m icon (`ios/art/`). No wording or logic changes.
- [Phase 08]: Everything renamed to Mewt Photos / MewtPhotos, bundle ID included. The phone pairs once more; the server moves `%LOCALAPPDATA%\PhotoSync` and its database to the new names on first start (tested in `tests/datadir.test.ts`).

### Pending Todos

- Device-check build 38 (Mewt Photos name and icon, new layout, a Back up now run), then merge PR 1.
- Pair the new app, delete the old one from the phone, and rename the iCloud Drive builds folder.
- ~~Device-test Retry (REP-04)~~ Done 2026-10-26: forced failures, retried, phone totals matched the PC.
- ~~Device-verify `c272a40`~~ Done 2026-10-26: passed on the phone (unfinished run picks up photos taken since it started).
- ~~Re-check Live Photo IMG_8068~~ Done 2026-10-26: both halves (HEIC and MOV) are in the backup folder.
- Parked: iCloud-only downloads (CLOUD-01..03); slow-mo, HDR/Dolby Vision, Cinematic, ProRes; edited versions not backed up.
- Known v1 gaps: no "paused" message or automatic resume (UP-04); hidden photos not backed up (LIB-05).

### Blockers/Concerns

- No Mac and no debugger: every device test is push, CI build, AltStore install, try on the phone. Plan on about 25 Mac builds a month until Phase 1 records real billed minutes.
- Largest unknowns are Apple-device behaviours (original bytes from PhotoKit, iCloud-only items, video speed); Phase 2 turns them into measured facts.
- Safari-uploaded items carry no item identity, so the Phase 4 "not on PC" count may shrink once content hashes match at run time.

## Deferred Items

Items acknowledged and deferred, most recent first:

| Category | Item | Status | Deferred At | Milestone |
|----------|------|--------|-------------|-----------|
| Coverage | Hidden photos (LIB-05): the app sees 0 hidden items | Accepted limit | 2026-10-13 | v1 |
| Resilience | "Paused" message and automatic resume (UP-04) | Gap | 2026-10-13 | v1 |
| Originals | Slow-mo, HDR / Dolby Vision, Cinematic, ProRes checks (ORIG-03) | Parked | 2026-10-13 | v1 |
| iCloud | Download iCloud-only items (CLOUD-01..03) | Parked | 2026-10-13 | v1 |
| Edits | Back up edited versions (EDIT-01..04) | v2 | 2026-10-11 | v2 |

## Session Continuity

Last session: 2026-10-26
Stopped at: Phase 8 built (build 38); waiting for the device check and PR 1
Resume file: None
