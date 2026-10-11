# Pitfalls Research

**Domain:** Native iPhone original-preserving photo backup client (SwiftUI + PhotoKit + URLSession) added to an existing LAN backup server, built without a Mac (GitHub Actions macOS runner, unsigned .ipa, AltStore with a free Apple ID)
**Researched:** 2026-10-11
**Confidence:** MEDIUM overall. Server-side interactions are HIGH (read directly from `server/engine.ts`, `server/app.ts`, `server/security.ts`, `server/metadata.ts`, `shared/schemas.ts`). Toolchain/billing/AltStore limits are HIGH-MEDIUM (GitHub docs, AltStore FAQ, Apple DTS thread). PhotoKit specifics are MEDIUM (Apple forum threads plus well-known behaviour; each is tagged and the ones that matter are turned into spike checks because no one can verify them without the real phone).

Tags used below: **[H]** verified in repo code or official docs this session, **[M]** consistent secondary sources or established platform behaviour, **[L]** recalled from experience, must be proved by the feasibility spike before relying on it.

Phase names used for mapping (match the downstream roadmap): **A** Toolchain/feasibility, **B** Pairing, **C** Scan/inventory, **D** Export/upload, **E** Live Photos & special types, **F** Reporting/truthfulness, **S** Small server patches (fold into whichever phase first needs them, but before D relies on them).

---

## Critical Pitfalls

### Pitfall 1: The blind-coding loop burns the macOS minute budget on compile errors

**What goes wrong:**
Every typo, misremembered PhotoKit signature or Swift concurrency error costs a full macOS build. GitHub Free gives 2,000 minutes per month for private repos and macOS minutes bill at roughly 10x Linux (docs list macOS at $0.062/min vs $0.006 Linux) [H], so the free allowance is about 200 macOS minutes. At 5-8 minutes per cold build that is 25-40 builds a month, and a feature phase can burn it in a week. The project is then stuck until the month resets, or the user pays.

**Why it happens:**
Swift cannot be compiled on Windows, so the author "compiles" by pushing. Code written from memory for Apple frameworks has a high first-build error rate. Newer Xcode defaults (strict concurrency, main-actor default isolation in recent templates) turn sloppy-but-working code into hard errors.

**How to avoid:**
- Put everything that does not import PhotoKit/SwiftUI/UIKit (API client models, request building, state machine, hashing loop, retry/backoff, count reconciliation) in a Foundation-only Swift package. Build and test it on a Linux runner (1x billing) or with the Swift toolchain for Windows locally; only the thin UI/PhotoKit shell needs macOS. Use `FoundationNetworking` on Linux for URLSession. [M]
- Pin `runs-on: macos-15` (not `-latest`, not `-xlarge`) and select the Xcode version explicitly so a runner image bump cannot break a green build.
- Trigger the macOS job only on `workflow_dispatch` or a tag, never on every push; add `concurrency: cancel-in-progress`. Skip tests on macOS.
- Set `SWIFT_VERSION = 5` (Swift 5 language mode) and `IPHONEOS_DEPLOYMENT_TARGET = 18.0`; keep warnings non-fatal.
- Use only documented APIs and the fewest third-party packages (every package is extra build time and unfixable errors).
- Check the first real build's billed minutes on GitHub's billing page and size the monthly build budget from that, not from the "20-40" guess in PROJECT.md. Consider that a public repository gets free standard runners: a user decision, flagged here because the source holds no secrets.
- Batch changes: write a whole feature, self-review against Apple docs, then spend one build.

**Warning signs:**
More than two consecutive red builds; "fix typo" commits; billing page above 50% before mid-month.

**Phase to address:** A (set up the split-package layout and the cheap Linux gate before any feature work).

---

### Pitfall 2: Project plumbing that only Xcode normally does (project file, Info.plist, unsigned .ipa)

**What goes wrong:**
There is no Xcode to generate the `.xcodeproj`, so a hand-written `project.pbxproj` is wrong in ways that only surface on CI. The `.ipa` builds but is malformed (not `iphoneos`, missing `Payload/`, leftover signature) and AltStore refuses it or the app crashes at launch. Or it builds fine but a required `Info.plist` key is missing, so the first permission request crashes the app, and discovering that costs a whole build, install and phone round trip.

**Why it happens:**
`INFOPLIST_KEY_*` build settings cover only some keys; the `NSAppTransportSecurity` dictionary and some privacy keys need a real `Info.plist`. Unsigned packaging is a manual `xcodebuild` + `zip` recipe rather than an Archive/Export.

**How to avoid:**
- Generate the project on the runner from a checked-in XcodeGen `project.yml` (or equivalent); do not hand-author `pbxproj`. Ship an empty entitlements setup: no capabilities at all (see Pitfall 4).
- Use a real `Info.plist` file containing: `NSPhotoLibraryUsageDescription`, `NSLocalNetworkUsageDescription`, `NSCameraUsageDescription` (QR scan), `NSAppTransportSecurity` -> `NSAllowsLocalNetworking = true`, `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = true`.
- Build: `xcodebuild -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`, copy `.app` to `Payload/`, zip to `.ipa`.
- Add a cheap CI gate before uploading the artifact: `unzip -l` shows `Payload/<App>.app/Info.plist`; `PlistBuddy -c "Print :NSPhotoLibraryUsageDescription"` etc. for every required key; fail the build if any is missing. Set artifact retention to a few days (GitHub Free artifact storage is 500 MB shared) [H].

**Warning signs:**
AltStore error on install; app icon appears then closes instantly; crash on first tap of "Allow photos".

**Phase to address:** A.

---

### Pitfall 3: AltStore free-account limits and identity churn wipe state or block installs

**What goes wrong:**
- Free Apple IDs allow 3 active sideloaded apps (AltStore error 2009) and 10 App IDs per rolling 7 days (error 1009) [H, AltStore FAQ]. AltStore itself and any other sideloaded apps count. Each distinct bundle ID (and each app extension) consumes App IDs.
- The app stops launching on day 8 if AltServer on the PC could not refresh it (phone not on the same Wi-Fi, iTunes/iCloud components broken, Apple ID sign-in prompt unanswered). A run that straddles the expiry dies mid-way.
- Changing the bundle ID to "work around" a limit, or installing under a different Apple ID, creates a different app identity: Keychain items (the device key), the Photos and Local Network grants, and the app's local state are lost, forcing a re-pair and a full re-scan. [M]

**Why it happens:**
Developers iterate bundle IDs during testing and add extensions/widgets/share targets, each burning App IDs. The weekly refresh depends on a PC process the user does not think about.

