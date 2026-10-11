# Project Research Summary

**Project:** PhotoSync iOS companion (native iPhone client for the existing Windows/Node backup server)
**Domain:** Native iPhone photo-backup client (SwiftUI, PhotoKit, URLSession), one-way and additive, LAN only, foreground only, built on GitHub Actions and sideloaded with AltStore
**Researched:** 2026-10-11
**Confidence:** MEDIUM

## Executive Summary

PhotoSync adds a native iOS app to a server that already works. The app enumerates the whole library, exports each resource as stored original bytes via `PHAssetResourceManager.writeData`, skips what the PC already holds, and uploads the rest over the existing resumable `/api/v1` protocol. The server is the source of truth: `/assets/check` and `sha256` on create say what is already stored, so local state is only a cache plus a failure list. Experts building this class of tool take whole-library scope, read resources rather than renders, and let the server decide what counts as backed up.

Recommended approach: a thin Apple-only app target over a pure Swift package (`PhotoSyncCore`) that builds and tests on Linux at low CI cost. Logic (state machine, retry rules, planner, naming, reconciliation) lives in Core behind protocols. XcodeGen generates the project (no committed `.xcodeproj`); an unsigned `.ipa` is built with `xcodebuild` on a pinned `macos-26` runner; zero third-party Swift packages in v1; persistence is small JSON files. Build spikes first: prove toolchain, install path, LAN HTTP and original bytes on the real iPhone before features. There is no Mac, no debugger, and about 200 macOS minutes a month on a private repo, so blind compile errors are expensive.

Key risks: false "backed up" results; partial library shown as complete (limited access, default fetch options); iCloud-only items stalling; AltStore free-account limits (7-day expiry, 3 active apps, 10 App IDs per week) and identity churn; known server bugs the native client will trigger (`finalizing` stuck until restart, `/assets/check` trusting the DB, 507 disk-full, auto-stop during device-side work). Each has a roadmap mitigation. Largest unknown: video throughput (Safari about 0.5 MB/s for video vs about 3.5 MB/s for photos; cause not established).

## Key Findings

### Recommended Stack
- Swift 5 language mode in the app target; SwiftUI with `@Observable`; iOS 18.0 deployment target; PhotoKit; CryptoKit streaming SHA-256; URLSession foreground `.default`, 8 MiB PATCH chunks (matches server `CHUNK_SIZE`); Keychain (`kSecClassGenericPassword`, `AfterFirstUnlockThisDeviceOnly`) for the device key only; VisionKit `DataScannerViewController` for QR; `os.Logger` plus an app-owned rotating log file.
- XcodeGen 2.46.0 generates the project from `project.yml`. `xcodebuild build` with signing disabled, then zip `Payload/` to `.ipa`. `actions/checkout@v7`, `actions/upload-artifact@v7` with `retention-days: 7`. Linux Swift job on every push; macOS build only on `workflow_dispatch` or tag.
- Runner `macos-26`, Xcode 26.x (default 26.6), explicitly selected and printed in logs.
- No entitlements file. Photos, Local Network, camera and ATS are Info.plist keys only.
- AltStore: one bundle ID, no extensions, install over the existing app. Limits: 7-day expiry, 3 active apps, 10 App IDs per 7 days.
- Persistence: Codable JSON in Application Support (atomic writes). No SwiftData or Core Data. GRDB 7.11.1 only if a measured need appears.

### Expected Features
Trust rule: an item is shown as backed up only when the server returned `verified` or `duplicate`.
- **Must have (v1):** build diagnostics and log export (BLD-1, BLD-2); pairing by QR plus manual fallback, Keychain, preflight naming the cause, editable address (PAIR-1 to PAIR-4); `.readWrite` access, limited access blocks the run, full enumeration newest first, hidden assets and all bursts included, user-library source types only, "N items not on PC" before run (LIB-1 to LIB-8); `writeData` originals only, all original-side resources, no conversion, no name-based identity, temp cleanup, free-space guard (ORIG-1 to ORIG-6); Live Photo as two same-folder files, backed up only when both verify (LIVE-1, LIVE-2); iCloud download with watchdog and "unavailable" with reason (CLOUD-1 to CLOUD-3); `/assets/check` batches, `sha256` on create, resumable video, interruption handling, keep-awake, one bad item never stops the run, clean cancel, sequential uploads (UP-1 to UP-8); live phased progress, reconciling summary, attention list with reasons, retry, persisted last result (REP-1 to REP-6).
- **Should have (v1.x):** edited renders as `IMG_E<nnnn>` siblings (DIFF-1, DIFF-9); re-back-up of edited assets (DIFF-3); resume after kill (DIFF-6); pipelining (DIFF-4) if speed disappoints.
- **Defer (v2+):** adjustment sidecars (DIFF-2), change tokens unless scan is measured slow (DIFF-5), size/time estimates (DIFF-7), reconciliation (DIFF-10), background runs, Bonjour, HTTPS pinning.
- **Anti-features:** delete or free-up after backup; propagate phone deletions; album pickers; format options (HEIC to JPEG, Motion-Photo JPEG); compression; RAW-vs-JPEG choice; shared-album or Recently Deleted items; gallery UI; manual picker; "select more photos" flow; parallel uploads; auto-run on launch; local-only "backed up" flags.

