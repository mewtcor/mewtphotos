# Roadmap: PhotoSync

## Overview

PhotoSync already has a working Windows server and a Safari page. This roadmap adds the native iPhone app that
makes one tap back up everything new as untouched originals, plus a small set of additive server changes. The
journey: first prove on the real iPhone that an app can be built without a Mac, installed with AltStore, reach the
PC and read true original bytes (Phases 1-2); upgrade the server so it can be trusted by a native client
(Phase 3, Windows-only); then grow the app in vertical slices the user can try on the phone: pair and see what is
missing (Phase 4), back up photos with a truthful result (Phase 5), and finish with videos, Live Photos, iCloud
items and retry (Phase 6).

**Go/no-go gates (checked on the real iPhone, written down before the next phase starts):**
- **Gate after Phase 1:** if the unsigned build cannot be installed with AltStore, cannot reach the PC over plain
  HTTP, or loses its device key on relaunch or AltStore refresh (FEAS-01), stop and re-plan the install route.
- **Gate after Phase 2 (hard stop):** if files exported by the app are not byte-identical to the originals copied over
  USB (FEAS-03), the project stops and the whole roadmap is re-planned from the Phase 2 findings. No later phase
  proceeds as written. If video upload is not clearly faster than Safari's 0.5 MB/s (FEAS-04), photos (Phases 4-5)
  may continue but Phase 6 is re-planned before any video work starts.

**Delivery rules for every app phase (no Mac, no debugger, limited Mac build minutes):**
- Logic (state machine, planner, naming, reconciliation, retry rules) goes into the pure Swift package and is tested
  on a Linux runner on every push. The app target only adapts Apple APIs.
- Mac builds are manual and batched: one build carries everything written since the last one. Plan around about
  25 Mac builds a month until the billed minutes measured in Phase 1 say otherwise.
- Every phase that needs the phone ends with a short device test the user runs on the real iPhone from an
  AltStore-installed build; the success criteria below are those tests.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Build, Install and Pair** - Walking skeleton: Linux CI, Mac build to `.ipa`, AltStore install, manual pairing, plain-HTTP reach, Keychain, log export
- [ ] **Phase 2: Feasibility on the Real iPhone** - Go/no-go: stored parts per item type, byte-identical originals, video speed, iCloud/hidden/burst behaviour
- [ ] **Phase 3: PC Server Upgrades** - Windows-only additive server changes so a native client gets truthful answers and Live Photo pairs stay together
- [ ] **Phase 4: Pair and See What's Missing** - QR pairing, library access handling, and a read-only count of what the PC does not have yet
- [ ] **Phase 5: Back Up Photos** - "Back up now" sends every photo as its original, with live progress and a result the PC confirms
- [ ] **Phase 6: Videos, Live Photos, iCloud and Retry** - Complete library coverage, resumable large videos, iCloud downloads, retry

## Phase Details

### Phase 1: Build, Install and Pair
**Goal:** User can build the iPhone app on GitHub Actions without a Mac, install it with AltStore, pair it with the PC by typing address and code, and see it reach the PC over plain HTTP.
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: BLD-01, BLD-02, BLD-03, BLD-04, BLD-05, BLD-06, BLD-07, FEAS-01, PAIR-02, PAIR-03
**Success Criteria** (what must be TRUE):
  1. Every push to the private GitHub repository runs the server tests and the iOS logic-package tests on a Linux runner, including a contract test against the real server, and the user can see the result go green.
  2. User starts a Mac build by hand and downloads an unsigned `.ipa`; the build stops early with a clear message if a required permission text is missing from the app; the billed Mac minutes of the first builds are recorded.
  3. User installs the `.ipa` on the iPhone with the existing AltStore setup, sees the app version and build inside the app, and re-installing over it keeps the same single app (no second icon, data kept).
  4. User types the PC address and pairing code into the app, the app reaches the PC over plain HTTP on the home network, and the pairing is still there after quitting and relaunching the app and after an AltStore refresh.
  5. User exports the app's log from the iPhone through the share sheet or Files, and the log does not contain the device key.