**How to avoid:**
- One bundle ID, chosen once, never changed. No extensions, widgets, or share targets. Install new builds over the existing install (AltStore "install .ipa" replaces in place and keeps app data) and never delete the app to "fix" something.
- Do not depend on local state being durable: the server is the source of truth (`/assets/check`, hash dedupe), so a wiped app costs a re-scan, not data (see Pitfall 17).
- Show "signature expires in N days" in-app (read the `ExpirationDate` of `embedded.mobileprovision` from the bundle, [L] verify on a sideloaded build) and refuse to start a long run if fewer than ~12 hours remain.
- Document the refresh routine (phone on home Wi-Fi, AltServer running on this same PC, which is also the backup PC) in the README.
- Keep the existing AltStore/AltServer/iTunes/Apple Devices setup untouched, as PROJECT.md requires.

**Warning signs:**
AltStore error 1009/2009 on install; "Unable to Verify App" on launch; Photos/Local Network prompts appearing again after an install.

**Phase to address:** A (establish identity rules) and every release thereafter.

---

### Pitfall 4: Assuming entitlements, Keychain, Photos and Local Network behave the same when sideloaded

**What goes wrong:**
A free account cannot use paid capabilities: iCloud/CloudKit, Push, Associated Domains, Keychain sharing groups, Network Extensions, Multicast Networking, HealthKit, Increased Memory Limit, etc. [M]. A project that lists any capability makes signing fail or silently strip it. Separately, people assume Keychain/Photos/Local Network "just work" and discover otherwise only after several build cycles.

**Why it happens:**
Capabilities get added reflexively (Background Modes, App Groups "for later"). Whether Keychain, Photos and Local Network work under AltStore re-signing is rarely proved up front.

**How to avoid:**
- Ship with an empty entitlements file. None of these features need one: Photos read access and Local Network are Info.plist usage-description based, not entitlement based; the app's own default Keychain access group needs no entitlement. [M]
- Make the first spike build exercise all of them in one install: request `.readWrite` photo access and list `PHAsset` count; write a Keychain item, kill the app, relaunch and read it, then do it again after an AltStore refresh; make one local HTTP request to the PC to trigger the Local Network prompt.
- Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no access group, and design a "re-pair" path (the server can revoke devices anyway). Treat the Keychain as convenient, not as durable across Apple ID changes.
- Background modes (`UIBackgroundModes`) and background URLSession are out of scope for v1; do not add them "just in case".

**Warning signs:**
`errSecMissingEntitlement` (-34018) from Keychain calls; AltStore signing errors mentioning capabilities; device key gone after reinstall.

**Phase to address:** A (spike), B (Keychain design).

---

### Pitfall 5: No debugger and no logs means silent crashes and blind "it doesn't work"

**What goes wrong:**
A force-unwrap, array out-of-bounds, `precondition`, or jetsam (memory) kill ends the app with no message. The only feedback is "it closed", and each hypothesis costs a build. A user report of "stuck" cannot be diagnosed.

**Why it happens:**
Without a Mac there is no Xcode console, no Console.app, no symbolicated crash logs. Observability must be built into the app from the first build.

**How to avoid:**
- First feature built, before pairing: a persisted ring-buffer log file in the app container with each entry flushed (stage breadcrumbs such as "export start/end", "hash start/end", "PATCH offset N", with resource id, size, elapsed), plus a launch marker so the next launch can report "previous run ended abnormally at <last breadcrumb>".
- Ship logs to the PC: a tiny authenticated additive endpoint (or reuse the existing log table) so a log dump is one tap and readable on the PC. A share-sheet export is the fallback.
- Log `NSError` domain, code and `NSUnderlyingError` for every failure, never only `localizedDescription` (it conflates -1009 local network, -1022 ATS, -1001 timeout, -1005 connection lost).
- Redact the bearer token and pairing code in logs (the log will be pasted into chats).
- Crash reports still exist on the phone under Settings > Privacy & Security > Analytics & Improvements > Analytics Data; document how to share the `.ips`. [M]
- Avoid force-unwraps and unchecked indexing in code that is never compiled locally; use `guard` and log.

**Warning signs:**
"App closed by itself" reports; any failure message that is just "The operation couldn't be completed".

**Phase to address:** A (logging scaffold is a phase-A deliverable; reused by all later phases).

---

### Pitfall 6: Local-network and ATS failures misdiagnosed (and an iOS 18 bug)

**What goes wrong:**
The first request to `http://192.168.x.x:port` fails with `NSURLErrorNotConnectedToInternet` (-1009, "Local network prohibited") and the developer toggles ATS settings that cannot help. Two separate mechanisms exist: ATS (TLS, error -1200/-1022) and Local Network Privacy (error -1009). [H, Apple DTS thread 788044 / TN3179]. On iOS 18.x (reported on 18.4) a bug (Radar 131764908) left a stale in-memory "denied" state: the app fails even after the user granted access, including after reinstall; fixed in iOS 18.6, reboot of the phone clears it. [H]

**Why it happens:**
- Apple documents that ATS applies only to public host names, not IP addresses, unqualified host names or `.local` names. So raw-IP HTTP often works without any exception [H]; people then over-add `NSAllowsArbitraryLoads`. DTS recommends `NSAllowsLocalNetworking` for apps that talk to local devices [H], and the DTS thread shows `NSAllowsArbitraryLoads` mixed with local-networking giving odd results [H].
- The Local Network prompt appears on the first local connection, not at launch, and there is no direct "am I allowed?" API. [M]

**How to avoid:**
- Info.plist: `NSAllowsLocalNetworking = true` and `NSLocalNetworkUsageDescription`; do not add `NSAllowsArbitraryLoads`. Use IP or unqualified host names only (a fully qualified name such as `pc.home.example` would not be exempt and fails with -1022).
- Trigger the Local Network prompt deliberately at pairing (one `GET /api/v1/health`), expect the first attempt to fail while the prompt is up, and retry after a short delay.
- Map error codes to messages: -1009 on a local IP = "Allow Local Network for this app in Settings > Privacy & Security > Local Network, then restart the phone if it still fails"; -1022 = ATS; -1001 = timeout; -1004 = server unreachable (PC off, wrong IP, firewall).
- Spike on the user's actual iOS version; if it is 18.0-18.5, tell the user to update to 18.6+ or reboot after granting.
- Set `allowsCellularAccess = false` on the session so a Wi-Fi drop does not silently fall to cellular.

**Warning signs:**
Safari reaches the server but the app cannot; error -1009 on a reachable LAN; works after a phone reboot.

**Phase to address:** A (spike proves HTTP to the PC), B (pairing UX and error mapping).

---

### Pitfall 7: The server address changes and the app just says "failed"

**What goes wrong:**
Pairing stores `http://<ip>:<port>`. A DHCP lease change, a new router, or the PC on a different adapter makes every request fail; the app shows a wall of failures. Bonjour is deferred, so nothing re-finds the PC.

**Why it happens:**
The IP is baked into the QR code at pairing time and nothing in v1 re-resolves it.