### Architecture Approach
`PhotoSyncCore` (local Swift package, Swift 6 mode, builds on Linux) holds all logic. The app target only adapts Apple APIs to protocols. Only `Sendable` value types cross actors; `PHAsset`/`PHAssetResource` never leave the adapter.
1. **`BackupCoordinator` (actor):** scan, plan, create session, upload loop, complete, reconcile; throttled `RunSnapshot` stream.
2. **`PhotoLibraryProviding` / `PhotoKitLibrary`:** enumerates `AssetDescriptor` values with resource descriptors.
3. **`Planner` and `ResourceNaming` (pure):** skip, check, or export+upload per resource; keys, upload names, ordering.
4. **`Inventory` (actor):** per-resource state; `ResourceState.apply(event)` is the truth gate; `confirmed` reachable only from server events.
5. **`ServerClient`, `ResumableUploader`, pure `UploadMachine`:** typed `/api/v1` calls; create, chunk, resync, finish; maps 409, 422, 413, 507, 415.
6. **`ResourceExporting` + `TempStore`:** one resource to a temp file; orphan sweep at launch.
7. **`Reconciler` (pure):** app-confirmed counts vs `GET /sessions/:id`; mismatches shown.
8. **`RunLog` (actor):** rotating, exportable, never logs the device key.

### Critical Pitfalls
1. **Blind-coding burns macOS minutes.** Keep logic in Core and gate it on Linux; batch changes; macOS job manual.
2. **Project plumbing and unsigned packaging fail only on CI.** XcodeGen; PlistBuddy gate on required keys; `unzip -l` check.
3. **Identity churn and AltStore limits.** One bundle ID; install over top; show days to expiry; refuse long runs with under about 12 h left; never rely on local state.
4. **False "backed up".** `/assets/check` answers from DB, not disk. Reducer truth gate; treat `known` as "recorded" until S2; Reconciler banner.
5. **Limited access and default fetch options.** Refuse to run under `.limited`; set hidden, burst and source-type options explicitly; `libraryCount` only under full access.
6. **Live Photo halves split on PC.** Server S1 (`groupId`, folder pinned to sibling); test with month-boundary capture and name collision.
7. **Server bugs.** Stuck `finalizing`; 507 per item; 415 on unlisted extensions; auto-stop after 5 min without API traffic. Server patches first; stop run on 507; `GET /status` heartbeat about every 60 s.

## Implications for Roadmap

### Phase 0: Foundations (Windows/Linux only)
- **Delivers:** private repo with existing project; `server.yml`; `PhotoSyncCore` skeleton with Wire types; fixtures from real server; `tests/contract/serve.ts`; `tests/wire-fixtures.test.ts`; Linux `swift test` green with one contract test.
- **Avoids:** Pitfall 1. **Flag:** Light. Confirm Linux Swift toolchain and WSL2; confirm no GRDB needed.

### Phase 1: Spike A, toolchain, install, LAN, Keychain (first macOS builds)
- **Delivers:** `project.yml`; `ios-build.yml` with PlistBuddy gate and unsigned `.ipa`; AltStore install; `GET /health` over plain HTTP to PC; manual URL and code pairing; `/status`; Keychain survives relaunch and refresh; log ring buffer with launch marker, `ShareLink` export, version display; recorded billed minutes.
- **Addresses:** BLD-1, BLD-2, PAIR-2. **Avoids:** Pitfalls 2–6, 25.
- **Flag:** Yes. Unsigned IPA via AltStore, Keychain under re-sign, IP-literal ATS, Local Network prompt, iOS 18.4 bug.
- **Pass:** launches on iOS 18+; plain-HTTP reaches PC; log export works; Keychain survives refresh.