**Plans**: 6 plans

Plans:
- [ ] 01-01-PLAN.md — Private GitHub repo (name confirmed first), Linux CI on every push (typecheck + vitest) and the permission-text gate with negative controls
- [ ] 01-02-PLAN.md — Swift pairing client against the real server on Linux (transport, redacting DeviceKey, ServerClient, strict address parser, contract tests)
- [ ] 01-03-PLAN.md — Remembered pairing: PairingFlow, pairing.json, scrubbed RunLog (real-server relaunch test)
- [ ] 01-04-PLAN.md — SwiftUI app target: XcodeGen spec, bundle ID decision, Keychain adapter, pair form, launch evidence, version row, log export
- [ ] 01-05-PLAN.md — Mac build to unsigned .ipa (two builds from one commit, explicit dispatches only), artifact checks, builds and minutes table
- [ ] 01-06-PLAN.md — Single-session device test on the real iPhone and the go/no-go note (01-GATE.md)
**UI hint**: yes

### Phase 2: Feasibility on the Real iPhone
**Goal:** User knows, from measurements on the real iPhone, that the app can read byte-identical originals and upload video at a usable speed, before any feature is built on that assumption.
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: FEAS-02, FEAS-03, FEAS-04, FEAS-05
**Success Criteria** (what must be TRUE):
  1. User opens the diagnostics screen on the installed build and sees, for sample items (HEIC, ProRAW/RAW, Live Photo, edited photo, burst, slow-motion, HDR video, iCloud-only item), every stored part with its type, filename, format and size.
  2. User exports at least four kinds of item through the app, copies the same originals from the iPhone to the PC over USB, and the SHA-256 of each exported file equals the SHA-256 of its USB original. A written go/no-go note records the result; any mismatch stops the project and the roadmap is re-planned (hard gate).
  3. User uploads a large video from the app to the PC and the measured speed is recorded and clearly faster than the 0.5 MB/s seen in Safari, together with the chunk size used and what happens when the screen locks.
  4. The observed behaviour of an iCloud-only item, a hidden item (with the Hidden album locked) and burst frames is written down before Phases 4-6 are designed around it.
**Plans**: TBD
**UI hint**: yes

### Phase 3: PC Server Upgrades
**Goal:** The Windows server keeps Live Photo pairs together, separates Hidden items, answers "already backed up?" truthfully, and recovers from failed moves, with the Safari page and Shortcut flows unchanged.
**Mode:** mvp
**Depends on**: Nothing (Windows-only server work; can run alongside the early device phases, for example while a build or phone test is pending)
**Requirements**: SRV-01, SRV-02, SRV-03, SRV-04, SRV-05, SRV-06, SRV-07, SRV-08
**Success Criteria** (what must be TRUE):
  1. Sending both files of a Live Photo to the server, even across a month boundary or when a name clash exists, leaves two files with matching base names in the same year/month folder on the PC.
  2. An item sent as hidden is stored under `Hidden\YYYY\MM\...` on the PC, and items not marked hidden are stored exactly as before.
  3. Asking the server "already backed up?" about an item whose file was deleted or shortened on the PC answers "not backed up"; re-sending the same item within one session creates no second record and does not inflate that session's counts.
  4. An upload whose final move fails returns to a resumable state and completes on retry without restarting the PC app; a backup database from before this change upgrades automatically with every row intact; the PC reports how much free disk space it has.
  5. The Safari page and Shortcut flows behave exactly as before: the existing 49 tests plus new regression tests all pass.
**Plans**: TBD