**How to avoid:**
- Make the server address editable in the app, and show "Cannot reach PC at <address>" as a distinct, non-failure state (the items stay pending, nothing is marked failed).
- Run a `GET /api/v1/health` reachability check before each run and again after every network error burst.
- Recommend a DHCP reservation for the PC in the README; verify the Windows network profile is Private so the firewall rule applies.

**Warning signs:**
All items fail at once after a reboot or router change.

**Phase to address:** B.

---

### Pitfall 8: Using any PhotoKit path that returns rendered copies

**What goes wrong:**
The files arrive as `.jpeg` or re-encoded video, which is exactly the problem the project exists to fix. Sources of this: `PHImageManager.requestImage*`, `requestAVAsset`, `requestExportSession`, `PHPickerViewController` (transcodes unless asked for the current representation and drops Live Photo resources), or reading bytes through `PHContentEditingInput`.

**Why it happens:**
The high-level APIs are the most documented and the easiest to write blind.

**How to avoid:**
- Only `PHAssetResourceManager.default().writeData(for:toFile:options:)` or `requestData(for:options:...)` with `PHAssetResourceRequestOptions.isNetworkAccessAllowed = true` on `PHAssetResource` objects.
- Prove "original" empirically in the spike: back up one known HEIC, one ProRAW, one Live Photo and one HEVC video, then SHA-256 compare against the same items imported by USB through the user's existing Windows Apple Devices/Photos import. Byte-identical is the acceptance test, not "the extension is right".

**Warning signs:**
Output extensions `.jpeg`/`.jpg` for HEIC sources; file sizes smaller than expected; no `.heic` on disk.

**Phase to address:** A (proof), D (implementation).

---

### Pitfall 9: Limited access or default fetch options silently hide part of the library

