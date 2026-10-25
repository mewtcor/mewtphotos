# Architecture Research

**Domain:** Native iPhone photo-backup client (SwiftUI + PhotoKit + URLSession) for an existing Windows/Node backup server
**Researched:** 2026-10-11
**Confidence:** MEDIUM overall. Server facts are HIGH (read from `server/*.ts`). Apple-framework behaviour is MEDIUM (documented APIs, not exercised on this device). Items marked **[SPIKE]** are LOW until measured on the real iPhone.

Confidence tags used below: **[SRC]** = read directly in this repo's code (HIGH); **[DOC]** = Apple/GitHub documentation or web source (MEDIUM); **[SPIKE]** = must be proven on the device before relying on it (LOW).

---

## Standard Architecture

### System Overview

```
 iPhone (SwiftUI app, foreground only, iOS 18+)                         Windows PC (unchanged, + 4 small additions)
┌───────────────────────────────────────────────────────────────┐     ┌──────────────────────────────────────┐
│ App target (thin, Apple-only, NOT compilable on Linux)         │     │ Fastify  /api/v1   (server/app.ts)    │
│  SwiftUI views ── @MainActor AppModel (@Observable)            │     │  requireDevice -> engine.ts           │
│  PhotoKitLibrary   (PHAsset -> AssetDescriptor)                │     │  createUpload / appendChunk /         │
│  PhotoKitExporter  (PHAssetResourceManager -> temp file)       │     │  finishUpload / place / commitStored  │
│  KeychainStore, ConnectivityMonitor(NWPathMonitor), Info.plist │     │  SQLite (uploads, files, sessions)    │
├───────────────────────────────┬───────────────────────────────┤     └───────────────▲──────────────────────┘
│ MewtPhotosCore  (pure Swift package, Swift 6 mode,              │                     │ plain HTTP on LAN
│ builds and tests on LINUX + macOS; no Apple-only imports)      │                     │ Bearer device key
│                                                                │                     │
│  BackupCoordinator (actor) ── run state machine, worker pool   │                     │
│   ├─ LibraryScanner ── PhotoLibraryProviding (protocol)        │                     │
│   ├─ Planner       (pure: descriptors + inventory -> work)     │                     │
│   ├─ Inventory     (actor, GRDB/SQLite: asset -> resource ->   │                     │
│   │                 state; ResourceState reducer = truth gate) │                     │
│   ├─ ResourceExporting (protocol) + TempStore                  │                     │
│   ├─ ServerClient + ResumableUploader ── HTTPTransport ────────┼─────────────────────┘
│   ├─ Reconciler    (app counts vs GET /sessions/:id)           │
│   └─ RunLog        (actor, rotating JSONL file, exportable)    │
└───────────────────────────────────────────────────────────────┘
```

Rule of the diagram: **everything with logic lives in MewtPhotosCore behind a protocol; the app target only adapts Apple frameworks to those protocols.** The app target is the part that cannot be compiled or tested without a macOS CI build, so it must stay small and boring.

### Component Responsibilities

| Component | Responsibility | Implementation |
|-----------|----------------|----------------|
| `AppModel` (`@MainActor @Observable`, app target) | Holds the latest `RunSnapshot`, forwards user intents (pair, back up, retry, cancel, share log). No business logic. | Consumes `AsyncStream<RunSnapshot>` from the coordinator. |
| `BackupCoordinator` (actor, Core) | Owns one run: scan -> plan -> create server session -> worker pool -> complete session -> reconcile. Single writer of run-level state. Cancellation root. | `withThrowingTaskGroup` sliding window of N workers; publishes snapshots (throttled to ~4/s). |
| `LibraryScanner` + `PhotoLibraryProviding` (protocol in Core, `PhotoKitLibrary` in app) | Enumerate assets and their resources as `Sendable` value descriptors. Never hands `PHAsset`/`PHAssetResource` (non-Sendable classes) across actors. | Adapter converts inside one function; Core sees `AssetDescriptor { localId, creationDate, modificationDate, mediaType, subtypes, resources:[ResourceDescriptor] }`. |
| `Planner` (pure, Core) | Decide per resource: skip (already confirmed), ask server (`/assets/check`), or export+upload. Computes resource key, upload filename, Live Photo grouping, ordering (small/photos first). | Pure functions; the bulk of unit tests. |
| `Inventory` (actor, Core) | Durable `asset -> resource -> state` store; survives app kill. **The only writer of resource state**, via `ResourceState.apply(event)`. | GRDB `DatabaseQueue` (one SPM dependency; see Stack notes), migrations numbered. |
| `ResourceExporting` + `TempStore` | Export one original resource to a temp file, return `ExportedFile{url,size,sha256}`; own temp dir lifecycle (sweep on launch, delete after confirm). | App target: `PHAssetResourceManager`. Core: protocol + `FakeExporter` writing real temp files for tests. |
| `ServerClient` (Core) | Typed calls for `/pair /status /sessions /assets/check /uploads /files`. Maps `{error,message,offset?}` to `ServerError`. | `Sendable` struct over `HTTPTransport`. |
| `ResumableUploader` (Core) | create -> chunk loop (8 MiB) -> resync on failure -> finish. Decides retry vs fail from a pure `UploadMachine`. | Reads chunks with `FileHandle`, sends `PATCH` with `Upload-Offset`. |
| `Reconciler` (Core) | Produces the truthful numbers: app-confirmed vs server session summary; flags any mismatch. | Pure function over inventory counts + `SessionSummary`. |
| `RunLog` (actor, Core) | In-app visible + exportable log (no debugger exists). Never logs the device key. | Rotating JSONL in `Documents/logs/`, `ShareLink` export. |
| `KeychainStore`, `ConnectivityMonitor` (app target) | Device key + deviceId; Wi-Fi/expensive-path signals. | Thin wrappers behind protocols with in-memory fakes in Core tests. |

---

## Recommended Project Structure (repo layout)

