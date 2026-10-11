# Requirements: PhotoSync

**Defined:** 2026-10-11
**Core Value:** Every photo and video on the iPhone reaches the PC as its untouched original — including both halves of Live Photos — and nothing is ever reported as backed up unless the PC has verified it.

## v1 Requirements

Requirements for the first usable native iPhone app. Each maps to one roadmap phase.
"User" is the single owner of the iPhone and the PC.

### Build & Install

- [x] **BLD-01**: The whole project (server, web pages, iOS app) lives in a private GitHub repository with the lockfile committed
- [x] **BLD-02**: Every push runs the server tests and the iOS logic-package tests on a Linux runner, including a contract test against the real server
- [ ] **BLD-03**: User can start a Mac build manually and download an unsigned `.ipa`; the build fails early if a required permission text is missing from the app
- [ ] **BLD-04**: User can install the `.ipa` on the iPhone with the existing AltStore setup, and re-installing keeps the same app (one fixed bundle ID, no extensions, no entitlements)
- [ ] **BLD-05**: User can export the app's log from the iPhone (share sheet or Files) and it never contains the device key
- [ ] **BLD-06**: User can see the installed app version and build in the app
- [ ] **BLD-07**: The Mac build minutes billed per build are measured and recorded after the first builds

### Feasibility (go / no-go on the real iPhone)

- [ ] **FEAS-01**: The app reaches the PC over plain HTTP on the home network from an AltStore-installed build, and the device key survives relaunch and an AltStore refresh
- [ ] **FEAS-02**: A diagnostics screen lists, for sample items (HEIC, ProRAW/RAW, Live Photo, edited photo, burst, slow-motion, HDR video, iCloud-only item), every stored part with its type, filename, format and size
- [ ] **FEAS-03**: Files exported by the app are byte-identical (same SHA-256) to the originals copied over USB, for at least four kinds of item
- [ ] **FEAS-04**: Native video upload speed to the PC is measured and is clearly faster than the 0.5 MB/s seen in Safari; chunk size and behaviour on screen lock are recorded
- [ ] **FEAS-05**: Behaviour for iCloud-only items, hidden items (with the Hidden album locked) and burst frames is observed and recorded before features are designed around it

### Pairing

- [ ] **PAIR-01**: User can pair by scanning the QR code shown on the PC dashboard
- [x] **PAIR-02**: User can pair by typing the PC address and pairing code instead
- [ ] **PAIR-03**: The device key is stored in the iPhone Keychain and pairing is remembered across launches
- [ ] **PAIR-04**: When the PC cannot be reached, the app names the likely cause in plain English (different Wi-Fi, PC app not running, firewall, Local Network permission off) and links to Settings where relevant
- [ ] **PAIR-05**: User can see which PC is paired, edit its address, and forget it to pair again

### Library Access

- [ ] **LIB-01**: The app asks for photo library access with a clear explanation and handles denied and restricted states with guidance
- [ ] **LIB-02**: With limited ("selected photos") access the app shows a persistent warning and will not run a backup or present a result as complete
- [ ] **LIB-03**: The app notices when access is changed in Settings, at the start of each run and when it returns to the foreground
- [ ] **LIB-04**: Every run considers the user's whole library, newest first
- [ ] **LIB-05**: Hidden photos and videos are included in the backup
- [ ] **LIB-06**: Every frame of a burst is included
- [ ] **LIB-07**: Shared-album items and Recently Deleted items are not backed up
- [ ] **LIB-08**: Before starting, user sees how many items are not on the PC yet

### Originals

- [ ] **ORIG-01**: Every file sent is the stored original, never a converted or re-rendered copy (HEIC stays HEIC, DNG stays DNG, HEVC `.mov` stays as is)
- [ ] **ORIG-02**: Every original part of an item is backed up: photo, video, Live Photo video, RAW alongside JPEG/HEIC, and audio
- [ ] **ORIG-03**: Slow-motion, HDR / Dolby Vision, Cinematic and ProRes videos arrive as their original files
- [ ] **ORIG-04**: Files keep their original names; two different items with the same name are both stored and neither is treated as already backed up
- [ ] **ORIG-05**: The app checks the iPhone's free space before exporting, exports one item at a time, and removes its temporary copies on every path, including after failures and at launch

### Live Photos