**What goes wrong:**
The app reports "everything backed up" while seeing only a subset. Causes: authorization is `.limited` (user chose "Select Photos"); `PHFetchOptions` defaults exclude hidden assets and non-representative burst frames; source types are not what you expect (shared-album items are not the user's own originals); the user changes access later in Settings.

**Why it happens:**
Fetch defaults are easy to forget. `.limited` does not throw, it just returns fewer assets.

**How to avoid:**
- Request `.readWrite` (reading the library needs it; `.addOnly` cannot read). Re-read `authorizationStatus(for: .readWrite)` at every run start and on every foreground return. `.limited`, `.denied`, `.restricted`, `.notDetermined` each get their own blocking message; a run never starts in `.limited`.
- Set `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = true`.
- Set options explicitly rather than relying on defaults: `includeHiddenAssets = true`, `includeAllBurstAssets = true`, an explicit `includeAssetSourceTypes` (decide on shared-album and iTunes-synced items; document the choice). [M] Verify on the device that Hidden-album items are returned (iOS 18 hides the Hidden album behind authentication in Photos, whether PhotoKit exposes them is [L], spike it) and report the count discrepancy if not.
- Report `libraryCount` to the server only under full access, as the existing schema comment requires.

**Warning signs:**
Phone's Photos shows more items than `fetchAssets` count; burst photos or hidden items missing from the PC.

**Phase to address:** C.

---

### Pitfall 10: Wrong or incomplete resource-type handling (edits, Live Photos, RAW+JPEG, bursts, slow-mo)

**What goes wrong:**
The proposal's list of resource types is incomplete. Missing the edited Live Photo video, base resources, or proxies means "edited Live Photo" arrives half-saved; hard-coding a short list silently drops new/unknown types; edited photos back up only the original (the user sees the edited look on the phone but the PC has the unedited image) or only the render (original lost).

**Why it happens:**
An asset has several `PHAssetResource` entries: `.photo`, `.video`, `.pairedVideo`, `.alternatePhoto` (RAW in RAW+JPEG), `.fullSizePhoto`, `.fullSizeVideo`, `.fullSizePairedVideo`, `.adjustmentData`, `.adjustmentBasePhoto`/`BaseVideo`/`BasePairedVideo`, `.photoProxy`, `.audio`. The proposal omits several. Burst members and slow-mo/Cinematic/spatial videos are single `.video` resources whose timing/depth lives in the original plus adjustment data. [M]

**How to avoid:**
- Decide policy explicitly in the phase plan and write it in PROJECT.md: v1 = originals only (`.photo`, `.video`, `.pairedVideo`, `.alternatePhoto`); edited renders (`.fullSizePhoto`, `.fullSizeVideo`, `.fullSizePairedVideo`) and `.adjustmentData` as an explicit extra, off by default or on by default but named distinctly (for example `IMG_E1234`).
- Enumerate `PHAssetResource.assetResources(for:)` and handle by an allow-list of types to upload plus a catch-all that records "type X not backed up" in the report. Never `switch` with a silent `default: break`.
- ProRAW is a single `.photo` DNG (~25-75 MB); true RAW+JPEG has `.alternatePhoto`. Test one of each.
- Edited-asset resource ids that change content must include the modification date (see Pitfall 12) so a re-edit is not skipped.

**Warning signs:**
Resource count per asset on the device differs from what was uploaded; an edited Live Photo has `.heic` and `.mov` but the video is the unedited one.

**Phase to address:** E (policy decided in C so inventory rows carry the right fields).

---

### Pitfall 11: Live Photo halves split apart on the PC (server naming and date folders)

**What goes wrong:**
The still and the paired video must share a base name and folder. On this server they can diverge three ways: [H]
1. **Name collision.** `place()` picks `IMG_1234.HEIC` or `IMG_1234 (2).HEIC` per file, independently. If an earlier different `IMG_1234.HEIC` exists in that month folder (counter reuse after a phone restore, another device, a crop), the still becomes `(2)` while the `.MOV` takes `IMG_1234.MOV`.
2. **Folder split.** The still's folder comes from EXIF `DateTimeOriginal` (local wall-clock), the video's from the `mvhd` atom (UTC, converted with the PC's time zone). Near month boundaries, or when the photo was taken in another time zone than the PC's, the two halves land in different `YYYY\MM` folders.
3. **Upload order/partial failure.** One half verified, the other failed or unavailable, with the app reporting the asset as backed up.

**Why it happens:**
The server treats every upload as an independent file; the schema has no group/pair concept.

**How to avoid:**
- Small additive server change (phase S): an optional `groupId` (and a sticky `capturedAt`/`lastModified` hint) on `UploadCreate`; the first half placed decides stem and folder, the second reuses them.
- Without a server change, the client can upload the still, read `UploadResult.path`, and send the video with that stem, but this does not fix the folder split, so prefer the server change.
- Always send `lastModified = PHAsset.creationDate` (ms) on both halves; the server uses it for the fallback folder and for file mtime.
- A Live Photo is "backed up" only when both halves are `verified`/`duplicate`; otherwise report it as incomplete with the missing half named.
- Add a server test that uploads a pair with colliding names and a month-boundary date.

**Warning signs:**
`IMG_1234 (2).HEIC` next to `IMG_1234.MOV`; a `.MOV` in the previous month's folder.

**Phase to address:** E, with the server patch in S.

---

### Pitfall 12: assetId semantics and localIdentifier stability

**What goes wrong:**
- `/assets/check` and `uploads.asset_id` work per exact string. If `assetId` is the plain `localIdentifier`, the still, the paired video and the RAW share one id, so one verified half makes the others look "known" and they are skipped. [H, server compares `asset_id` equality only]
- `localIdentifier` is stable on one device but is not stable across restore to a new phone or a rebuilt library; assuming it is permanent turns a new phone into a "nothing known" re-upload (acceptable) or, worse, an id reused for a different asset (rare, wrong skip).
- Edited-render resources keep the same resource id while their bytes change on re-edit, so the newest edit is skipped.

**Why it happens:**
The proposal specifies `"<localIdentifier>/<resource type>"` but a Live Photo can have two resources of similar type, and edits are mutable.

**How to avoid:**
- `assetId = <localIdentifier>/<resourceType rawValue>/<index>`; for mutable resources add `/<modificationDate ms>`. Originals are immutable so plain ids suffice.
- Treat assetId as a speed optimisation only. Content hash is the identity. Always send `sha256` on create, so a wrong skip can never lose data.
- On a new phone or after restore, expect every item to be re-exported and hashed; say so in the UI rather than showing "0 of N" as a failure.

**Warning signs:**
Live Photo videos never upload while stills do; an edited photo's re-edit never appears.

**Phase to address:** C (id scheme), E (edits).

---

### Pitfall 13: iCloud-only originals: stalls, silent no-callbacks, storage, and "unavailable" misuse

**What goes wrong:**
With "Optimize iPhone Storage" the original is in iCloud. Without `isNetworkAccessAllowed = true` the request fails (PhotosError networkAccessRequired). With it: the progress handler may stall (forum reports of progress stopping at about 0.5 then "Unable to locate resource"), and some assets never call either the progress or completion handler [M]; a stalled request blocks the run forever. Downloaded originals plus exported temp copies can fill the phone; Photos keeps its own downloaded copy until iOS purges it, so the phone's free space shrinks as the run progresses. Failures get recorded as `failed` (retry-loopable) rather than `unavailable`.

**Why it happens:**
There is no API that says "this resource is local", no timeout on the request, and downloads depend on iCloud, Wi-Fi and Low Data Mode.

**How to avoid:**
- Run each request under a watchdog: no progress or data for N seconds (start with 120 s, tune in the spike) -> `cancelDataRequest(_:)`, mark `unavailable_cloud` with the reason, move on, retry in a later pass. Never block the queue on one asset.
- Detect cloud-only cheaply: request with `isNetworkAccessAllowed = false` first; a networkAccessRequired error means cloud-only (Apple engineer's suggestion in forum thread 833066). [M] Use it to order work (local first) and to give an honest "N items need download from iCloud, about X GB".
- Preflight free space (`volumeAvailableCapacityForImportantUsageKey`) against the resource size (`PHAssetResource` has no public size; the KVC `fileSize` is widely used but undocumented [L], so fall back to "export, then stat"). Refuse to start an export with less than ~1.2x the expected size or 2 GB free; stop the whole run (not each item) on low space.
- Export strictly one resource at a time and delete the temp file as soon as the server returns `verified`/`duplicate`.
- Report "unavailable" separately from "failed" and send the count in `SessionComplete.unavailableCount`.

**Warning signs:**
Progress frozen at the same percentage; run never finishes; phone storage graph climbs during the run.

**Phase to address:** D (watchdog, storage), F (reporting).

---

### Pitfall 14: Memory blow-ups and temp-file mistakes in export and hashing

**What goes wrong:**
The app is killed by iOS (jetsam) halfway through the first multi-GB video, with no log. Causes: accumulating `requestData` chunks in `Data`; `Data(contentsOf:)` or one-shot `SHA256.hash(data:)` over the whole file for hashing; materialising an array of all `PHAsset`s or all resource lists for a 50k-item library; SwiftUI `List` over 50k rows with per-item `@Published` updates. `writeData(for:toFile:)` also errors if the destination exists.

**Why it happens:**
Small-file test data hides all of it; the failure only appears on the first large video, one build cycle later.

**How to avoid:**
- Stream: `writeData` to a fresh unique path (delete any leftover first), then hash with an incremental CryptoKit `SHA256` over 1-4 MB reads from a `FileHandle`, inside `autoreleasepool`. Hash cost on device is not the bottleneck (hardware accelerated, far faster than the 4 MB/s pure-JS check measured in Safari).
- `PHFetchResult` is lazy; iterate by index, process in batches of a few hundred, and keep only counters in UI state. Throttle UI progress to about 4 Hz.
- Temp folder under `Library/Caches/export`, marked `isExcludedFromBackup`, emptied at every launch (crashes leave multi-GB orphans), and wiped after each verified item.
- Spike with a 2 GB+ video and a 10k+ item library; watch for a silent exit.

**Warning signs:**
App disappears during hashing or export of a big file; phone gets warm and slow; storage shrinks after crashes.

**Phase to address:** D (export/hash), C (enumeration).

---

### Pitfall 15: URLSession upload done in a way that buffers, mis-sends, or caches

**What goes wrong:**
- Building the body as `Data` loads the video into memory. `uploadTask(withStreamedRequest:)` sends chunked transfer encoding without `Content-Length`, which the one-shot `POST /files` rejects with 411. [H]
- Sending bytes with `Content-Type: application/json` or `text/plain`: Fastify has built-in parsers for those and applies the 1 MiB `bodyLimit`, giving 413/400 instead of streaming. Only other types reach the stream catch-all. [H, `server/app.ts` lines 82 and 199]
- A cached `GET /uploads/:id` returns a stale offset, producing 409 `offset_mismatch` loops.
- Resume after failure uses a locally remembered offset instead of the server's.

**Why it happens:**
Default `URLSession.shared` caching and the many upload entry points; the server's content-type rules are not obvious.

**How to avoid:**
- Use `uploadTask(with:fromFile:)` (or `upload(for:fromFile:)`); it sets `Content-Length` and streams from disk. Send `Content-Type: application/offset+octet-stream` (the constant in `shared/schemas.ts`) and `Upload-Offset` on `PATCH`.
- Chunking: the server accepts a PATCH of any length up to the declared size, so the simplest correct design is one PATCH per attempt from the current offset. To send "from offset N" without a stream implementation written blind, write the remaining slice (or an 8 MiB chunk, the server's advertised `chunkSize`) to a temp file and send it with `fromFile`. Measure single-PATCH vs 8 MiB chunks in the spike; keep whichever is faster and simpler.
- Session config: `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`, `allowsCellularAccess = false`, `waitsForConnectivity = false`, `httpMaximumConnectionsPerHost = 1` (upload sequentially in v1; the server concurrency default is 2 but a sequential client avoids the unreserved space/quota overshoot noted in CONCERNS.md).
- Always resume by `GET /uploads/:id` (offset is measured from the file on the server, never trusted) and PATCH from that offset; handle 409 `offset_mismatch` by using the `offset` in the error body.

**Warning signs:**
411 or 413 on first upload; 409 offset loops; app memory growing during upload.

**Phase to address:** D.

---

### Pitfall 16: Client timeouts do not match a server that hashes multi-GB files before it answers

**What goes wrong:**
`finishUpload()` fsyncs, re-hashes the whole file, reads capture metadata, then queues `place()` behind a global serialize queue where it may re-hash an existing duplicate and any same-size name collision (`fileIntact()`, `hashFile(candidate)`). [H] `POST /uploads` with a known sha256 also re-hashes the stored file before answering. For a multi-GB video, plus antivirus scanning, this can exceed URLSession's default 60 s `timeoutIntervalForRequest`. The client sees -1001, counts a failure, retries, and gets 409 `upload_busy`, or worse marks a file failed that the server then successfully stored (the next run reports `duplicate`, so the count drifts).

The server also abandons a chunk that receives no bytes for 60 s (`timeouts.chunkIdleMs`), so a short phone-side stall (screen lock, Wi-Fi hiccup; Safari saw 16 s and 41 s stalls) can produce 408.

**How to avoid:**
- `timeoutIntervalForRequest` of at least 10 minutes on `finish` and on create-with-hash requests; `timeoutIntervalForResource` several hours.
- Treat -1001 and -1005 on finish as "unknown outcome", not failure: poll `GET /uploads/:id` (statuses `finalizing`, `verified`, `duplicate`) with backoff, and call `finish` again, which is idempotent (`finishUpload` returns the existing result when already verified). Cap total waiting (for example 15 minutes) and handle `upload_busy` with a capped backoff. Do not reproduce the unbounded `upload_busy` loop noted in CONCERNS.md for `web/src/uploader.ts`.
- On 408 or any transport error during PATCH, reconcile via `GET /uploads/:id`, never assume.
- Parse JSON defensively; a 200 with a non-JSON body must not hang the task (another bug in the web client).

**Warning signs:**
-1001 on `finish` for big files only; server log shows "stored" after the client reported failure; repeated `upload_busy`.

**Phase to address:** D.

---

### Pitfall 17: Local state is treated as authoritative and then lost

**What goes wrong:**
A local inventory database grows into a second source of truth. It gets lost when AltStore reinstall, expiry or deletion wipes the app, or it silently disagrees with the server (marked verified locally while the PC copy was deleted). It is also a large amount of blind-coded persistence (SQLite or SwiftData) with a high chance of build and runtime bugs.

**Why it happens:**
The proposal's `Inventory (SQLite/GRDB or SwiftData)` is designed for background resumption, which v1 does not do.

**How to avoid:**
- In v1 the server is the inventory: each run = scan, `POST /assets/check` in batches of 5000, then upload the unknowns. The local state is a small atomically written file (pending/failed/unavailable list with reasons, last session id, current upload id per resource) that can be rebuilt by re-running a scan. No GRDB, no SwiftData, no SQLite until a measured need appears.
- Persist `{resourceId -> uploadId, sha256, tempPath, size}` when an upload is created so a relaunch resumes via `GET /uploads/:id` instead of creating a second `.part` (the server resumes a `receiving` upload only when filename, size and `last_modified` all match and no request is currently writing it, otherwise it creates another).
- Always send `lastModified = PHAsset.creationDate` so resume matching works at all. [H, `createUpload` lines 144-156]

**Warning signs:**
Orphan `.part` files in the PC's `.incoming` folder; "0 known" after a reinstall.

**Phase to address:** C.

---

### Pitfall 18: PHPersistentChangeToken used as the sole "what's new" source

**What goes wrong:**
Items are silently missed. The change token (iOS 16+) has a limited history window; `fetchPersistentChanges(since:)` throws when the token is expired or history is unavailable; the token is lost whenever the app is deleted/reinstalled (a 7-day-expiry fact of life here); a library rebuild invalidates it. "No changes" is then mistaken for "all backed up". [M]

**Why it happens:**
It looks like the right incremental mechanism and is in the proposal.

**How to avoid:**
Skip it in v1 (YAGNI): full enumeration plus `/assets/check` is cheap at 5000 ids per request and always correct. If added later for speed, use it only to prioritise, always catch the expired/unavailable errors, and keep a periodic full scan as the correctness path.

**Warning signs:**
New photos that never appear in a run; token errors in the log after an AltStore reinstall.

**Phase to address:** C (decision recorded: deferred).

---

### Pitfall 19: Foreground-only means the phone sleeps and the run stops

**What goes wrong:**
After the auto-lock timeout (or a power-button press, a phone call, switching app), iOS suspends the app within seconds; sockets die. In-flight tasks return -1005/-999/-1001 when the app returns. Observed throughput (0.5-3.5 MB/s) makes the first full backup of a real library many hours (100 GB is roughly 8 to 55 hours), so "foreground only" is the dominant UX constraint, not an edge case.

**Why it happens:**
v1 deliberately omits background execution; the limitation is not communicated.

**How to avoid:**
- Set `UIApplication.shared.isIdleTimerDisabled = true` for the duration of a run (main thread, re-assert when the scene becomes active), and tell the user: keep the app open, plug the phone in. Screen on for hours means dimming the brightness; mention it.
- Observe `scenePhase`: on `.background`, stop starting new work, persist state, use `beginBackgroundTask` only to finish the current request cleanly (about 30 s at best). Do not use silent-audio or location hacks.
- On return to foreground, reconcile every in-flight item with the server before continuing.
- Order work so partial runs always produce value: photos first, videos by ascending size, and make repeat runs cheap (skip via check). Persist the run position so 30-minute sessions converge.
- Keep the long-running coordinator in an app-level object, not in a View's `.task` modifier, which cancels when the view disappears.
- Measure real native throughput in the spike with a 300 MB file, and compare against a LAN laptop uploading to the same server (`curl.exe -T`) to separate server or Wi-Fi causes (Windows Defender scanning `.incoming`, adapter power saving, 2.4 GHz band, router isolation) from client causes. The slow Safari video transfer is not established to be a Safari-only problem; do not assume native fixes it. Also confirm the PC will not sleep during a multi-hour run.

**Warning signs:**
Runs that always end with "interrupted"; upload speed identical to the Safari numbers in PROJECT.md.

**Phase to address:** A (throughput measurement), D (idle timer, reconcile).

---

### Pitfall 20: The PC app shuts itself down while the phone is busy exporting

**What goes wrong:**
`stopWithDashboard` defaults to true. The server stops once no dashboard tab is open, no request is writing, and no device has made an authenticated request for 5 minutes (`autoStop.deviceQuietMs`). [H, `server/app.ts` lines 28-35, 406-418] A native client spends minutes without any API traffic while it downloads a big iCloud video, exports it, and hashes it. The server can exit mid-run and every later request fails.

**How to avoid:**
- Send a cheap authenticated `GET /api/v1/status` heartbeat every ~60 s for the whole run (also surfaces a revoked key or unreachable PC early).
- Document in the README that the dashboard tab should stay open during a first backup, and surface "PC stopped responding" as a pending state, not a mass failure.

**Warning signs:**
Server log "auto_stop ... no backup is running" during a run; connection refused errors on all items at once.

**Phase to address:** D (heartbeat), S if a server-side exemption is preferred.

---

### Pitfall 21: Known server bugs that the native client will actually trigger

**What goes wrong:** [H, from `CONCERNS.md` and the code]
1. **Stuck `finalizing`.** `place()` sets `finalizing` before `rename`. A non-EXDEV failure (antivirus or OneDrive lock, `EPERM`) leaves it there; retries return 409 `not_receiving`; only a server restart clears it. A native client uploads large videos, exactly the files most exposed to Defender scanning, so this is likely.
2. **`/assets/check` trusts the database.** It checks `verify_status = 'ok'` or `uploads.status` only, with no stat of the file. A file deleted from the PC is "known" and the app skips it forever, directly violating the core value.
3. **Extension allow-list.** `ALLOWED_EXTENSIONS` has no `aae`, `plist`, `heics`, `avci`, `jp2` etc.; any such resource returns 415 `unsupported_type`. `size` must be at least 1, so zero-byte resources return 400.
4. **Unreserved space and quota.** Checked at create, after the phone has already downloaded, exported and hashed. A full PC disk (507 `insufficient_space`/`quota_exceeded`) is discovered once per item.
5. **Full re-hash on duplicates**, serialized: re-running over previously stored multi-GB videos makes each duplicate answer slow and can block other placements.

**How to avoid:**
- Phase S before D relies on them, each with a test in the existing suite: make `place()` roll back to `receiving` on failure; make `/assets/check` stat the file and compare size (as `/files/:sha256` already does); decide the sidecar policy (add `aae`/`heics`/`avci` or send sidecars under a safe renamed extension) and make the client treat 415 as a terminal, reported "server rejects type" state, not retryable; add `freeBytes` (additive) to `ClientStatus`.
- Client circuit breakers: stop the whole run on the first 507 (ask the user), on repeated `not_receiving` "finalizing" show "restart the PC app", on 413 `file_too_large` mark that item terminal.
- Until patch S is deployed, display `/assets/check` hits as "recorded on PC", not "verified".

**Warning signs:**
Dashboard "in progress" count that never drops; items "known" that are missing from the folder after "Verify now".

**Phase to address:** S (before D), D (breakers), F (wording).

---

### Pitfall 22: Marking items backed up prematurely, and phone-vs-server count drift

**What goes wrong:**
The app shows "backed up" at upload-complete, at `/assets/check` hit, or after the last PATCH, and the server count differs. Also: the app counts assets while the server counts files (a Live Photo is two uploads, RAW+JPEG two); duplicates counted as new; `SessionComplete` never sent after a crash so `unavailableCount` is 0; failed rows from earlier sessions remain on the dashboard after a later success.

**How to avoid:**
- Only `finish` or create-with-hash responses with `status` of `verified` or `duplicate` set an item to backed up. A hash-duplicate counts as backed up (the content is on the PC), but never the `known` flag until patch S lands.
- One unit everywhere: resources (files). Asset-level status is derived: complete only if all expected resources are verified/duplicate.
- Final numbers shown to the user come from `GET /sessions/:id` (`verified + duplicates`), and the app asserts equality with its own tally and logs any difference.
- Create the session after scanning (`selectedCount` is required, and `libraryCount` only under full access); call `complete` with `unavailableCount` in a `finally` and also on next launch for any dangling session id.
- Do not claim items uploaded earlier through Safari are duplicates of the new originals: converted `.jpeg` copies have different hashes and carry no asset id, so both copies will exist. Say so in the UI/README.

**Warning signs:**
Phone says 1,234, dashboard says 1,229; "verified" while `npm run verify` reports missing files.

**Phase to address:** F, with the counting contract fixed in C.

---

## Moderate Pitfalls

### Pitfall 23: QR pairing blind-coded around the camera

**What goes wrong:** Missing `NSCameraUsageDescription` crashes at scan; `AVCaptureMetadataOutput` code is easy to get subtly wrong without a device debugger; the QR payload format is not confirmed.
**Prevention:** Provide a manual entry path (address and 8-character code) from the first pairing build; confirm the QR payload from the dashboard code before writing the parser; use `UIDevice.current.name` knowing it returns a generic "iPhone" on modern iOS, and let the user edit the device name.
**Phase:** B.

### Pitfall 24: Filename collisions and renaming sidecars

**What goes wrong:** `PHAssetResource.originalFilename` is not unique across the library (counter wraps after IMG_9999, restore to a new phone, other devices, edited renders all named alike). The server never overwrites (`IMG_1234 (2).HEIC`), so data is safe, but name-based reasoning in the app (for example "same name means already backed up") is wrong.
**Prevention:** Never use filename as identity in the client. Identity = assetId + sha256.
**Phase:** C/E.

### Pitfall 25: Server writes into a OneDrive-redirected folder

**What goes wrong:** The default destination can be the OneDrive-redirected Pictures folder (CONCERNS.md); a multi-hundred-GB native backup floods OneDrive sync and can lock files (raising the `finalizing` bug above).
**Prevention:** Before the first native run, confirm the destination is not under OneDrive; add the warning to the dashboard (existing recommendation), test with a 2 GB file.
**Phase:** A/S.

### Pitfall 26: Progress UI floods the main thread

**What goes wrong:** URLSession progress callbacks per few KB update `@Published` state and re-render a list, starving the UI and making the app look hung.
**Prevention:** Throttle UI updates (~4 per second), keep per-item state out of the observed list, show aggregate counters.
**Phase:** D.

### Pitfall 27: "Retry" re-runs the wrong thing

**What goes wrong:** Retrying a failed item re-exports and re-uploads without reconciling first; a file the server stored after the client timed out becomes `duplicate` and double-counts.
**Prevention:** Retry = `GET /uploads/:id` first when an id exists, else assetId/sha256 check, then upload.
**Phase:** F.

---

## Minor Pitfalls

### Pitfall 28: Time zone and metadata edits

**What goes wrong:** Date edits made in the Photos app do not change the file's EXIF, so the PC folder reflects the original capture time, not what the phone displays.
**Prevention:** Expected behaviour; document it. Send `creationDate` as `lastModified` anyway.

### Pitfall 29: Language-mode drift when the runner image updates

**What goes wrong:** A newer Xcode on the runner image turns a warning into an error.
**Prevention:** Pin runner and Xcode versions; bump deliberately with a build to spare.

### Pitfall 30: Artifact retention and storage

**What goes wrong:** Keeping every `.ipa` artifact eats the 500 MB shared storage quota.
**Prevention:** Short retention (3 days).

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Local SQLite/SwiftData inventory | Feels "proper" | Large blind-coded surface, second source of truth, lost on reinstall | Never in v1; add only for a measured need |
| `PHPersistentChangeToken` incremental scan | Faster re-scan | Silent misses on expiry/reinstall | Only as an optimisation over a full-scan fallback |
| Skipping the Linux logic gate (push and pray) | No setup | Burns macOS minutes on trivial errors | Never |
| Plain `localIdentifier` as `assetId` | One line | Live Photo and RAW halves skipped | Never |
| Hard-coded resource-type list with `default: break` | Less code | Silent data loss for new types | Never; log and report unknown types |
| `NSAllowsArbitraryLoads` "to be safe" | Avoids ATS debugging | Weakens ATS, masks real failures, odd interaction with local-networking | Never; `NSAllowsLocalNetworking` only |
| Trusting `/assets/check` as verified | Fast skip | Core-value violation | Only after patch S, and display as "recorded" before |
| Fixed address from QR, no re-entry | Simpler pairing | Stuck after DHCP change | Never; make it editable |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| `POST /uploads` | Omit `lastModified`, so resume never matches and `.part` files orphan | Always send `lastModified = creationDate` ms, persist `uploadId` |
| `POST /uploads` with `sha256` | Default 60 s timeout; server re-hashes the stored file first | 10 min request timeout, tolerate slow answers |
| `PATCH /uploads/:id` | Wrong Content-Type (`application/json`, `text/plain`) hits built-in parsers and the 1 MiB limit | `application/offset+octet-stream` plus `Upload-Offset`, body via `fromFile` |
| `GET /uploads/:id` | URLCache returns a stale offset | Disable the cache; trust only the server offset |
| `POST /uploads/:id/finish` | Treat -1001 as failure | Poll status, call finish again (idempotent), cap the wait |
| `POST /files` | Streamed body (no Content-Length) gives 411 | `fromFile` only |
| `POST /assets/check` | Treat `known` as verified | Treat as "recorded" until the server stats the file |
| `GET /status` | Used only at pairing | Use as heartbeat and for `chunkSize`/`maxFileBytes` |
| `/sessions` | Create before scanning; never complete | Scan first, complete in `finally` and on next launch |
| PhotoKit `writeData` | Destination already exists | Unique path per attempt, clean temp at launch |
| PhotoKit iCloud requests | No timeout | Watchdog with `cancelDataRequest` |
| AltStore | Change bundle ID or add extensions | Single stable bundle ID, install over the top |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| `assetResources(for:)` for every asset up front | Long "scanning" pause, memory growth | Batch of a few hundred in `autoreleasepool`; measure in spike | ~10k+ assets |
| One-shot hashing (`Data(contentsOf:)`) | Jetsam kill on big video | Incremental CryptoKit SHA256 over file chunks | Files over ~500 MB |
| SwiftUI list of all assets | Scrolling lag, hang | Show counters and the active/failed items only | ~5k rows |
| Re-exporting for each retry | Hours of wasted iCloud downloads | Keep the temp file until verified, key it by resource | Large cloud videos |
| Per-chunk requests with fresh connections | Throughput below plain upload | Single session, keep-alive, measure chunk vs single PATCH | Multi-GB files |
| Duplicate video re-hash on the PC | `POST /uploads` takes tens of seconds | Server patch (trust last verification), client timeout margin | Repeated runs over stored multi-GB videos |
| Progress callbacks into SwiftUI | UI stalls | Throttle to ~4 Hz | Any large upload |
| Initial backup at 0.5-3.5 MB/s | Run never completes in one sitting | Resumable runs, ordering, measure early | 50+ GB libraries |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Bearer token or pairing code in exported logs | Token pasted into a chat or issue; anyone on the LAN can upload | Redact in the log layer; show the key never |
| Device key in `UserDefaults` or a file | Readable from an unencrypted backup | Keychain, `AfterFirstUnlockThisDeviceOnly` |
| Pairing over HTTP on an untrusted Wi-Fi | Key sniffed (known and disclosed; pinning deferred) | Pair only on the home network; keep the disclosure; revoke from dashboard |
| Logs shipped to the server unauthenticated | Anyone on the LAN writes into the dashboard log | Use the device bearer auth; cap size |
| Temp exports left in the app container | Photos persist after a crash, and could be included in the phone's own backups | `isExcludedFromBackup`, wipe at launch |
| Any code path that modifies the library | Violates one-way safety | Request `.readWrite` but never call `performChanges`; no delete or edit APIs anywhere (grep gate in CI) |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| "Backup complete" when items were skipped or unavailable | False confidence, the worst failure for this product | Three explicit numbers: backed up, unavailable (with reason), failed; no "complete" unless all are zero |
| `.limited` access treated as success | Partial library backed up unnoticed | Blocking banner; run disabled |
| Generic error text | Cannot self-diagnose | Mapped messages (local network, PC off, space, server stuck) with the next action |
| No guidance to keep the screen on | Run silently stops at lock | Idle timer disabled, prominent "keep open, plugged in" |
| Counting assets in one place and files in another | Numbers never match the dashboard | Files everywhere, assets as secondary |
| Safari-era `.jpeg` copies appear as "extra" files | Users think duplicates are a bug | Explain in the README once |
| Hidden failure state across reinstall | Lost retry list | Rebuildable from scan plus server check |

## "Looks Done But Isn't" Checklist

- [ ] **Original bytes:** Often a re-encoded copy slips in; verify SHA-256 of an uploaded HEIC, ProRAW DNG, Live Photo pair and HEVC video equals the USB-imported original.
- [ ] **Unsigned .ipa on CI:** Often builds but cannot install; verify `Payload/` layout, required Info.plist keys (PlistBuddy gate), AltStore install on the real phone.
- [ ] **Permissions:** Often a missing usage-description crash; verify Photos, Local Network and Camera prompts each appear once and a denied state shows a recovery message.
- [ ] **Keychain:** Often lost on reinstall or never written; verify the key survives relaunch and an AltStore refresh.
- [ ] **Live Photos:** Often only the still uploads; verify both files verified with identical base name and the same `YYYY\MM` folder, including a colliding name and a month-boundary capture.
- [ ] **iCloud-only:** Often hangs; verify an Optimize-Storage asset downloads, and a deliberately blocked one (airplane mode mid-download) ends as `unavailable` without stalling the queue.
- [ ] **Limited access:** Often reported as done; verify a run is refused under limited access.
- [ ] **Resume:** Often restarts from zero or duplicates; kill the app at 50% of a 1 GB video, relaunch, confirm it resumes from the server offset and ends in exactly one `verified` file.
- [ ] **Large file:** Often a timeout on finish; upload a 4 GB video and confirm `finish` survives a 60+ s server hash.
- [ ] **Screen lock:** Verify idle timer prevents auto-lock, and a power-button lock mid-upload reconciles on return.
- [ ] **Truthfulness:** Delete a stored file on the PC, run again, confirm it is re-uploaded (needs patch S), and the app's verified count equals the server's session summary.
- [ ] **Server failure paths:** Force a rename failure on the PC and confirm the upload is retryable (needs patch S) or that the app shows "restart the PC app".
- [ ] **Library safety:** Grep the Swift sources for `performChanges`, `deleteAssets`, `PHAssetChangeRequest`; none allowed.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| macOS minutes exhausted | MEDIUM | Wait for the monthly reset; meanwhile use the Linux gate and review code by hand; or make the repo public (free runners) |
| App expired (7 days) | LOW | Refresh via AltServer on the home Wi-Fi; state persists |
| App deleted or identity changed | MEDIUM | Reinstall, re-pair (revoke the old device on the dashboard), scan again; server dedupe prevents re-sending content |
| Upload stuck in `finalizing` on the PC | LOW | Restart the PC app (`recover()` rolls it back), retry; permanent fix in patch S |
| Wrongly "known" asset (file deleted on PC) | LOW | Run `npm run verify` / "Verify now", then re-run the phone; permanent fix in patch S |
| Live Photo halves split on the PC | MEDIUM | Manually move the files; server pairing patch to prevent recurrence |
| Orphan `.part` files | LOW | Server startup recovery clears stale ones after 7 days; delete manually in `.incoming` |
| Phone storage full from temp exports | LOW | Relaunch (temp cleaned at launch), free space, rerun |
| Count drift | MEDIUM | Compare per-resource lists app vs `GET /sessions/:id`; log both sets; fix the unit mismatch |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 1 Blind-coding minute burn | A | Linux gate green; first-build billed minutes recorded; macOS builds per week tracked |
| 2 Project plumbing and Info.plist | A | CI PlistBuddy gate; installs through AltStore |
| 3 AltStore limits and identity | A | One bundle ID; reinstall keeps data; refresh routine documented |
| 4 Entitlements, Keychain, permissions sideloaded | A (spike), B | Single spike build proves Photos, Keychain across relaunch/refresh, Local Network |
| 5 No debugger | A | Log ring buffer and PC log shipping working; abnormal-exit report works |
| 6 Local network and ATS | A, B | HTTP request to PC succeeds on the user's iOS version; error mapping tested |
| 7 Server address changes | B | Address editable; unreachable state does not mark failures |
| 8 Rendered copies | A, D | SHA-256 equals USB-imported original for 4 asset kinds |
| 9 Limited access and fetch options | C | Run refused under limited; hidden/burst counts match Photos |
| 10 Resource types and edit policy | C (policy), E | Per-asset resource list vs uploaded list reconciled |
| 11 Live Photo pair split | S, E | Server test with colliding names and month boundary; both halves same folder and stem |
| 12 assetId and localIdentifier | C | Live Photo video uploads; re-edit gets re-uploaded |
| 13 iCloud-only originals | D, F | Optimize-Storage asset backed up; blocked asset ends `unavailable` with reason |
| 14 Memory and temp files | D | 2 GB+ video and 10k+ library without jetsam; temp dir empty after run |
| 15 URLSession mechanics | D | No 411/413; stale-offset loop absent; memory flat during upload |
| 16 Timeouts vs server hashing | D | 4 GB finish survives; `upload_busy` handled; no false failures |
| 17 Local state authority | C | App deleted, rerun, nothing re-sent that the PC already holds |
| 18 Change token | C | Decision logged: deferred; full scan is the correctness path |
| 19 Foreground suspension and run length | A, D | Throughput measured against a laptop baseline; lock mid-upload reconciles |
| 20 Server auto-stop | D | Run with dashboard closed survives a 10-minute iCloud download |
| 21 Known server bugs | S before D | Server tests: rename failure, `/assets/check` disk check, sidecar types, `freeBytes` |
| 22 Premature "backed up" and count drift | F | App verified count equals server session summary in every test run |
| 23 QR and camera | B | Manual entry works without the camera |
| 24 Filename collisions | C/E | No client logic keyed on filename |
| 25 OneDrive destination | A/S | Destination is outside OneDrive or warned |

## Sources

- GitHub Docs, "How use of GitHub Actions is measured": https://docs.github.com/en/billing/concepts/product-billing/github-actions (HIGH: 2,000 included minutes on Free, macOS 3/4-core at $0.062/min, 500 MB artifact/package storage; the 10x figure from this and a secondary summary)
- AltStore FAQ, App IDs and error codes: https://faq.altstore.io/altstore-world/app-ids and https://faq.altstore.io/altstore-world/error-codes (HIGH/MEDIUM: 10 App IDs per 7 days, error 1009; 3 active apps, error 2009)
- Apple Developer Forums, "Local network prohibited" 2025 edition: https://developer.apple.com/forums/thread/788044 (HIGH: ATS vs Local Network Privacy are separate, TN3179, Radar 131764908 fixed in iOS 18.6, reboot workaround, DTS recommends `NSAllowsLocalNetworking`)
- Apple Developer Forums, ATS and local IP addresses: https://developer.apple.com/forums/thread/66417 (MEDIUM: ATS does not protect IP address, unqualified or .local connections)
- Apple Developer Forums on PHAssetResource: https://developer.apple.com/forums/thread/66477 (stalls and "Unable to locate resource"), https://developer.apple.com/forums/thread/833066 (no local-availability API; probe with network disabled), https://developer.apple.com/forums/thread/813354 (callbacks never fire) (MEDIUM)
- Apple documentation `PHAssetResourceRequestOptions`: https://developer.apple.com/documentation/photos/phassetresourcerequestoptions (HIGH: `isNetworkAccessAllowed`, progress handler)
- Repository, read directly this session (HIGH): `.planning/PROJECT.md`, `.planning/codebase/CONCERNS.md`, `docs/ROADMAP_IOS_COMPANION.md`, `shared/schemas.ts`, `server/engine.ts` (createUpload, appendChunk, place, finishUpload, recover), `server/app.ts` (routes, auto-stop, content-type parser), `server/security.ts` (extension allow-list, sanitize), `server/metadata.ts` (EXIF vs mvhd date handling), `server/config.ts` (defaults)
- Experience-based [L] items to be proved in the feasibility spike: free-account entitlement list, `embedded.mobileprovision` expiry read, `PHAssetResource` `fileSize` KVC, Hidden-album exposure on iOS 18, the exact PhotosError code for network-required, change-token expiry specifics, whether Swift for Windows is practical locally

---
*Pitfalls research for: native iPhone photo backup client built without a Mac*
*Researched: 2026-10-11*