```
mewtphotos/                              (existing repo root; git remote to be created, private)
├── server/  shared/  web/  tests/      (unchanged; server additions below land here)
├── ios/
│   ├── project.yml                     # XcodeGen spec: app target, Info.plist keys, local package ref
│   ├── MewtPhotos/                      # APP TARGET: Apple-only glue (keep < ~1500 lines)
│   │   ├── MewtPhotosApp.swift
│   │   ├── UI/                         # SwiftUI: PairView, BackupView, IssuesView, LogView, DiagnosticsView
│   │   ├── Adapters/                   # PhotoKitLibrary, PhotoKitExporter, KeychainStore, ConnectivityMonitor
│   │   └── Assets.xcassets
│   ├── Packages/
│   │   └── MewtPhotosCore/              # PURE SWIFT PACKAGE (swift-tools-version 6.0, Swift 6 mode)
│   │       ├── Package.swift
│   │       ├── Sources/MewtPhotosCore/
│   │       │   ├── Wire/               # Codable mirrors of shared/schemas.ts
│   │       │   ├── Server/             # ServerClient, HTTPTransport, ServerError
│   │       │   ├── Upload/             # UploadMachine, ResumableUploader, RetryPolicy
│   │       │   ├── Library/            # descriptors, PhotoLibraryProviding, LibraryScanner, ChangeApplier
│   │       │   ├── Inventory/          # schema, migrations, ResourceState, Inventory actor
│   │       │   ├── Planning/           # Planner, ResourceNaming, ResourceKey
│   │       │   ├── Run/                # BackupCoordinator, Reconciler, RunSnapshot
│   │       │   └── Support/            # RunLog, Hashing (CryptoKit | swift-crypto), PairingLink, Clock seams
│   │       └── Tests/MewtPhotosCoreTests/
│   │           ├── Unit/               # pure logic + fake transport
│   │           ├── Contract/           # real Node server (spawned), real URLSessionTransport
│   │           └── Fixtures/wire/      # JSON captured from the real server (also checked by vitest)
├── tests/
│   ├── contract/serve.ts               # headless real server for Swift contract tests (no PowerShell, loopback)
│   └── wire-fixtures.test.ts           # vitest: fixtures vs shared/schemas.ts (Zod)
└── .github/workflows/
    ├── server.yml                      # npm ci, typecheck, vitest (ubuntu or windows)
    ├── ios-core.yml                    # ubuntu: setup-node + swift test (unit + contract). Every push. ~1x minutes
    └── ios-build.yml                   # macos: xcodegen + unsigned .ipa. workflow_dispatch / tag only. ~10x minutes
```

### Structure Rationale

- **`ios/` beside `server/`**: one repo so `shared/schemas.ts` and the Swift wire types change in one commit and one CI run. `ios/` is not part of the npm workspace (nothing in `package.json`/`tsconfig.json` includes it; `tsconfig.json` `include` is explicit so it is already excluded).
- **XcodeGen (`project.yml`) instead of a committed `.xcodeproj`**: a hand-edited `pbxproj` cannot be produced reliably on Windows; `project.yml` is a reviewable text file and the CI step is `brew install xcodegen && xcodegen generate` [DOC: XcodeGen supports local SPM packages; the exact local-package `path:` syntax and signing settings must be set in `project.yml` and checked in the first build]. Do **not** commit the generated `.xcodeproj`.
- **Core as a local SPM package**: the same package builds with `swift build/test` on Linux (cheap runner, and in WSL2 on the dev machine) and is linked by the app. This is the single most important cost/feedback lever (see CI economics).
- **Two language modes on purpose**: Core = Swift 6 language mode (strict concurrency, verifiable on Linux for free). App target = `SWIFT_VERSION 5` with `SWIFT_STRICT_CONCURRENCY=complete` (warnings, not errors). PhotoKit/SwiftUI Sendable gaps in Apple's SDK would otherwise turn into build-breaking errors that can only be found on a 10x-priced macOS build.
- **`tests/contract/serve.ts` and not `server/main.ts`**: `main.ts` calls `pickLanAddress()` and the first-run `config.ts` path shells out to `powershell.exe` [SRC], which does not exist on Linux CI. The harness uses `buildApp({ db, port: 0, lanIp: null })` + `saveSettings` exactly as `tests/helpers.ts` `startServer` does, then `listen()`, which binds `127.0.0.1` only. Loopback is accepted by the sender API (`isLocalNetworkAddress` includes `127.0.0.0/8`) [SRC].

---

## Concurrency Model (Swift 6 / async-await / actors)

```
@MainActor AppModel ──intent──▶ actor BackupCoordinator ──AsyncStream<RunSnapshot>──▶ @MainActor AppModel
                                   │
                    ┌──────────────┼───────────────────────────────┐
                    ▼              ▼                               ▼
              actor Inventory   ServerClient (Sendable struct)   RunLog (actor)
                    ▲              ▲
                    │              │
        worker task 1..N  (each: export -> hash -> create -> upload -> finish -> record)
                    │
        ExportGate (actor semaphore: max 2 concurrent exports, max K temp bytes in flight)
```

Rules (each one prevents a class of Swift 6 build failure or runtime bug):

1. **Only value types cross actor boundaries.** `PHAsset`, `PHAssetResource`, `PHFetchResult` are non-Sendable; they never leave the adapter function that creates them. Core types are `Sendable` structs/enums.
2. **State has exactly one owner.** Inventory rows: `Inventory` actor. Run counters: `BackupCoordinator`. UI state: `AppModel` on `@MainActor`. Workers hold no shared mutable state; they `await inventory.apply(event)`.
3. **Worker pool, not a multi-stage pipeline.** N workers (N = `min(server concurrency from GET /status, 3)`; server default 2, max 6 [SRC]) each own one resource end to end. The temp-disk bound is automatically N files; exporting item k+1 overlaps uploading item k through the other worker. No `AsyncChannel`/swift-async-algorithms dependency needed.
4. **Export concurrency is gated separately** (`ExportGate`, 1-2) because iCloud downloads are network-bound and local exports are disk-bound; also guards free space (check `volumeAvailableCapacityForImportantUsage` before each export; surface ENOSPC as "phone storage full").
5. **Completion-handler PhotoKit APIs are bridged once** with `withCheckedThrowingContinuation` inside the adapter, plus `withTaskCancellationHandler` calling `PHAssetResourceManager.cancelDataRequest(_:)`. Cancellation is cooperative everywhere else (`try Task.checkCancellation()` between chunks).
6. **No `Task.sleep` in logic.** Backoff takes an injected `any Clock<Duration>`; tests use an immediate clock so a retry script runs in microseconds.
7. **Foreground discipline** (v1 has no background session): set `UIApplication.shared.isIdleTimerDisabled = true` while a run is active (screen auto-lock is what suspends a foreground app), wrap in `beginBackgroundTask` for the ~30 s grace so the current chunk can finish and state can be flushed, and on `scenePhase == .active` the coordinator offers "Resume" (every network call is idempotent or resumable, see below). Use the **default** `URLSession` (not `background`) with `waitsForConnectivity = false`, `timeoutIntervalForRequest` 60 s for PATCH, and **long (10+ min) request timeout for `/finish`** [SRC: finish re-reads and re-hashes the whole file server-side, seconds for GB videos].

### Concrete types (sketch)