### Phase 2: Spike B, PhotoKit reality and go/no-go
- **Delivers:** resource dump (type, filename, UTI, size) for HEIC, ProRAW, RAW+JPEG, Live, edited, burst, slo-mo, HDR, Cinematic, iCloud-only; `writeData` bytes checked by magic bytes and SHA-256 against USB originals; hidden and burst fetch counts; scan time with and without resources; iCloud-only export behaviour; throughput at 8 vs 32 MiB and 1 vs 2 workers; screen-lock behaviour.
- **Addresses:** ORIG-1 to ORIG-5, LIB-5 to LIB-7, CLOUD-1/2 proof. **Avoids:** Pitfalls 8, 9, 13, 14, 19.
- **Flag:** Yes, main unknown.
- **Pass/fail (set before spike):** originals byte-identical for four asset kinds; video throughput clearly above 0.5 MB/s; iCloud items download or fail with a signal. **If originals fail, stop and re-plan.**

### Phase 3: Server patches (Windows; parallel with Phases 1–2)
- **Delivers:** S1 `groupId` with folder pinned to sibling; S2 `/assets/check` stats file and compares size; S4 idempotent `POST /uploads` per asset per session; S5 `PRAGMA user_version` migration; `place()` rollback to `receiving` on rename failure; 415 as terminal "server rejects type"; `freeBytes` in `ClientStatus`; optional O1 log ingest; `docs/api.md` counting units.
- **Addresses:** UP-1, REP-2, LIVE-1, UP-2. **Avoids:** Pitfalls 11, 21, 22.
- **Flag:** No. S2 and S4 change behaviour the Safari page sees; add regression tests and confirm Safari flows are unchanged.

### Phase 4: Core engine on Linux
- **Delivers:** `ServerClient`; `UploadMachine` and `ResumableUploader` (8 MiB chunks, resync on 409, 10-minute finish timeout); `ResourceState` reducer with exhaustive "confirmed only from server event" test; `Planner`; `ResourceNaming`, `ResourceKey` (reserve mutable-kind suffix); `Reconciler`; sequential `BackupCoordinator`; JSON-backed `Inventory` actor; `RunLog`; `FakePhotoLibrary` (50 assets); T1–T4 tests incl. contract test for Live Photo same-folder.
- **Addresses:** UP-1 to UP-8 logic, ORIG-4, LIB-4, LIB-8 logic, REP-2 logic. **Avoids:** Pitfalls 12, 15, 16, 17, 22.
- **Flag:** No.

### Phase 5: App v1, pair and back up photos
- **Delivers:** PhotoKit adapter; QR via DataScanner plus manual entry; PAIR-3 preflight; editable address; Keychain; full-access gate; `scenePhase` handling; idle timer with "keep open, plugged in" banner; cancel; `GET /status` heartbeat about every 60 s; Pair, Backup, Issues, Log views; phased progress and reconciling summary; space guard.
- **Addresses:** PAIR-1 to PAIR-4, LIB-1 to LIB-3, ORIG-1 to ORIG-3, ORIG-6, UP-4, UP-5, UP-7, REP-1, REP-2, REP-5. **Avoids:** Pitfalls 7, 8, 9, 19, 20, 23, 26.
- **Flag:** Partial. Scanner availability; scene-phase timing.

### Phase 6: Videos, Live Photos, iCloud, retry
- **Delivers:** resumable video from server offset (UP-3); `.video` and `.pairedVideo` roll-up (LIVE-1, LIVE-2); iCloud download with progress, about-120 s stall watchdog and "unavailable" with reason (CLOUD-1 to CLOUD-3); Issues list with retry and reconciliation before retry (REP-3, REP-4); "Re-check with PC"; breakers on 507 and repeated `not_receiving`.
- **Avoids:** Pitfalls 10, 11, 13, 14, 16, 21, 27.
- **Flag:** Yes for resource shape and iCloud error codes.

### Phase 7: Measurement-driven optimisations (no commitment)
- Change token only if full scan exceeds about 10 s; pipelining if speed disappoints; streaming hash; chunk and worker tuning; GRDB only if JSON state too slow at roughly 30k+ resources; `POST /diagnostics`. Each needs its own spike.

**v1.x:** edited renders (DIFF-1, DIFF-9) with resource-key scheme reserved in Phase 4; DIFF-3; DIFF-6.
**v2+:** DIFF-2, DIFF-7, DIFF-10, background runs, Bonjour, HTTPS with pinning.