- [ ] **LIVE-01**: A Live Photo arrives as two files with the same base name in the same folder on the PC
- [ ] **LIVE-02**: A Live Photo is shown as backed up only when both files are verified by the PC

### iCloud

- [ ] **CLOUD-01**: Items stored only in iCloud are downloaded and backed up, with a visible "downloading from iCloud" state and progress
- [ ] **CLOUD-02**: A download that stalls or fails is abandoned after a timeout, marked unavailable with a reason, and the run continues
- [ ] **CLOUD-03**: Unavailable items are never counted as backed up and are listed separately

### Upload

- [ ] **UP-01**: Items already on the PC are skipped without sending their data, both by item identity and by content
- [ ] **UP-02**: After the app is deleted and re-installed, the next run rediscovers what is already on the PC and sends nothing twice
- [ ] **UP-03**: A large video interrupted mid-transfer continues from where it stopped instead of restarting
- [ ] **UP-04**: When the app is sent to the background, the screen locks, Wi-Fi drops or the PC app restarts, the run shows "paused" and continues when conditions return
- [ ] **UP-05**: The screen stays awake during a run and the app tells the user to keep it open
- [ ] **UP-06**: One failing item never stops the run; short-lived network errors are retried automatically
- [ ] **UP-07**: User can stop a run at any time and a later run picks up cleanly
- [ ] **UP-08**: When the PC reports it is out of space, the run stops with a clear message instead of failing item by item
- [ ] **UP-09**: The PC app does not shut itself down while an app backup is in progress

### Reporting

- [ ] **REP-01**: During a run user sees the current item, item N of M, and what is happening (checking, downloading from iCloud, preparing, sending, verifying on PC)
- [ ] **REP-02**: At the end user sees totals that add up — considered = already on PC + newly verified + failed + unavailable — and the verified count equals the PC's own count; any mismatch is shown
- [ ] **REP-03**: User sees a list of every failed or unavailable item with its name, date and reason
- [ ] **REP-04**: User can retry all failed items or a single one
- [ ] **REP-05**: Errors are worded in plain English
- [ ] **REP-06**: The last run's result is shown when the app is opened
- [ ] **REP-07**: The result states plainly that edited versions of photos are not yet backed up

### PC Server

- [ ] **SRV-01**: Both files of a Live Photo are placed in the same year/month folder with matching base names, even across a month boundary or a name clash
- [ ] **SRV-02**: Hidden items are stored under a separate `Hidden` folder (`Hidden\YYYY\MM\...`)
- [ ] **SRV-03**: The "already backed up?" check confirms the file is still on disk at the expected size, not only that it was recorded
- [ ] **SRV-04**: Re-sending the same item in one session does not create a second record or inflate the session's counts
- [ ] **SRV-05**: When the final move of a file fails, the upload returns to a resumable state without restarting the PC app
- [ ] **SRV-06**: The existing backup database upgrades automatically to the new format with no data loss
- [ ] **SRV-07**: The PC tells the app how much free space it has so the app can stop before preparing a file that will not fit
- [ ] **SRV-08**: The Safari page and Shortcut flows behave exactly as before, proven by the existing tests plus new regression tests

## v2 Requirements

Deferred. Tracked but not in the current roadmap.

### Edits

- **EDIT-01**: Edited photos and videos are also backed up as a separate file beside the original
- **EDIT-02**: An item edited after it was backed up has its new edited version backed up on the next run
- **EDIT-03**: Edited Live Photos keep both edited halves
- **EDIT-04**: Edit instructions (adjustment data) are preserved as a sidecar file

### Speed

- **SPD-01**: The next item is prepared while the current one uploads
- **SPD-02**: Only changes since the last run are scanned, if a full scan proves slow
- **SPD-03**: User sees estimated size and time remaining

### Convenience

- **CONV-01**: An interrupted run resumes automatically after the app is force-closed
- **CONV-02**: Uploads continue with the screen off or the app in the background
- **CONV-03**: The app finds the PC automatically on the network
- **CONV-04**: The connection is encrypted and the PC's identity is pinned at pairing
- **CONV-05**: App logs are sent to the PC dashboard
- **CONV-06**: Days until the AltStore install expires are shown in the app

### Coverage

- **COV-01**: User can see a full comparison of the phone's library against the PC and a "coverage verified" status