```swift
// Core, Swift 6 mode
public struct ResourceDescriptor: Sendable, Hashable {
  public let type: ResourceKind            // .photo .video .pairedVideo .alternatePhoto .fullSizePhoto .fullSizeVideo .adjustmentData ...
  public let originalFilename: String
  public let uti: String
}
public struct AssetDescriptor: Sendable {
  public let localId: String
  public let creationDate: Date?
  public let modificationDate: Date?
  public let mediaType: MediaKind
  public let resources: [ResourceDescriptor]
}
public protocol PhotoLibraryProviding: Sendable {
  func authorization() async -> LibraryAccess                    // .full | .limited | .denied
  func allAssets() async throws -> [AssetDescriptor]             // full enumeration, includes hidden + all burst frames
  func changes(since: Data?) async throws -> LibraryChanges      // optional optimisation, see Change tracking
}
public protocol ResourceExporting: Sendable {
  func export(_ r: ResourceDescriptor, of asset: String, to dir: URL,
              progress: @Sendable (Double) -> Void) async throws -> ExportedFile   // url, size, sha256
}
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse)
}
```

`HTTPTransport` is implemented once over `URLSession.dataTask(with:completionHandler:)` + continuation (not the async `URLSession.upload(for:from:)` overloads) so the identical code path runs on Linux `FoundationNetworking` [DOC/SPIKE on Linux: async URLSession overloads availability in corelibs varies by toolchain; the completion-handler API is available everywhere].

---

## Key Data Flows

### 1. Run: scan -> plan -> upload -> report

```
[Back up now]
   │ AppModel.start()
   ▼
BackupCoordinator.run()
   1. authorization()                      full access required for libraryCount; limited -> run but libraryCount = nil + banner
   2. LibraryScanner.scan()                allAssets() -> diff against Inventory (localId, modificationDate) -> upsert asset+resource rows
   3. Planner.plan(inventory)              pending = resources whose state is not terminal-good
   4. POST /assets/check  (<=5000/batch)   items = pending resource keys -> known[] -> Inventory.apply(.serverKnown) for true
   5. POST /sessions {method:"native", selectedCount: remaining.count, libraryCount?}   -> sessionId
   6. worker pool over remaining resources (see flow 2)
   7. POST /sessions/:id/complete {unavailableCount}
   8. GET  /sessions/:id -> Reconciler(app counts, server summary) -> RunSnapshot.final
```

### 2. One resource end to end (worker)

```
Inventory: pending ──▶ exporting
   ExportGate.acquire ─▶ PhotoKitExporter.export (isNetworkAccessAllowed = true, progress, stall watchdog)
        │ error ─▶ classify: transient(iCloud/network) -> retry w/ backoff (<=3) -> else .unavailable(reason)
        ▼ ExportedFile{ url, size, sha256 }  (size == 0 -> .unavailable(zeroBytes): server rejects size < 1 [SRC])
Inventory: exported(sha256,size)
   POST /uploads { sessionId, filename, size, mimeType, lastModified, assetId=resourceKey, groupId=localId, sha256 }
        ├─ UploadResult(duplicate) ──────────────────────────▶ confirmed(duplicate)   (no bytes sent)
        └─ UploadState(receiving, offset)
              PATCH /uploads/:id  Upload-Offset  (8 MiB chunks from FileHandle)
                 409 offset_mismatch{offset} -> adopt, continue      409 upload_busy -> wait & GET /uploads/:id
                 timeout / -1005 / -1001      -> GET /uploads/:id (offset is measured from disk) -> continue
              POST /uploads/:id/finish { sha256 }   (idempotent; retry on lost response; upload_busy = still working, poll)
                 ├─ UploadResult(verified|duplicate) ─────────▶ confirmed(verified|duplicate)  + delete temp file
                 ├─ 422 hash_mismatch ─▶ nothing stored -> re-export once, else failed(hash_mismatch)
                 └─ 415 / 413 / 507 ───▶ terminal states: unsupported / tooLarge / serverFull (NOT retried automatically)
```

The temp file is deleted only after `confirmed`; `TempStore.sweep()` on launch removes orphans from a killed run.

### 3. Truthful state (the invariant)

```
ResourceState:  discovered
                  ├─▶ serverKnown            only from /assets/check known==true      (shown: "on PC, not re-sent")
                  └─▶ pending ▶ exporting ▶ exported ▶ uploading(offset) ▶ finishing
                                   │            │            │               │
                                   ▼            ▼            ▼               ▼
                              unavailable   failed(code)  failed(code)   confirmed(verified|duplicate)   <- ONLY from server UploadResult
                              (reason)      retryable?    retryable?
```

- `ResourceState.apply(_ event:)` is a pure reducer; `confirmed` and `serverKnown` are reachable **only** from events carrying a server response (`.serverVerified`, `.serverDuplicate`, `.serverKnown`). A unit test enumerates every (state, event) pair and asserts no other path produces them. This is the code-level form of "never show backed up unless the PC said so".
- Headline number on screen = count of `confirmed + serverKnown`. Sub-lines: "verified this run" (from `GET /sessions/:id` `verified + duplicates`), "already on PC", "failed", "unavailable", "waiting".
- **Reconciler rule**: every resource the app marked `confirmed` in this run must be matched by a server upload row in `verified|duplicate` for that session, so `server.verified + server.duplicates >= app.confirmedThisRun`, with equality expected. `<` is a bug and renders a red banner. `>` can happen only through retried `POST /uploads` creating a second attempt row; fixed server-side by change **S4** below so equality holds.
- `serverKnown` is a statement about the last `/assets/check`, not a re-verification. Provide "Re-check with PC" (cheap after S2) which re-runs `/assets/check` for all `serverKnown/confirmed` rows and demotes any the PC has lost to `pending`.

### 4. Inventory loss is recoverable

If the app is reinstalled (Documents wiped) but the Keychain still holds the device key, the inventory is rebuilt by scan + `/assets/check` (assetId is device-scoped on the server [SRC `uploads_asset(device_id, asset_id)` index]). If the key is lost the app must re-pair, which creates a **new device id**, and every assetId becomes unknown; the fallback is hash-based dedupe via `POST /uploads` with `sha256` (correct but forces export+hash, and iCloud download, of the whole library; the server also re-reads each existing stored copy per duplicate [SRC `fileIntact`]). Store `deviceId` alongside the key and tell the user "do not delete the app to refresh it; AltStore refresh keeps data".

---

## Library Scanning and Change Tracking

**Recommendation: ship the full-diff scan as the correctness path; make `PHPersistentChangeToken` an optimisation behind the same `PhotoLibraryProviding.changes(since:)` seam, added after the scan time is measured.**

