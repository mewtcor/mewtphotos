# Roadmap: native iOS companion app

**Status: plan only. Nothing here is built, and nothing should be built until explicitly approved.**
No Swift, Xcode, or iOS dependency exists in this repository.

Everything below is a design proposal based on Apple's documented frameworks. It has not been
prototyped; items marked *(verify)* are assumptions to confirm early in milestone 1.

## Why a native app

The Safari page and Shortcut can only send what you hand-pick, may receive converted copies, lose the
video half of Live Photos, and stop when the phone locks. A native app using PhotoKit can list the
library, identify assets stably, read original resources, and continue uploads in the background.
That is what makes "back up everything new, and tell me what is missing" possible.

## 1. Proposed architecture (Swift / SwiftUI)

```
PhotoBackupApp (SwiftUI)
├─ PairingView / StatusView / BackupView / IssuesView
├─ BackupCoordinator        orchestrates a run; owns state (Observable)
├─ LibraryScanner           PhotoKit enumeration and change tracking
├─ ResourceExporter         PHAssetResource → temp file + SHA-256
├─ UploadClient             URLSession (foreground + background) speaking /api/v1
├─ ServerDiscovery          Bonjour browse, manual address fallback
├─ Inventory (SQLite/GRDB or SwiftData)   asset → resources → state
└─ KeychainStore            device key
```

- Minimum iOS: the oldest version your iPhone runs at the time; SwiftUI + async/await need iOS 15+,
  `PHPersistentChangeToken` needs iOS 16+.
- One coordinator, plain value types for API payloads mirroring `shared/schemas.ts`.

## 2. PhotoKit integration

- Request `PHPhotoLibrary.requestAuthorization(for: .readWrite)`. **Full access** is required to
  enumerate the library. With **limited access** the app sees only chosen items and must say so
  in the UI and report `libraryCount` as unknown, exactly like the web page does today.
- Enumerate with `PHAsset.fetchAssets(with:)`, including hidden and burst assets as an option.
- Identity: `PHAsset.localIdentifier` (stable on one device; changes after restore to a new device).
  Sent as `assetId`. Each asset has one or more `PHAssetResource`s; the upload unit is the resource,
  with id `"<localIdentifier>/<resource type>"`.
- Changes: store a `PHPersistentChangeToken` and call `fetchPersistentChanges(since:)` to get
  inserted / updated / deleted identifiers; fall back to a full scan if the token expired.

## 3. Incremental backup design

1. Scan → inventory rows `(assetId, resourceType, filename, modificationDate, state)`.
2. `POST /assets/check` in batches of up to 5000 `assetId`s → skip everything already known.
3. For the rest: export, hash while exporting, `POST /uploads` **with `sha256`** → the server answers
   `duplicate` immediately for content it already has (for example photos backed up earlier via Safari),
   so nothing is sent twice.
4. Upload, `finish`, mark the inventory row `verified` only on the server's `verified`/`duplicate`.
5. Edited assets: adjustments change `modificationDate` and add resources; treat as new resources,
   never as replacements. The server never deletes.
6. Deletions on the phone are never propagated to the PC.

Session reporting uses fields the API already has: `libraryCount` (total assets seen),
`selectedCount`, `unavailableCount`. Only this client could ever justify setting library coverage to
"verified", and only when every enumerated resource is confirmed; that flag stays server-controlled.

## 4. Original media preservation

- Use `PHAssetResourceManager.writeData(for:toFile:options:)`, which delivers the stored resource bytes
  rather than a rendered image. Resource types to back up: `.photo`, `.video`, `.pairedVideo`
  (Live Photo video), `.fullSizePhoto` / `.fullSizeVideo` (edited renders), `.alternatePhoto` (RAW in
  RAW+JPEG pairs), `.adjustmentData`. ProRAW is a `.photo` resource with a DNG type.
- Live Photos: upload `.photo` and `.pairedVideo` as two files with the same base name so they stay
  together on disk. *(verify)* The server's extension allow-list may need `.aae`/`.plist` for adjustment data.
- iCloud-only originals: set `isNetworkAccessAllowed = true` to download; if the download fails, record
  the resource as **unavailable** and report it. Never mark it backed up.
- Never use `PHImageManager.requestImage` for backup; it returns rendered copies.

## 5. Background execution limits

iOS does not allow an app to run or scan the photo library continuously in the background.
What is realistic:

- **Background `URLSession` upload tasks** continue after the app is suspended, but only from a file on
  disk and one request per file. Use `POST /files` (one request) or a single large `PATCH`; resume
  after failure via `GET /uploads/:id` when the app is next woken. *(verify)* how reliably iOS
  schedules background transfers to a local-network host over plain HTTP.
- Exporting resources to temp files must happen while the app runs, and needs free space on the phone.
  Export and enqueue in bounded batches.
- **`BGProcessingTask`** (requires external power / network options) can give occasional minutes to scan
  and enqueue; timing is decided by iOS and is not guaranteed.
- Foreground runs remain the dependable path. The UI must show "N items waiting; open the app to continue".

Do not promise automatic, continuous, or scheduled-to-the-minute backups.

## 6. Scheduling and triggers

- Manual "Back up now" at any time.
- Opportunistic: on app launch, on `PHPhotoLibraryChangeObserver` while running, and in
  `BGProcessingTask` with `requiresExternalPower` as an option.
- Wi-Fi only: check `NWPathMonitor` for a non-cellular, non-expensive path and reachability of the paired server.
- A Shortcuts automation ("when charger connected → open app") is a user-side option worth documenting.