## Out of Scope

| Feature | Reason |
|---------|--------|
| Deleting or "freeing up" photos on the iPhone after backup | The phone holds the only other copy; a backup tool must never delete |
| Propagating phone deletions to the PC | Backup is one-way and additive |
| Choosing albums or individual photos to back up | "Back up everything new" is the product; partial selection makes results untrustworthy |
| Format options (HEIC to JPEG, single-file Motion Photo) or compression | Conflicts with the core value of untouched originals |
| Choosing RAW or JPEG | Both are originals; both are kept |
| Shared-album and Recently Deleted items | Not the user's own originals |
| Photo gallery or viewer in the app | Photos and Windows already do this |
| Parallel uploads in v1 | Harder to keep truthful; revisit only on measured need |
| Starting a backup automatically on launch | User chose a deliberate "Back up now" |
| Changes to the Safari page | User chose to keep it as is |
| Paid Apple Developer membership, buying or renting a Mac | Project stays free |
| Cloud storage or any internet-facing service | Local network only |

## Traceability

Which phases cover which requirements. Filled in during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| BLD-01 | Phase 1 | Complete |
| BLD-02 | Phase 1 | Complete |
| BLD-03 | Phase 1 | Pending |
| BLD-04 | Phase 1 | Pending |
| BLD-05 | Phase 1 | Pending |
| BLD-06 | Phase 1 | Pending |
| BLD-07 | Phase 1 | Pending |
| FEAS-01 | Phase 1 | Pending |
| FEAS-02 | Phase 2 | Pending |
| FEAS-03 | Phase 2 | Pending |
| FEAS-04 | Phase 2 | Pending |
| FEAS-05 | Phase 2 | Pending |
| PAIR-01 | Phase 4 | Pending |
| PAIR-02 | Phase 1 | Complete |
| PAIR-03 | Phase 1 | Pending |
| PAIR-04 | Phase 4 | Pending |
| PAIR-05 | Phase 4 | Pending |
| LIB-01 | Phase 4 | Pending |
| LIB-02 | Phase 4 | Pending |
| LIB-03 | Phase 4 | Pending |
| LIB-04 | Phase 4 | Pending |
| LIB-05 | Phase 4 | Pending |
| LIB-06 | Phase 4 | Pending |
| LIB-07 | Phase 4 | Pending |
| LIB-08 | Phase 4 | Pending |
| ORIG-01 | Phase 5 | Pending |
| ORIG-02 | Phase 6 | Pending |
| ORIG-03 | Phase 6 | Pending |
| ORIG-04 | Phase 5 | Pending |
| ORIG-05 | Phase 5 | Pending |
| LIVE-01 | Phase 6 | Pending |
| LIVE-02 | Phase 6 | Pending |
| CLOUD-01 | Phase 6 | Pending |
| CLOUD-02 | Phase 6 | Pending |
| CLOUD-03 | Phase 6 | Pending |
| UP-01 | Phase 5 | Pending |
| UP-02 | Phase 5 | Pending |
| UP-03 | Phase 6 | Pending |
| UP-04 | Phase 5 | Pending |
| UP-05 | Phase 5 | Pending |
| UP-06 | Phase 5 | Pending |
| UP-07 | Phase 5 | Pending |
| UP-08 | Phase 5 | Pending |
| UP-09 | Phase 5 | Pending |
| REP-01 | Phase 5 | Pending |
| REP-02 | Phase 5 | Pending |
| REP-03 | Phase 5 | Pending |
| REP-04 | Phase 6 | Pending |
| REP-05 | Phase 5 | Pending |
| REP-06 | Phase 5 | Pending |
| REP-07 | Phase 5 | Pending |
| SRV-01 | Phase 3 | Pending |
| SRV-02 | Phase 3 | Pending |
| SRV-03 | Phase 3 | Pending |
| SRV-04 | Phase 3 | Pending |
| SRV-05 | Phase 3 | Pending |
| SRV-06 | Phase 3 | Pending |
| SRV-07 | Phase 3 | Pending |
| SRV-08 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 59 total
- Mapped to phases: 59
- Unmapped: 0

---
*Requirements defined: 2026-10-11*
*Last updated: 2026-10-11 after roadmap creation (traceability filled)*