### Phase Ordering Rationale
- Spikes before features: Phases 1–2 decide viability and naming/resource rules.
- Server patches early and in parallel: needed for truthful `known` and Live Photo folders; Core contract tests depend on them.
- Core before app: logic tested at 1x cost; app target stays thin.
- Photos before videos: truth model proven before large-file and iCloud problems.

### Research Flags
- **Needs deeper research or spike:** Phase 1 (AltStore unsigned install, Keychain under refresh, ATS and Local Network); Phase 2 (resource naming, `writeData` fidelity, iCloud, throughput); Phase 5 (scanner, scene phase); Phase 6 (edit and Live resource shape, iCloud errors).
- **Standard patterns:** Phase 0 (Linux Swift package setup); Phase 3 (additive server changes, read code); Phase 4 (pure state machines, test-first).

## Conflicts to resolve

### 1. Local persistence in v1
- **A (STACK, PITFALLS):** No database; small Codable JSON files; server is the inventory.
- **B (ARCHITECTURE):** GRDB `Inventory` actor as durable per-resource ledger.
- **Resolution:** A for v1. Keep the `Inventory` actor and reducer as ARCHITECTURE describes, backed by an atomic JSON store, so a later GRDB swap does not touch Core logic. GRDB only under Phase 7 measured-need rule. Batch JSON writes per scan or run.

### 2. CI runner image
- **A (STACK):** `macos-26`, pinned, Xcode 26.x (default 26.6).
- **B (PITFALLS):** Pin `macos-15` (default Xcode 16.4).
- **Resolution:** `macos-26` with explicit Xcode 26.x selection, printed in logs. Explicit selection answers PITFALLS' default-Xcode concern. Never `macos-latest` or `-large`/`-xlarge`. Recheck label in Phase 1.

### 3. App Transport Security
- **A (STACK primary, PITFALLS):** `NSAllowsLocalNetworking = true` only.
- **B (ARCHITECTURE):** also `NSAllowsArbitraryLoads = true`.
- **Resolution:** A. PROJECT.md constrains to "ATS local-networking exception." Apple documents ATS does not apply to IP-literal connections. Phase 1 proves plain-HTTP `GET /health` to PC IP. Widen only if that fails, and record the reason.

### 4. Swift language mode
- **A (STACK, PITFALLS):** Swift 5 everywhere.
- **B (ARCHITECTURE):** Swift 6 for `PhotoSyncCore` (Linux-verified); Swift 5 with complete-check warnings for app target.
- **Resolution:** B. The risk is macOS compile cost; Core errors are cheap on Linux. App target stays Swift 5. Set `SWIFT_VERSION` per target.

### 5. PHPersistentChangeToken in v1
- **A (PITFALLS, FEATURES DIFF-5):** Skip.
- **B (ARCHITECTURE):** `changes(since:)` seam now; token if scan slow.
- **Resolution:** A in implementation. Do not add `changes(since:)` in Phase 4. Measure scan in Phase 2; if over about 10 s, add token in Phase 7 with full-scan fallback at the same time.

### 6. Edited renders in v1
- **A (FEATURES):** v1.x.
- **B (ARCHITECTURE):** v1, on by default, `IMG_E<nnnn>`.
- **Resolution:** A for upload. Keep ARCHITECTURE's resource-key scheme in Phase 4 so no migration is needed. State in the summary that edited renders are not yet backed up, so the omission is visible.

### 7. Upload concurrency (additional)
- **A (FEATURES UP-8, PITFALLS):** Sequential; `httpMaximumConnectionsPerHost = 1`.
- **B (ARCHITECTURE):** Worker pool, N = min(server concurrency, 3).
- **Resolution:** A for v1. Phase 2 measures 1 vs 2 workers; pool and DIFF-4 move to Phase 7 if justified.

### 8. Resource key format (additional)
- **A (ARCHITECTURE):** `<localIdentifier>#<kind>`, plus `@<modEpoch>` for mutable kinds.
- **B (FEATURES):** `<localIdentifier>/<resourceType>`.
- **C (PITFALLS):** `<localIdentifier>/<resourceType>/<index>`.
- **Resolution:** A. Kind is unique per asset, so index adds nothing. Confirm server accepts the form (max 200 chars) in Phase 3.

### 9. Chunk size (additional)
- **A (ARCHITECTURE, STACK):** 8 MiB chunks.
- **B (PITFALLS):** One PATCH per attempt, or 8 MiB; measure both.
- **Resolution:** 8 MiB for v1; measure 32 MiB in Phase 2 and change only on data.