- Full scan = `PHAsset.fetchAssets(with:)` with `includeHiddenAssets = true`, `includeAllBurstAssets = true`, and explicit `includeAssetSourceTypes` [DOC; confirm defaults in spike]. Per asset record `(localIdentifier, creationDate, modificationDate, mediaType, mediaSubtypes)`. Resource lists (`PHAssetResource.assetResources(for:)`) are fetched **only for assets that are new or whose `modificationDate` changed** versus the inventory, so unchanged assets cost one cheap row comparison. This already gives "edits detected" and "new items detected" with no token.
- Token path (iOS 16+ `PHPhotoLibrary.currentChangeToken`, `fetchPersistentChanges(since:)`, `changeDetails(for: .asset)` -> inserted/updated/deleted local identifiers [DOC: WWDC22 session 10132]): returns only the delta, so it skips even the cheap comparison. It adds failure modes (token expiry, token saved before the inventory commit, hidden/burst identifiers) for a saving that is probably seconds on one person's library. **[SPIKE: time `allAssets()` with and without resource lookup on the real 10k+ library; adopt the token only if the full diff is > ~10 s].**
- If adopted: persist the token **in the same Inventory transaction** that applies the changes; on any error (expired token, decoding failure) discard it and run the full diff; the full diff is also run on every app update and weekly as a safety net. `ChangeApplier` (pure) takes a `LibraryChanges{inserted,updated,deleted}` and the inventory and returns row mutations; fully unit-testable.
- Deleted-on-phone assets: mark `deletedLocally`, keep rows, never contact the server (one-way, additive backup).
- `PHPhotoLibraryChangeObserver` is not needed for v1 (foreground, user-initiated runs). Do a fresh scan at the start of each run.
- Limited access (`.limited`): scan sees only the chosen subset; pass `libraryCount` as nil and show "limited access: some photos are invisible to this app" because `libraryCount` is only legitimate with full access [SRC: `SessionCreate` comment].

### Inventory schema (GRDB, v1)

| Table | Key columns |
|-------|-------------|
| `asset` | `localId` PK, `creationDate`, `modificationDate`, `mediaType`, `subtypes`, `firstSeen`, `lastSeen`, `deletedLocally` |
| `resource` | `key` PK (= the `assetId` sent to the server), `localId` FK, `kind`, `originalFilename`, `uploadFilename`, `uti`, `size?`, `sha256?`, `state`, `stateDetail`, `attempts`, `lastError`, `serverUploadId?`, `updatedAt` |
| `run` | `id`, `serverSessionId`, `startedAt`, `finishedAt?`, `libraryCount?`, `selected`, `unavailable`, `appConfirmed`, `serverVerified`, `serverDuplicates` |
| `meta` | key/value (change token if adopted, schema notes) |

**Resource key (`assetId`, max 200 chars [SRC])**: `"<localIdentifier>#<kind>"` for immutable resources (`photo`, `video`, `pairedVideo`, `alternatePhoto`), and `"<localIdentifier>#<kind>@<modificationEpochSeconds>"` for mutable ones (`fullSizePhoto`, `fullSizeVideo`, `adjustmentData`). Reason: `/assets/check` answers by exact `assetId` string, so a re-edited photo must produce a new key or its new render would be wrongly reported as already backed up. `localIdentifier` is stable on one device and changes after a restore to a new device [DOC].

---

## Resource Export and Hashing

- **Default: `PHAssetResourceManager.default().writeData(for:toFile:options:)` to `tmp/export/<uuid>`, then hash the temp file with 1 MiB reads.** This is the documented "write original bytes to disk" path, memory-bounded, and the second read of a local temp file is cheap next to the LAN transfer. Streaming `requestData(for:options:dataReceivedHandler:completionHandler:)` (write + `SHA256.update` in the same pass) is a measured-later optimisation: it removes the second read but ties hashing to arbitrary chunk delivery and to a callback queue (`@unchecked Sendable` sink). Keep both behind `ResourceExporting` so the choice does not leak. **[SPIKE: confirm `writeData` returns stored HEIC/DNG/HEVC bytes (magic bytes `ftypheic`, DNG TIFF header, `.mov` `ftypqt`), and how fast it is for a 300 MB video].**
- Options: `isNetworkAccessAllowed = true`, `progressHandler` feeding both UI progress and a **stall watchdog** (no progress for ~120 s cancels the request). Do not use wall-clock timeouts: a 2 GB iCloud video is legitimately slow.
- Hash: `CryptoKit.SHA256` on Apple platforms, `swift-crypto` (`import Crypto`) on Linux, chosen by `#if canImport(CryptoKit)` inside `Support/Hashing.swift`. Output lowercase hex (the server regex requires `^[0-9a-f]{64}$` [SRC]).
- **Size is learned from the exported file, not from PhotoKit** (public API gives no resource size; the KVC `fileSize` trick is private API, avoid). Hence order is export -> hash -> `POST /uploads` (which needs `size >= 1` and `sha256`). `/assets/check` by assetId is what avoids exporting already-backed-up resources.
- Never use `PHImageManager.requestImage*` for backup (rendered copies).
- Temp dir under `FileManager.default.temporaryDirectory/export`, files deleted after `confirmed`, swept at launch. Cap in-flight temp bytes (e.g. 2 x largest + 1 GB headroom) via `ExportGate`.

### Resource set and naming (client-side, no server change)