### Phase 4: Pair and See What's Missing
**Goal:** User can pair by scanning the dashboard QR code, grant full photo access, and see how many items in the whole library the PC does not have yet, without anything being sent.
**Mode:** mvp
**Depends on**: Phase 2 (go decision and recorded findings), Phase 3
**Requirements**: PAIR-01, PAIR-04, PAIR-05, LIB-01, LIB-02, LIB-03, LIB-04, LIB-05, LIB-06, LIB-07, LIB-08
**Success Criteria** (what must be TRUE):
  1. User scans the QR code on the PC dashboard (or types address and code instead) and the app pairs; the app shows which PC is paired, lets the user edit its address, and lets the user forget it and pair again.
  2. When the PC cannot be reached, the app names the likely cause in plain English (different Wi-Fi, PC app not running, firewall, Local Network permission off) and links to Settings where that is the fix.
  3. The app asks for photo library access with a clear explanation, shows guidance when access is denied or restricted, and with "selected photos" access shows a persistent warning and refuses to run or present anything as complete; changing the setting in Settings is noticed at the start of a run and when the app returns to the foreground.
  4. Before starting, user sees how many items are not on the PC yet, counted over the whole library and listed newest first, including hidden items and every frame of a burst, and leaving out shared-album and Recently Deleted items.
**Plans**: TBD
**UI hint**: yes

### Phase 5: Back Up Photos
**Goal:** User taps "Back up now" and every photo not yet on the PC arrives as its untouched original, with live progress and a result that matches what the PC verified.
**Mode:** mvp
**Depends on**: Phase 4
**Requirements**: ORIG-01, ORIG-04, ORIG-05, UP-01, UP-02, UP-04, UP-05, UP-06, UP-07, UP-08, UP-09, REP-01, REP-02, REP-03, REP-05, REP-06, REP-07
**Success Criteria** (what must be TRUE):
  1. On the real iPhone, user taps "Back up now" and each photo not on the PC arrives as its stored original (HEIC stays HEIC, DNG stays DNG, a RAW+JPEG pair arrives as both files), under its original name, hidden photos under the PC's `Hidden` folder and every burst frame included; two different photos with the same name are both stored.
  2. Photos already on the PC are skipped without sending their data, by item identity and by content, and after deleting and re-installing the app the next run finds what the PC already has and sends nothing twice.
  3. During the run user sees the current item, item N of M and what is happening (checking, preparing, sending, verifying on PC); the screen stays awake with a "keep this open" message; user can stop at any time and a later run picks up cleanly.
  4. Sending the app to the background, locking the screen, dropping Wi-Fi or restarting the PC app shows "paused" and the run continues when conditions return; the PC app does not shut itself down mid-run; a full PC disk stops the run with one clear message; one failing photo never stops the run and the phone's free space is checked before each export, with no temporary copies left after a failure, a stop or the next launch.
  5. At the end user sees totals that add up (considered = already on PC + newly verified + failed + unavailable), the verified count equals the PC's own count and any mismatch is shown; every failed or unavailable item is listed with name, date and a plain-English reason; the last result is shown when the app is reopened; the result states that edited versions of photos are not yet backed up. In this phase videos, Live Photos and iCloud-only items are listed as unavailable with the reason "not supported in this version yet" and are never counted as backed up.
**Plans**: TBD
**UI hint**: yes

### Phase 6: Videos, Live Photos, iCloud and Retry
**Goal:** User's whole library is covered: videos, both halves of Live Photos and iCloud-only items arrive as originals, interrupted large videos resume, and failed items can be retried.
**Mode:** mvp
**Depends on**: Phase 5 (also relies on the Phase 3 server work and the Phase 2 findings)
**Requirements**: ORIG-02, ORIG-03, UP-03, LIVE-01, LIVE-02, CLOUD-01, CLOUD-02, CLOUD-03, REP-04
**Success Criteria** (what must be TRUE):
  1. On the real iPhone, user's videos arrive as their original files, including slow-motion, HDR / Dolby Vision, Cinematic and ProRes clips, and every original part of an item arrives (video, Live Photo video, RAW beside JPEG/HEIC, audio).
  2. A Live Photo arrives as two files with the same base name in the same folder on the PC, and the app shows it as backed up only when the PC has verified both files.
  3. A large video interrupted mid-transfer (for example by switching Wi-Fi off or restarting the PC app) continues from where it stopped instead of starting again.
  4. An item stored only in iCloud shows "downloading from iCloud" with progress and is backed up; a download that stalls or fails is given up after a timeout, marked unavailable with a reason, the run carries on, and unavailable items are listed separately and never counted as backed up.
  5. User can retry all failed items or a single one from the list, and the totals still add up and still match the PC's count afterwards.