## 7. Local pairing and security

- **Discovery:** the server would advertise `_mewtphotos._tcp` via Bonjour; the app browses with
  `NWBrowser`. Requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` in Info.plist.
  On Windows, advertising needs an mDNS responder: either a pure-JS library inside the server or the
  existing Bonjour service used **read-only through its API**. The existing Bonjour installation must
  not be modified. Manual address entry and QR scan stay as fallbacks.
- **Pairing:** same `POST /pair` with the dashboard code (scan the existing QR code). Store the key in the Keychain.
- **Transport:** plain HTTP to a local address needs an App Transport Security exception
  (`NSAllowsLocalNetworking`). Better: add HTTPS to the server with a self-signed certificate and pin its
  public key at pairing time (the QR code can carry the fingerprint). A native app can pin; Safari cannot,
  which is why the web flow stays on HTTP. This is the main server change worth doing for the app.

## 8. Windows API compatibility

Already in place and intended for reuse without change:

| Need | Existing API |
|---|---|
| Pairing, device key | `POST /pair`, `Authorization: Bearer` |
| Sessions with library / selected / unavailable counts | `/sessions` (`method: "native"`, `libraryCount`) |
| Skip known assets | `POST /assets/check`, `assetId` on uploads |
| Skip known content before sending | `sha256` on `POST /uploads` |
| Resumable transfer | `PATCH /uploads/:id` + `Upload-Offset`, `GET /uploads/:id` |
| Single-request transfer (background sessions) | `POST /files` |
| End-to-end integrity | `sha256` on `finish`; `endToEndVerified` in the result |
| Progress and errors | `SessionSummary`, error codes, dashboard events |

Likely additions (small, versioned under `/api/v1` or `/api/v2`): Bonjour advertisement; optional HTTPS
with pinning; grouping key for Live Photo pairs; `GET /assets?since=` so the app can reconcile its
inventory against server records; allow-listing sidecar types.

## 9. Development and build requirements (no Mac today)

Building and signing an iOS app requires Xcode, which runs only on macOS. Options:

| Option | Cost | Notes |
|---|---|---|
| Used Mac mini (Apple silicon) | One-time purchase | Simplest, and enables on-device debugging over USB/Wi-Fi |
| Cloud Mac rental (MacinCloud, AWS EC2 Mac, Scaleway, etc.) | Hourly/monthly | Works for building; on-device debugging is awkward because the phone is not attached |
| CI macOS runners (GitHub Actions, Xcode Cloud, Codemagic) | Free tiers exist | Good for producing a signed `.ipa` from Windows-edited source; no interactive debugger. Prices and free allowances change; check current terms |

Signing and installing:

- **Free Apple ID:** apps expire after 7 days and are limited in number; background modes work, but
  re-signing weekly is required.
- **Apple Developer Program (paid, yearly):** 1-year profiles, TestFlight, no weekly refresh.
  This conflicts with the "completely free" goal and is the honest price of a low-maintenance native app.
- **AltStore / AltServer** can *install and refresh* an already-built `.ipa` using a free Apple ID.
  It **cannot compile** an app; a macOS build step is still required. If used, it would be used as-is,
  without changing the existing AltStore/AltServer setup.

Recommended first step: build unsigned on a free CI macOS runner to prove the toolchain, then decide
between a second-hand Mac and CI + AltStore based on how painful debugging is.

## 10. Testing strategy

- **Unit (XCTest):** inventory state machine, upload client against a mocked `URLProtocol`, hashing.
- **Contract:** run the real Windows server and replay the app's request sequences from Node tests
  (the server already has an integration suite to extend), so both sides are checked against `shared/schemas.ts`.
- **Device matrix:** HEIC, ProRAW, Live Photo, burst, edited photo, slow-motion and HDR video,
  iCloud-only originals, limited-access permission, 10k+ asset library.
- **Interruption:** kill app mid-upload, lock phone, leave Wi-Fi, stop the server, fill the phone's storage.
- **Truthfulness:** for every run, the app's "verified" count must equal the server's; any difference is a bug.

## 11. Milestones

Rough effort for one developer working part-time; estimates, not commitments.

| # | Milestone | Outcome | Effort |
|---|---|---|---|
| 0 | Toolchain | Empty SwiftUI app built on macOS (owned, rented or CI) and installed on the iPhone | 1–3 days |
| 1 | Feasibility spikes | Confirm: original bytes via `PHAssetResourceManager`; local HTTP with ATS exception; background upload to the PC | 3–5 days |
| 2 | Pair + manual backup | QR pairing, pick-all foreground backup of `.photo`/`.video`, end-to-end hashes | 1–2 weeks |
| 3 | Inventory + incremental | Full scan, `assets/check`, change tokens, issues list (failed / unavailable) | 1–2 weeks |
| 4 | Live Photos, RAW, edits | All resource types, pairing on disk, iCloud download handling | 1 week |
| 5 | Background + triggers | Background sessions, `BGProcessingTask`, Wi-Fi/charging rules | 1–2 weeks |
| 6 | Discovery + HTTPS pinning | Bonjour, certificate pinning, server changes | 1 week |
| 7 | Reconciliation | Library-vs-server report; only now consider a coverage-verified status | 1 week |

Milestone 1 decides whether the rest is worth doing: if originals or background uploads do not behave
as documented on your iOS version, the plan changes before much is invested.