| PhotoKit resource | Back up in v1? | Upload filename | Notes |
|---|---|---|---|
| `.photo`, `.video` | Yes | `originalFilename` (e.g. `IMG_1234.HEIC`, `IMG_1234.MOV`) | The untouched original (stays the original even for edited assets). ProRAW = `.photo` with `.DNG` [DOC]. |
| `.pairedVideo` | Yes | `originalFilename` (`IMG_1234.MOV`) | Live Photo video; same stem as the still. |
| `.alternatePhoto` | Yes | `originalFilename` (`IMG_1234.DNG`) | RAW half of RAW+JPEG. |
| `.fullSizePhoto` / `.fullSizeVideo` | Decide (recommend Yes, default on) | `IMG_E1234.<ext from UTI>` (Apple's own edited-copy convention) | `originalFilename` is typically `FullSizeRender.*` for every asset [DOC: Apple forum thread; verify in spike] so it MUST be renamed client-side or the server will produce `FullSizeRender (2).jpg` ... and lose the association. |
| `.adjustmentData` | **No in v1** | (would be `IMG_1234.AAE`) | Only meaningful to the Photos app; its `originalFilename` is reportedly `Adjustments.plist` [DOC, MEDIUM], which the server rejects with 415. Avoids an allow-list change entirely. |

`ResourceNaming` is a pure function (heavily unit-tested). **[SPIKE: the Diagnostics screen dumps `(type, originalFilename, uti)` for ~200 assets of the user's own library, including an edited photo, a Live Photo, a RAW+JPEG, a screenshot, a burst, and an iCloud-only video, so naming rules are data-driven.]**

---

## Upload Client

- `ResumableUploader` is a thin loop around a **pure `UploadMachine`**: `next(state, event) -> Action`. Events are server replies/errors; actions are `createUpload`, `sendChunk(offset)`, `resync`, `finish`, `wait(duration)`, `restartFromExport`, `fail(reason)`, `done(result)`. Unit tests script event sequences without any I/O.
- Chunking: `FileHandle.read(upToCount: chunkSize)` where `chunkSize` comes from `GET /status` (8 MiB [SRC `CHUNK_SIZE`]); N workers x 8 MiB `Data` is a ~16-24 MB working set. The server accepts any chunk size and streams to disk [SRC], so a larger chunk is a pure tuning knob. **[SPIKE: measure MB/s at chunk 8 MiB vs 32 MiB, worker count 1 vs 2 vs 3; the Safari path measured 0.5 MB/s for video and the cause is unknown, so do not assume the native client is automatically fast.]**
- Error policy table (all derived from `server/engine.ts` / `app.ts` behaviour [SRC]):

| Server/transport signal | Meaning | Client action |
|---|---|---|
| 409 `offset_mismatch` `{offset}` | Disk size differs | Adopt `offset`, continue (not an error) |
| 409 `upload_busy` | Another request still writing / finishing | Poll `GET /uploads/:id` with backoff; never a failure; cap total (e.g. 15 min) |
| 408 `upload_timeout`, 400 `client_disconnected`, URLError -1001/-1005/-1009 | Transient | `GET /uploads/:id`, resume from its offset; backoff + jitter; max attempts then `failed(retryable)` |
| 409 `incomplete` `{offset}` on finish | Missing bytes | Resume from `offset` |
| 422 `hash_mismatch` | Corruption; server deleted the partial | Re-export once and start a new upload; then `failed(hash_mismatch)` |
| 413 `file_too_large` / 507 `insufficient_space` / `quota_exceeded` | Server limits | Terminal for this item; stop the whole run on 507 (disk full) and say so |
| 415 `unsupported_type` | Extension not on allow-list | Terminal `unsupported`; shown in Issues, never counted backed up |
| 401 `unauthorized` | Device removed/unpaired | Stop run, route to Pair |
| 403 `forbidden_network` | Not on LAN | Stop run, "connect to home Wi-Fi" |
| lost response to `POST /uploads` | Row may exist | Safe only with S4 (idempotent by assetId); otherwise creates a duplicate attempt row |

- Keep-alive: Node's default idle socket timeout can drop reused connections between chunks; treat the first -1005 on a reused connection as transient (do not count it against the retry budget).
- Local-network access on iOS: needs `NSLocalNetworkUsageDescription` in Info.plist and the user to accept the prompt; a denied prompt looks like timeouts. Show a specific hint when `/health` fails repeatedly on first run. ATS: plain-HTTP LAN host. Set `NSAppTransportSecurity > NSAllowsLocalNetworking = true`, and for v1 also `NSAllowsArbitraryLoads = true` to remove a failure mode that cannot be debugged (sideloaded personal app; tighten in the HTTPS milestone) **[SPIKE: first build must `GET /health` over plain HTTP to the PC IP]**.
- iCloud handling is entirely in the export stage (above); the upload client never knows about iCloud.

---

## Server Changes Actually Required (read from the code)

What the server does today that matters, by file:

- `server/security.ts` `ALLOWED_EXTENSIONS` (jpg jpeg jpe heic heif hif avif png gif webp bmp tif tiff dng cr2 cr3 nef arw raf orf rw2 mov mp4 m4v 3gp 3g2 avi mkv webm mts m2ts). Every resource v1 uploads (HEIC/JPG/PNG/GIF/DNG/MOV/MP4/TIFF/WebP, edited render JPG/HEIC) is already allowed. `safeMediaFilename` throws 415 otherwise [SRC].
- `server/engine.ts` `finishUpload` -> `readCaptureDate(temp, ext)` then `place()`: folder = **each file's own** embedded date (EXIF `DateTimeOriginal` local wall-clock for stills, QuickTime `mvhd` creation time converted with the **PC's** local timezone for videos), else `last_modified`, else now [SRC `metadata.ts`, `engine.ts`]. Name = `upload.filename`, with `stem (n).ext` on collision with different content [SRC].
- `server/app.ts` `/assets/check`: `sha256` branch checks `files.verify_status='ok'` only; `assetId` branch checks only that this device has an `uploads` row `verified|duplicate` with that `asset_id`. Neither touches the disk [SRC; matches CONCERNS.md].
- `createUpload`: resume match is `device + filename + size + last_modified + status='receiving'`; hash-known duplicate inserts another `uploads` row with `status='duplicate'` each time it is called; `size` must be >= 1 [SRC].

| # | Change | Why the app needs it | Size | Verdict |
|---|--------|---------------------|------|---------|
| **S1** | **Live Photo / sibling placement.** Add optional `groupId` (string, max 200) to `UploadCreate` in `shared/schemas.ts`; store in new `uploads.group_id` column; in `place()` (already inside `serialize()`, so deterministic) look up a placed sibling `SELECT f.path FROM uploads u JOIN files f ON f.id=u.file_id WHERE u.device_id=? AND u.group_id=? AND u.status IN ('verified','duplicate') LIMIT 1` and **use `dirname(sibling.path)` as the target directory** instead of the per-file date folder. Duplicates count: a stored-elsewhere duplicate sibling pulls the new half next to the existing copy. | PROJECT requirement: both halves "kept together on disk". Without it the halves can land in different `YYYY\MM` folders because stills use EXIF local time and videos use UTC `mvhd` converted to the PC timezone (differs when the photo was taken in another timezone or near a month boundary). `lastModified` cannot fix it because embedded dates win [SRC]. | ~25 lines + 1 column + 3 vitest cases (pair same folder when dates straddle a month; duplicate sibling; no group = unchanged) | **REQUIRED** |
| **S1b** | Stem adoption: when the sibling's *original* filename stem equals this file's stem but the sibling was stored as `IMG_0001 (2).HEIC`, name this file `IMG_0001 (2).MOV`. | Keeps identical base names under name collision (iPhone counters wrap; restored phones repeat names). | ~10 lines | **Optional / defer.** Collision inside one month is rare for one user; folder pin (S1) delivers "kept together". Do not apply to `IMG_E*`/`FullSizeRender` renders (different stems). |
| **S2** | **`/assets/check` must prove the file is still on disk.** assetId branch: join `uploads.file_id -> files`, require `verify_status='ok'` and `stat(path).size === size`; sha256 branch: same `stat`. Response shape (`{ known: boolean[] }`) unchanged. | The app skips export+upload on `known`, so a stale `known` is a silent missed backup (CONCERNS.md "High" gap). It is the app's only cheap skip mechanism, so truthfulness depends on it. | ~15 lines + 1 test (delete the stored file -> `known:false`); 5000 `stat` calls per batch is fine | **REQUIRED** |
| **S3** | Extension allow-list | Not required: all v1 resources are already allowed. Add `aae` (and nothing else) **only if** adjustment data is brought into scope later (Apple names the sidecar `IMG_1234.AAE`; the PHAssetResource name is reportedly `Adjustments.plist`, so the client renames it). Optionally add `heics`, `jxl` so rare library items are stored instead of reported `unsupported`. | - | **None for v1** |
| **S4** | **`POST /uploads` idempotent per asset.** If `assetId` is given and this device already has an upload row for that `asset_id` in this session with `status IN ('verified','duplicate')`, return its `UploadResult` instead of inserting; prefer matching a `receiving` row by `asset_id` before the name+size+mtime heuristic. | Lost responses on a flaky Wi-Fi retry `POST /uploads`; today each retry of a duplicate adds another `duplicate` row so `sessionSummary.duplicates` exceeds the app's count and the "app count == server count" invariant breaks. Names like `FullSizeRender.jpg` also make the name+size+mtime resume match weak. | ~15 lines + 1 test | **REQUIRED for the stated invariant** (client tolerates `server >= app` until done) |
| S5 | `ALTER TABLE` migration | `db.ts` only has `CREATE TABLE IF NOT EXISTS` [SRC], so S1's new column needs a guarded `ensureColumn` (`PRAGMA table_info(uploads)`) in `openDb`. CONCERNS.md already recommends `PRAGMA user_version` steps; do that instead of ad-hoc if S1 is the first schema change. | ~10 lines | Required by S1 |
| O1 | `POST /diagnostics` (text body appended to `logs`) | On-device failures (PhotoKit, export) are invisible to the server and there is no debugger; a one-tap "send log to PC" beats Share-sheet round trips. | ~15 lines | Optional, recommended for the dev loop |
| O2 | `GET /assets?since=` reconciliation | Roadmap milestone 7 only | - | **Not v1** |
| - | Bonjour, HTTPS pinning | Out of scope for v1 | - | Not v1 |

Everything else the app needs already exists: `method:"native"`, `libraryCount`, `unavailableCount` on complete, `sha256` on create for an early `duplicate`, resumable PATCH, idempotent `finish` [SRC]. `/files` one-shot is not used in foreground v1. Counting units: `selectedCount`/server rows are **resources (files)**; `libraryCount` is **assets**; document this in `docs/api.md` so the summary text is not misread. Also note the server computes "never reached this computer" = `selected - safe - failed - unavailable - cancelled`, so the app must set `selectedCount` exactly (resources it intends to send this run) and report `unavailableCount` at complete: this is what turns an interrupted run into a truthful "N never reached this computer" [SRC `sessionSummary`].

---

## Testing Strategy (maximise logic testable without a device)

| Tier | What | Where it runs | Cost |
|------|------|---------------|------|
| **T1 Unit (pure Core)** | `ResourceState` reducer (incl. "confirmed only from server events" exhaustive test), `UploadMachine` event scripts, `RetryPolicy` with immediate clock, `Planner`, `ResourceNaming`, `ResourceKey`, `ChangeApplier`, `Reconciler`, `PairingLink.parse` (`http://ip:port/#pair=CODE`), `ServerError` decoding, Inventory migrations on in-memory GRDB | `swift test` on ubuntu CI and **locally in WSL2 Ubuntu** on the dev PC [DOC: Swift 6.3.x toolchains exist for Ubuntu 24.04; WSL2 itself not confirmed by a source, expected to work] | ~1x minutes, seconds locally |
| **T2 Fake-transport integration** | `BackupCoordinator` end to end with `FakePhotoLibrary` (50 assets: Live Photos, RAW+JPEG, edited, iCloud-failing, zero-byte), `FakeExporter` writing real temp files, scripted `FakeTransport` (drops, 409s, lost responses) | same | same |
| **T3 Wire fixtures** | `Fixtures/wire/*.json` (requests and real server responses). Swift decodes every fixture; `tests/wire-fixtures.test.ts` (vitest) validates the request fixtures with `UploadCreate`/`SessionCreate`/`AssetCheck`/`PairRequest` and the response fixtures against the TS response types/keys. A change to `shared/schemas.ts` that breaks the app fails the server CI, and vice versa. | vitest (existing) + Swift | negligible |
| **T4 Contract (real Node server)** | Swift tests spawn `node tests/contract/serve.ts` (prints `{port, pairingCode, dest}` as one JSON line, runs until stdin closes), then drive the real `ServerClient` + real `URLSessionTransport` over loopback: pair -> status -> session -> `/assets/check` -> upload (chunked, forced offset mismatch, killed mid-chunk by cancelling the task) -> finish -> verified; then assert on disk under `dest`: byte-identical files, **both halves of a fake Live Photo in the same folder**, duplicate by hash, `/assets/check` false after deleting the file, session summary counts == app counts. | ubuntu CI (setup-node >= 22.18; type stripping needs no flag) and WSL2/Windows locally | ~1x minutes |
| **T5 URLProtocol mock** | Only for `URLSessionTransport` itself (header/timeout mapping). Skip as a priority: T2 fakes `HTTPTransport` one level higher and T4 uses the real thing. | macOS only if at all | - |
| **T6 Server** | New vitest cases for S1/S2/S4 in the existing `tests/engine.test.ts` style (uses `startServer`, `inject`) | existing `npm test` | free |
| **Device-only (cannot be CI-tested)** | PhotoKit adapter, exporter bytes/speed, iCloud download, Keychain, NWPathMonitor, local-network prompt, screen-lock behaviour, SwiftUI | on the phone via the **Diagnostics screen** | 1 macOS build per round |

Dependencies for Linux-buildable Core: GRDB (needs system SQLite: `apt-get install libsqlite3-dev` on the runner if absent) and `swift-crypto` (Linux only, conditional product dependency). Every Apple-only import (`CryptoKit`, `Security`, `Network`, `Photos`, `UIKit`) stays out of Core or is behind `#if canImport`.

---

## CI Economics and Build Pipeline

- **Free private-repo allowance is 2,000 minutes/month and macOS standard runners bill at roughly 10x Linux** ($0.062 vs $0.006 per minute) [DOC: GitHub billing page; multiplier derived from the per-minute rates], i.e. about 200 macOS minutes a month. Public repos get standard runners free [DOC]; the repo has no secrets, so making it public would remove the limit, but the user chose private. Therefore:
  - `ios-core.yml` (ubuntu, every push, path-filtered to `ios/**`, `shared/**`, `server/**`, `tests/**`): `actions/setup-node` (>= 22.18), `npm ci`, `swift test --package-path ios/Packages/MewtPhotosCore`. Ubuntu 24.04 runner image ships Swift 6.3.x [DOC: runner-images release notes], so no install step.
  - `ios-build.yml` (macOS, `workflow_dispatch` + tag only, `concurrency: cancel-in-progress`, SPM cache via `actions/cache`): `brew install xcodegen`, `xcodegen generate`, `xcodebuild -project ios/MewtPhotos.xcodeproj -scheme MewtPhotos -sdk iphoneos -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`, then `mkdir Payload && cp -R build/Build/Products/Release-iphoneos/MewtPhotos.app Payload/ && zip -r MewtPhotos.ipa Payload`, upload as artifact. AltStore re-signs it with the free Apple ID [DOC: community-reported unsigned-IPA + AltStore flow; **[SPIKE]** first build proves it]. Pick the runner image explicitly (`macos-26` with Xcode 26.x, or `macos-15`) and pin Xcode via `xcode-select`/`maxim-lobanov/setup-xcode` rather than relying on `macos-latest` [DOC: `macos-latest` migration to macOS 26 was announced for mid-2026, unconfirmed]. Unsigned builds can pick an older SDK than signed ones [DOC: Apple forum]; verify the built `.app` runs on iOS 18+ in the spike.
  - Information per macOS build must be maximised: each spike build is a **Diagnostics build** with many independent probes (below).
- Compile-error risk in the app target is the expensive failure (a 10x-minute iteration to learn about a typo). Mitigations: keep the target thin; Core carries the logic; use Swift 5 language mode + warnings in the app target; write adapter code against the documented signatures only; read each adapter file twice before pushing; consider a one-time review by running the same file through `swiftc -parse` in WSL2 (syntax only, catches typos for free).

---

## Suggested Build Order (feasibility spikes first)

| # | Phase | Contents | Needs macOS CI? | Depends on |
|---|-------|----------|-----------------|------------|
| 0 | **Foundations (Windows/Linux only)** | Create private GitHub repo; commit existing project; `server.yml`; Swift toolchain in WSL2; `ios/Packages/MewtPhotosCore` skeleton + `Wire` types + fixtures + `tests/wire-fixtures.test.ts` + `tests/contract/serve.ts`; `ios-core.yml` green with one contract test (pair + status). | No | - |
| 1 | **Spike build A: toolchain + LAN** (in parallel with phase 0 tail) | XcodeGen project, `ios-build.yml`, unsigned `.ipa` -> AltStore install; app shows `GET /health`, pairing via manual URL+code (QR later), `/status`; RunLog + ShareLink export; Info.plist keys (local network, ATS). **Pass:** app launches on iOS 18, plain-HTTP call reaches the PC, log export works. | **Yes (1-3 builds)** | 0 |
| 2 | **Spike build B: PhotoKit reality** (Diagnostics screen, one build, many probes) | (a) full-access authorisation; enumerate count + timing with/without resources on the real library (decides change token); (b) resource dump for sample assets (types, filenames, UTIs, edited/Live/RAW/iCloud); (c) export photo, Live Photo pair, video, iCloud-only item: bytes are originals (magic bytes, size vs expectation), speed, iCloud progress/failure error codes; (d) upload the exported files with the real Core uploader at 8 vs 32 MiB chunk, 1 vs 2 workers, MB/s reported; (e) behaviour on screen lock with `isIdleTimerDisabled`. **Pass/fail criteria decide the project** (original bytes; usable video throughput; iCloud download works). | **Yes (1-3 builds)** | 1 |
| 3 | **Server additions S1, S2, S4 (+S5)** + vitest + docs/api.md | Pure Windows work; runs in parallel with 1-2. | No | 0 |
| 4 | **Core engine to green on Linux** | `ServerClient`, `UploadMachine`/`ResumableUploader`, `ResourceState`, `Inventory`, `Planner`, `ResourceNaming`, `Reconciler`, `BackupCoordinator` with fakes; T1-T4 including Live Photo same-folder contract test. | No | 0, 3 (contract for S1/S2/S4) |
| 5 | **App v1: pair + back up now** | PhotoKit adapters (from spike code), `AppModel`, Pair/Backup/Issues/Log views, Keychain, idle-timer + background grace. Manual retry. | Yes (few builds) | 2, 4 |
| 6 | **Incremental, Live Photos/RAW/edits/iCloud polish** | `/assets/check` skip at scale, resource set + naming per spike data, iCloud transient/permanent classification, Issues retry, re-check with PC, Reconciler banner. Device matrix from the roadmap. | Yes | 5 |
| 7 | **Optimisations driven by measurements** | Change token (if scan > 10 s), streaming hash (if hashing shows up), chunk/worker tuning, `POST /diagnostics` (O1). | Yes | 6 |

Phase ordering rationale: spikes (1, 2) decide whether native is viable at all and what the PhotoKit data really looks like, so they come before app features; server changes (3) and Core (4) need no macOS minutes, so they absorb the long middle of the project at ~1x cost while the scarce macOS budget is spent on device-only questions; the app target (5) is last because it is the thin adapter over already-tested Core.

---

## Architectural Patterns

### Pattern 1: Protocol seam at every Apple boundary
**What:** `PhotoLibraryProviding`, `ResourceExporting`, `HTTPTransport`, `KeychainStoring`, `ConnectivityProviding` defined in Core; Apple implementations in the app target; fakes in tests.
**When:** Any API that exists only on Apple platforms or touches I/O.
**Trade-offs:** A few protocols and value types; in return ~90% of the logic compiles and runs on Linux and the Apple-only surface is a few hundred lines that are easy to review by eye.

### Pattern 2: Pure state machines with effects outside
**What:** `ResourceState.apply`, `UploadMachine.next`, `Planner.plan`, `Reconciler.reconcile` take values and return values/actions; the actor loop performs the I/O.
**When:** Anything with retry/branching rules (uploads, truth gating).
**Trade-offs:** Slightly more types; failure-path tests become table-driven and instant.

```swift
enum UploadAction { case create, sendChunk(offset: Int), resync, finish, wait(Duration), restartFromExport, fail(UploadFailure), done(UploadResult) }
func next(_ s: UploadState, _ e: UploadEvent) -> (UploadState, UploadAction)   // no I/O, no clock
```

### Pattern 3: Server is the only source of "backed up"
**What:** Inventory states `confirmed`/`serverKnown` only from server responses; UI shows server-derived counts; periodic re-check demotes stale entries.
**When:** Always; this is the product's core value.

### Pattern 4: Worker pool bounded by temp disk and server concurrency
**What:** N end-to-end workers + `ExportGate`; backpressure is implicit.
**When:** Foreground transfers of large originals with limited phone storage.

---

## Anti-Patterns

### Anti-Pattern 1: Logic in the app target
**What people do:** Put scanning/upload logic in view models or PhotoKit adapters.
**Why it's wrong:** It can only be compiled on a macOS CI build and never unit-tested; every bug costs ~10 CI-minutes and a device round trip.
**Do this instead:** Adapters convert and forward; all decisions live in Core.

### Anti-Pattern 2: Trusting `/assets/check` (as it is today) or the inventory alone
**What people do:** Show "backed up" because a local row or a stale server answer says so.
**Why it's wrong:** Server answers from the DB without checking disk [SRC]; local rows survive PC-side deletion.
**Do this instead:** S2 + `serverKnown` labelling + "Re-check with PC" + Reconciler.

### Anti-Pattern 3: Blind retry of non-idempotent calls
**What people do:** Retry `POST /uploads` after a timeout.
**Why it's wrong:** Duplicate attempt rows break count equality; may create parallel partial uploads.
**Do this instead:** S4 (idempotent by assetId); on ambiguity `GET`/resume first.

### Anti-Pattern 4: Hashing or exporting everything up front
**What people do:** Export+hash the whole library before uploading.
**Why it's wrong:** Fills the phone, triggers a full iCloud download, and delays the first byte (the Safari path's 27-80 s pre-check problem).
**Do this instead:** Check by assetId first; per-resource export/hash/upload inside a bounded worker.