### 10. Server patch scope (additional)
- **A (ARCHITECTURE):** S1, S2, S4, S5.
- **B (PITFALLS):** Also finalizing rollback, 415 handling, `freeBytes`, client heartbeat.
- **Resolution:** Union in Phase 3, each with its own test. Heartbeat is client-side in Phase 5.

### 11. Build-minute budget (additional)
- **A (PROJECT.md):** 20–40 builds a month, to be checked.
- **B (STACK):** 35–60 builds, 3–6 min each.
- **C (PITFALLS):** 25–40 builds, 5–8 min each.
- **Resolution:** Plan on about 25 macOS builds a month until Phase 1 records real billed minutes. Linux gate carries most iterations.

### 12. Public or private iOS repo (additional)
- **A (PROJECT.md):** Private.
- **B (STACK, PITFALLS):** Public gets free standard runners; no secrets in source.
- **Resolution:** Keep private, as PROJECT.md decides. Record public repo or Codemagic as the user's fallback if the allowance runs out. This is a user decision.

### 13. Temp export location (minor)
- **A (STACK, ARCHITECTURE):** `temporaryDirectory`.
- **B (PITFALLS):** `Library/Caches/export`.
- **Resolution:** `temporaryDirectory`, `isExcludedFromBackup`, full wipe at launch.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM-HIGH | Runner images, billing, AltStore limits, XcodeGen checked against official pages. PhotoKit details MEDIUM. Unsigned IPA flags must be proven by first build. |
| Features | MEDIUM | PhotoKit semantics HIGH; competitor behaviour MEDIUM; edge behaviours LOW until spike. |
| Architecture | MEDIUM | Server facts HIGH (code read). Apple-framework behaviour MEDIUM; SPIKE items LOW. |
| Pitfalls | MEDIUM | Server-side HIGH; toolchain and billing HIGH to MEDIUM; PhotoKit and Keychain experience-based. |

**Overall:** MEDIUM. Server and CI constraints are well grounded; Apple device behaviour is not, and it is the product. Phases 1–2 convert that uncertainty into measured facts.

### Gaps to Address
- `writeData` original bytes: unverified; Phase 2 gate.
- Video throughput cause (Wi-Fi, iOS, server): Phase 2 compares native with a laptop `curl` upload to the same server.
- iCloud-only behaviour: Phase 2 measures completion, stall or error; 120 s stall timeout is a starting point.
- Hidden and burst fetch under full access: Phase 2 probes.
- Edit and Live Photo resource naming (`FullSizeRender`, `Adjustments.plist`): forum-sourced; Phase 2 dump.
- Keychain under AltStore refresh: Phase 1.
- Local Network on iOS 18.4–18.5: confirm user's iOS version in Phase 1; reboot workaround.
- XcodeGen with local SPM and Xcode 26: verify in first build.
- Swift on Linux CI and WSL2: verify in Phase 0.
- `/finish` for multi-GB files vs 60 s hash: Phase 5/6 test 4 GB file.
- Defender and OneDrive effects on `.incoming`: Phase 2 and 6 on real PC.
- Build-minute cost: Phase 1.
- `embedded.mobileprovision` expiry read: Phase 1 test or manual fallback.

## Sources

**Primary (HIGH):** repository files read directly (`server/app.ts`, `server/engine.ts`, `server/security.ts`, `server/metadata.ts`, `server/db.ts`, `shared/schemas.ts`, `tests/helpers.ts`, `.planning/codebase/CONCERNS.md`, `docs/api.md`, `docs/ROADMAP_IOS_COMPANION.md`, `.planning/PROJECT.md`); GitHub runner-images README; GitHub Actions billing docs; AltStore FAQ; Apple membership comparison; Apple PhotoKit documentation; XcodeGen releases; GRDB.swift releases.

**Secondary (MEDIUM):** Apple Developer Forums on ATS, Local Network, PHAssetResource and iCloud (threads 747421, 788044, 66417, 66477, 833066, 813354, 662053, 771373); Immich docs and issues; PhotoSync release notes; Synology KB; Ente FAQ; Nextcloud forum threads; unsigned-archive flags (forum thread 109122).

**Tertiary (LOW, validate in spikes):** free-account entitlements; mobileprovision expiry read; `fileSize` KVC; Hidden-album exposure; network-required PhotosError code; change-token expiry; Swift on Windows practicality.

---
*Research completed: 2026-10-11*
*Ready for roadmap: yes, once Conflicts to resolve is accepted or overridden*