**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6. Phase 3 has no dependency on Phases 1-2 and can be done at
any point while a build or phone test is pending, but it must be finished before Phase 4. Phases 4 and later do not
start until the Phase 2 go/no-go note says go.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Build, Install and Pair | 0/6 | Planned | - |
| 2. Feasibility on the Real iPhone | 0/TBD | Not started | - |
| 3. PC Server Upgrades | 0/TBD | Not started | - |
| 4. Pair and See What's Missing | 0/TBD | Not started | - |
| 5. Back Up Photos | 0/TBD | Not started | - |
| 6. Videos, Live Photos, iCloud and Retry | 0/TBD | Not started | - |

## Planning Notes

**Research resolutions adopted** (from `.planning/research/SUMMARY.md` "Conflicts to resolve"; apply when planning):
- Local state is small atomic JSON files behind an `Inventory` actor and reducer; the server is the inventory. No GRDB in v1 (Phases 4-6).
- CI Mac runner is `macos-26` with an explicit Xcode 26.x selection printed in the log; never `macos-latest` or large runners; re-check the label in Phase 1.
- ATS: `NSAllowsLocalNetworking` only; Phase 1 proves plain-HTTP reach to the PC's IP, and widens only if that fails, recording why.
- Swift 6 mode for the pure Swift package (checked on Linux), Swift 5 for the app target (`SWIFT_VERSION` set per target).
- No change-token / `changes(since:)` in v1; scan time is measured in Phase 2 and only a scan over about 10 s reopens it.
- Edited renders are not uploaded in v1 (shown in the result summary); the resource-key scheme `<localIdentifier>#<kind>` (plus `@<modEpoch>` for mutable kinds) is built in Phase 5 so adding them later needs no migration; confirm the server accepts keys of that form (max 200 characters) in Phase 3.
- Uploads are sequential, 8 MiB chunks; Phase 2 measures 32 MiB and 1 vs 2 workers, and changes only on data.
- Server patch scope in Phase 3 is the union of the research lists, each with its own test; the app's `GET /status` heartbeat (about every 60 s, for the PC's idle auto-stop) is client-side work in Phase 5.
- Temp exports go to `temporaryDirectory`, marked excluded from backup and wiped at launch.
- The repository stays private as decided; if the monthly Mac allowance runs out, making it public or using another CI host is the user's call.

**Server work must be done before the app relies on it:** the truthful "already backed up?" check (SRV-03) before the Phase 4 counts; the Hidden folder (SRV-02), free-space reporting (SRV-07) and idempotent sessions (SRV-04) before Phase 5; Live Photo placement (SRV-01) before Phase 6. Phase 3 is scheduled as a whole before Phase 4 for simplicity.

**Open points for planning:**
- The "not on the PC yet" count in Phase 4 can only use item identity until a file is exported and hashed; items first sent through the Safari page carry no item identity, so the count may shrink at run time once content matches are found.
- Phase 5 treats videos, Live Photos and iCloud-only items as "unavailable: not supported in this version yet" so the totals stay truthful until Phase 6. If the user would rather have videos in Phase 5, move them there and keep resume and iCloud in Phase 6.

---
*Roadmap created: 2026-10-11*