### Anti-Pattern 5: Using the default adjustmentData/`FullSizeRender` names blindly
**What people do:** Upload with `originalFilename`.
**Why it's wrong:** Every edited asset yields `FullSizeRender.jpg`; the server appends `(2)`, `(3)` ... and the edit is unlinked from its photo.
**Do this instead:** `ResourceNaming` derives `IMG_E<nnnn>` from the primary resource's stem.

### Anti-Pattern 6: Making the app target Swift 6 strict before CI feedback is cheap
**What people do:** Enable strict concurrency errors on code that touches PhotoKit/SwiftUI.
**Why it's wrong:** Non-Sendable Apple types produce errors discoverable only on 10x macOS builds.
**Do this instead:** Core in Swift 6 mode (verified on Linux), app target Swift 5 mode with complete-checking warnings.

---

## Scaling Considerations

(One user, one phone, one PC: scale means library size and file size, not users.)

| Scale | Architecture Adjustments |
|-------|--------------------------|
| ~1k assets | Full scan, in-memory plan, single `/assets/check` batch. |
| ~10-30k assets | Resource lookup only for new/modified assets; `/assets/check` in batches of 5000 (server `assetId` lookup is indexed on `(device_id, asset_id)` [SRC]); inventory writes batched per scan in one transaction; UI snapshots throttled. Measure scan time (decides change token). |
| 100k assets / 100+ GB first run | Keep plan ordering (photos and small files first, then videos) so progress is visible early; resumable run across many foreground sessions (state is in Inventory); server `fileIntact` re-hash per duplicate and the `serialize()` placement queue [SRC, CONCERNS] become the PC-side bottleneck for large duplicates; consider fixing those server items then. |

### Scaling Priorities

1. **First bottleneck:** LAN video throughput (unknown, measured 0.5 MB/s in Safari) and iCloud download speed: spike measures; tune chunk size/workers.
2. **Second bottleneck:** First-run duplicates of an already Safari-backed-up library: each duplicate costs a full export + hash on the phone and a full re-read on the PC; acceptable once, and not repeated because assetId rows then exist.

---

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| PC server `/api/v1` | `ServerClient` over `HTTPTransport` | Bearer key from Keychain; base URL from pairing link; first run triggers Local Network prompt |
| PhotoKit | Adapters in app target only | Full access required for `libraryCount`; never write/delete assets (`PHAssetChangeRequest` unused; request `.readWrite` authorization only because enumeration of the full library needs it) |
| AltStore | Receives the unsigned `.ipa` artifact | 7-day refresh; bundle id rewrite by AltStore; refresh keeps Documents and Keychain |
| GitHub Actions | Linux (tests) + macOS (IPA) | macOS minutes are the scarce resource |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| App target <-> Core | Protocols + `AsyncStream<RunSnapshot>` | No Apple types in Core signatures |
| Coordinator <-> Inventory | `await` actor calls with events | Reducer enforces truth gate |
| Core <-> server | JSON per `shared/schemas.ts`, fixtures as the drift detector | Only additive server changes (S1, S2, S4, S5) |
| Swift tests <-> server | `tests/contract/serve.ts` subprocess over loopback | Same code the iPhone uses, minus the radio |

---

## Sources

- `C:/codes/claude/mewtphotos/server/app.ts`, `server/engine.ts`, `server/security.ts`, `server/metadata.ts`, `server/db.ts`, `shared/schemas.ts`, `tests/helpers.ts`, `.planning/codebase/CONCERNS.md`, `docs/api.md`, `docs/ROADMAP_IOS_COMPANION.md`: HIGH (read directly).
- GitHub Actions billing: https://docs.github.com/en/billing/concepts/product-billing/github-actions (2,000 free min/month on private repos; per-minute rates Linux $0.006 vs macOS $0.062; public repos free): MEDIUM-HIGH.
- Runner images (Ubuntu 24.04 ships Swift 6.3.x; macOS 26 / Xcode 26.x images; macOS 14 image retiring): https://newreleases.io/project/github/actions/runner-images/release/ubuntu24%2F20260705.232 , https://github.blog/changelog/2025-09-11-actions-macos-26-image-now-in-public-preview/ , https://github.com/actions/runner-images/issues/13008 : MEDIUM.
- Unsigned IPA build flags and AltStore flow: https://git.tdem.in/MrKai77/Export-unsigned-ipa-files , https://dev.to/samay15jan/breaking-into-apples-walled-garden-almost-4a8m , https://developer.apple.com/forums/thread/795881 : LOW-MEDIUM (community; proven only by the first spike build).
- XcodeGen with local SPM packages: https://dev.to/vgorloff/xcodegen-with-local-swift-packages-4g29 : LOW-MEDIUM (latest version/syntax unconfirmed).
- PHPersistentChangeToken API shape: https://developer.apple.com/videos/play/wwdc2022/10132/ : MEDIUM (expiry error handling not confirmed; treated as "fall back to full diff").
- PHAssetResource types and `FullSizeRender` / `Adjustments.plist` names: https://developer.apple.com/documentation/photos/phassetresourcetype.md , https://developer.apple.com/forums/thread/771373 : MEDIUM-LOW (forum evidence only; verified by the Diagnostics dump).
- Swift toolchains for Ubuntu 24.04 / Windows: https://linuxcapable.com/how-to-install-swift-on-ubuntu-linux/ , https://learn.arm.com/install-guides/swift/ : MEDIUM (WSL2 use is an inference).

---
*Architecture research for: native iPhone photo-backup client integrating with the existing Mewt Photos Windows server*
*Researched: 2026-10-11*
