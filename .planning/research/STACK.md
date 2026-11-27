# Technology Stack

**Project:** Mewt Photos iOS companion app (native iPhone client for the existing Windows/Node server)
**Researched:** 2026-10-11
**Scope:** Only the iOS app and its build/install pipeline. The Windows server is out of scope.
**Overall confidence:** MEDIUM-HIGH. CI, pricing and AltStore facts were checked against official pages today. Apple API behaviour on a real device (ATS with an IP literal, iCloud downloads) is only verifiable by a spike.

Confidence tags: HIGH = official doc or runner-image README read today. MEDIUM = multiple secondary sources, or stable API knowledge not re-read today. LOW = single source or inference. Apple's developer docs are JavaScript-rendered and could not be scraped, so PhotoKit API details are MEDIUM, from stable framework knowledge plus Apple forum threads.

## Headline decisions

1. **Language/UI:** Swift, SwiftUI, deployment target iOS 18.0, built with the runner's default Xcode 26.x (not Xcode 16).
2. **Project definition:** XcodeGen (`project.yml`). The `.xcodeproj` is generated on the runner and never committed. A Swift Package alone cannot produce an iOS app bundle.
3. **Build:** `xcodebuild build` with signing disabled, then `Payload/` + `zip` into an unsigned `.ipa`. Archive-then-export is unnecessary.
4. **Runner:** `macos-26` (pinned label, not `macos-latest`). Trigger builds manually or on tag, never on every push.
5. **Cost reality:** a private repo on GitHub Free gets 2,000 included minutes, and macOS jobs bill at 10x, so about 200 macOS minutes per month. That is roughly 35-60 builds. A public repo for the iOS source gets unlimited standard-runner minutes (see "Decision for the user").
6. **Persistence:** no database in v1. Small Codable JSON files, because the server is the source of truth. If an inventory is needed later use GRDB, never SwiftData.
7. **Logging:** `os.Logger` plus an app-owned rotating log file in `Documents/`, exposed in the Files app and via `ShareLink`. Optionally also push log lines to the PC over the existing LAN connection.
8. **Dependencies:** zero third-party Swift packages in v1.

## Recommended Stack

### Core Framework

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| Swift | Whatever Xcode 26.6 ships; language mode **5** (`SWIFT_VERSION: "5.0"`) | App language | Language mode 5 gives Swift 6 compiler features without strict-concurrency errors. Every compile error costs a 10x CI minute and there is no local compiler, so do not opt into Swift 6 mode. Revisit once the app works. | MEDIUM (reasoned from constraints) |
| SwiftUI + Observation (`@Observable`) | iOS 18 SDK | All UI and state | Native, no dependency. `@Observable` (iOS 17+) replaces Combine/`ObservableObject` boilerplate. | HIGH |
| Xcode | **26.6 (default on `macos-26`)**; 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1 also installed | Compiler/SDK | A binary built with the iOS 26 SDK and a deployment target of 18.0 runs on iOS 18 and later. The `macos-15` image also carries Xcode 26.0.1-26.3, but its default is 16.4, so you would have to select a version anyway. | HIGH (runner-images README) |
| iOS deployment target | 18.0 | Minimum OS | User's phone is iOS 18+. Gives `PHPersistentChangeToken` (16+), `@Observable` (17+), `DataScannerViewController` (16+). | HIGH |
| PhotoKit | iOS SDK | Library enumeration and original bytes | `PHAsset.fetchAssets`, `PHAssetResource.assetResources(for:)`, `PHAssetResourceManager.default().writeData(for:toFile:options:)` writes the stored resource bytes (not a rendered image). Use `.photo`, `.video`, `.pairedVideo` for v1; `.fullSizePhoto`/`.fullSizeVideo`/`.alternatePhoto`/`.adjustmentData` later. Set `PHAssetResourceRequestOptions.isNetworkAccessAllowed = true` and a `progressHandler` for iCloud-only items. | MEDIUM (stable API, docs not re-read) |
| CryptoKit | iOS SDK | SHA-256 | `SHA256()` incremental hasher: `update(data:)` over 1 MiB reads of the exported temp file, then `finalize()`. Hardware-accelerated, orders of magnitude faster than the ~4 MB/s JS hash in Safari. | HIGH |
| URLSession | iOS SDK | HTTP to the server | Foreground `.default` configuration, async `upload(for:from:)` of 8 MiB chunks (matches server `CHUNK_SIZE = 8 MiB`, `PATCH /uploads/:id` with `Upload-Offset`). One code path for all sizes; resume via `GET /uploads/:id`. `allowsCellularAccess = false` and `allowsExpensiveNetworkAccess = false` give Wi-Fi-only. | HIGH |
| Security framework (Keychain) | iOS SDK | Device key storage | ~40-line `SecItemAdd/CopyMatching/Delete` wrapper, `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no explicit access group. | HIGH |
| VisionKit `DataScannerViewController` | iOS SDK | Scan the dashboard QR | Less code than hand-rolled AVFoundation. The QR payload is `http://<LAN-IP>:8787/#pair=<code>` (verified in `server/app.ts` line 364). Needs `NSCameraUsageDescription`. Always offer a manual paste-URL fallback (scanner is unavailable on very old hardware). | MEDIUM |
| Network framework `NWPathMonitor` | iOS SDK | Wi-Fi/reachability gate | Optional in v1; `URLSession` flags already enforce Wi-Fi-only. | HIGH |

### Build and project definition (no Mac)

| Tool | Version | Purpose | Why | Confidence |
|------|---------|---------|-----|------------|
| **XcodeGen** | **2.46.0** (released 2026-07-16) | Generate `MewtPhotos.xcodeproj` from `project.yml` | The only approach that is both Windows-editable and boring: ~40 lines of YAML, `brew install xcodegen` on the runner (not preinstalled), then `xcodegen generate`. Keeps pbxproj merge noise and hand-editing errors out of the repo. Supports Xcode 16+ project formats and synchronized folders. | HIGH (release), MEDIUM (Xcode 26 compatibility not explicitly stated; no known issue) |
| GitHub Actions runner | **`macos-26`** (arm64, M1 3-4 core standard runner; `macos-latest` currently points to it) | Compile | Pin the label so an image bump does not change Xcode under you. Print `xcodebuild -version` and `swift --version` at the top of every log. | HIGH |
| `actions/checkout` | **v7** (v7.0.1, 2026-07-20) | Checkout | Current major. | HIGH |
| `actions/upload-artifact` | **v7** (v7.0.2, 2026-10-07) | Hand the `.ipa` back | Current major. Set `retention-days: 7` and `compression-level: 0` (an `.ipa` is already a zip). | HIGH |
| `gh release create` (preinstalled `gh`) | n/a | Optional: attach `.ipa` to a prerelease | Release assets are a plain `.ipa` download (no zip wrapper like artifacts have) and do not count against the 500 MB Actions artifact storage. Needs `permissions: contents: write`. | MEDIUM |
| Swift syntax check on Linux | `swift` official Docker image, `swiftc -parse` | Cheap first-line typo filter | A Linux job costs 1x minutes, not 10x. `swiftc -parse *.swift` catches syntax errors (not type errors) without needing SwiftUI/PhotoKit. Run on every push; run the macOS build only on demand. | MEDIUM (technique is standard; not run here) |

### Unsigned `.ipa` build recipe (the exact flags)

Use `xcodebuild build` rather than `archive`: the end product is just `Release-iphoneos/MewtPhotos.app`.

```bash
xcodegen generate
xcodebuild build \
  -project MewtPhotos.xcodeproj \
  -scheme MewtPhotos \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER}"

mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/MewtPhotos.app Payload/
zip -qry MewtPhotos.ipa Payload      # Payload/ must be the top-level folder in the zip
```

Notes:
- `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO` and `CODE_SIGN_IDENTITY=""` are the flags documented in Apple forum threads and current guides for unsigned archives. (MEDIUM: forum and guide sources, not executed here.) The first CI build should confirm the output with `unzip -l MewtPhotos.ipa | head`.
- Do not pass an `-exportOptionsPlist`; Apple forum reports say export methods re-sign.
- The linker still adds an ad-hoc signature to the arm64 binary. That is harmless: AltServer replaces it.
- If the `.app` path differs, run `ls build/Build/Products/*/` in the workflow; do not guess.
- Bump `CURRENT_PROJECT_VERSION` per build (`GITHUB_RUN_NUMBER`). It also nudges iOS to refresh Files-app metadata (see Logging).
- Minimal workflow skeleton:

```yaml
name: ios
on:
  workflow_dispatch:
  push: { tags: ['ios-*'] }          # no build on plain pushes; each macOS minute costs 10
permissions: { contents: write }     # only needed for gh release
concurrency: { group: ios, cancel-in-progress: true }
jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v7
      - run: xcodebuild -version && swift --version
      - run: brew install xcodegen
      - run: xcodegen generate
      - run: |   # xcodebuild build ... + Payload zip, as above
      - uses: actions/upload-artifact@v7
        with: { name: MewtPhotos-ipa, path: MewtPhotos.ipa, retention-days: 7, compression-level: 0 }
```

### `project.yml` essentials

```yaml
name: MewtPhotos
options: { deploymentTarget: { iOS: "18.0" }, createIntermediateGroups: true }
settings:
  base:
    SWIFT_VERSION: "5.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    ENABLE_USER_SCRIPT_SANDBOXING: YES
targets:
  MewtPhotos:
    type: application
    platform: iOS
    sources: [MewtPhotos]
    settings: { base: { PRODUCT_BUNDLE_IDENTIFIER: com.<you>.mewtphotos, ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon } }
    info:
      path: MewtPhotos/Info.plist
      properties:
        UILaunchScreen: {}
        NSPhotoLibraryUsageDescription: "MewtPhotos reads your library to back it up to your PC. It never changes or deletes photos."
        NSLocalNetworkUsageDescription: "MewtPhotos sends your photos to your PC on this Wi-Fi network."
        NSCameraUsageDescription: "Used only to scan the pairing QR code shown on your PC."
        NSAppTransportSecurity: { NSAllowsLocalNetworking: true }   # see ATS pitfall in PITFALLS/spike
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
```

No `.entitlements` file at all. The app needs no entitlements, which removes the whole class of "free account cannot provision this capability" failures. Provide a 1024 px `AppIcon` asset (generate the PNG with a Node script on Windows); a missing app icon only warns but looks broken.

### Install / signing (AltStore with a free Apple ID)

| Fact | Value | Source / confidence |
|------|-------|--------------------|
| Certificate/profile lifetime | 7 days; app cannot launch after expiry; AltServer must be running on the PC on the same Wi-Fi to auto-refresh, or tap Refresh All in My Apps | AltStore FAQ, HIGH |
| Active sideloaded apps | **3** at once; a 4th requires deactivating one (error 2009 "Cannot activate more than 3 apps with a non-developer Apple ID") | AltStore FAQ, HIGH |
| App IDs | **10 per 7 days** (errors 1009 / 3013); each App ID expires after one week; app extensions consume extra App IDs | AltStore FAQ, HIGH |
| Apple personal team | 10 App IDs, 3 devices, 3 apps per device, profile expires 7 days after issue | developer.apple.com compare-memberships, HIGH |
| Latest AltStore Classic | **2.3** (2026-09-14), minimum iOS **17.4**, iOS 26 UI, adds Remote AltServer. 2.2 added "Increased Memory Limit" entitlement support. | AltStore release notes, HIGH |
| Latest AltServer for Windows | **1.7.4** (2026-03-24), fixes apps crashing on launch on iOS 26.4 and updates the codesigning library | AltStore release notes, HIGH |
| Windows prerequisite | iTunes and iCloud installed **from Apple directly** (not the Microsoft Store builds), or the documented folder workaround. User already runs this setup; do not change it. | AltStore troubleshooting guide, HIGH |
| Installing an `.ipa` | In AltStore: My Apps, then **+**, pick the `.ipa` from Files. Windows-side drag/"Sideload .ipa" menu entries were not confirmed in official docs. | MEDIUM (phone-side flow), LOW (Windows-side) |
| Bundle ID | AltStore re-signs and rewrites the bundle ID (appends the team ID). Never hardcode `com.you.mewtphotos` anywhere at runtime; use `Bundle.main.bundleIdentifier`. | MEDIUM (known AltStore behaviour) |
| Capabilities needing a paid team | Not enumerated by Apple's public pages. Commonly cited as unavailable on personal teams: Push Notifications, iCloud/CloudKit, Associated Domains, In-App Purchase, Apple Pay, Sign in with Apple, Game Center, Network Extensions, multicast networking entitlement. | LOW-MEDIUM. Irrelevant to this app as long as it declares no entitlements. |
| What needs NO entitlement (all Info.plist only) | Photos read access, local network access, camera, background `URLSession`, `BGTaskScheduler`, file sharing, ATS exceptions, `NWBrowser` Bonjour browsing (needs `NSBonjourServices` key only) | MEDIUM |
| Keychain | Keychain items are scoped to the signing team. Refreshing with the same Apple ID keeps them. Switching Apple ID loses access to the old items, so pairing must be re-doable from scratch. | MEDIUM (inference from Apple keychain model) |

### Local persistence (v1: files, not a database)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `Codable` JSON in `Application Support/` (atomic `Data.write(options: .atomic)`) | Foundation | Server URL, device name, last run summary, failed/unavailable list, in-flight upload ids | The server is the source of truth: `POST /assets/check` (5000 ids per call) and `sha256` on create already tell the app what the PC has. Local state is a cache plus a "what went wrong" list, small enough for a JSON file. Loss of the file costs a re-check, never data. Keeps the "never show backed up unless server said verified/duplicate" rule trivially true: nothing local can say "verified". |
| Keychain | Security | Device key only | Never write the key to a file or `UserDefaults`. |
| Temp exports | `FileManager.default.temporaryDirectory` | One exported resource at a time (bounded batch), deleted after the server answers `verified`/`duplicate` | Avoids filling the phone. Delete leftovers at launch. |

**Escalation rule:** if a phase genuinely needs an inventory (change tokens, 30k+ row reconciliation), add **GRDB.swift 7.11.1** (2026-06-18) as the first and only SPM dependency, or use the system `SQLite3` module directly. Do **not** use SwiftData.

### Logging (no debugger)

| Piece | Choice | Why |
|-------|--------|-----|
| Structured logging | `os.Logger`, subsystem from `Bundle.main.bundleIdentifier` | Free, but unreadable without a Mac, so it is only the secondary sink. |
| **Primary sink** | Own `FileLogger` actor appending lines to `Documents/mewtphotos.log`, rotate at ~2 MB (keep 2 files), every line `ISO-8601 level category message`, flush on every line | Survives crashes and is exportable. Log every state transition, HTTP status, offset, PHAsset error code, and iCloud progress. Never log the device key. |
| Export path 1 | `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` in Info.plist: log shows under Files, On My iPhone, MewtPhotos. | Zero code. Apple forum report: on iOS 18 the folder only appears if `Documents` contains at least one file, so write a log line at first launch. Unverified for AltStore-signed builds, so confirm in the first spike. |
| Export path 2 | SwiftUI `ShareLink(item: logFileURL)` in a Settings/Diagnostics screen | AirDrop is unavailable from Windows, but "Save to Files", mail, or sharing to iCloud Drive works. |
| Export path 3 (recommended, needs a tiny server change) | Best-effort `POST` of log batches to the server (which already has a `logs` table and dashboard events) | Gives live logs on the PC with no export step. Current server has no log-ingest endpoint (routes checked in `server/app.ts`), so this is a small additive server change. |
| Crash reports | Settings, Privacy and Analytics, Analytics Data on the phone has `.ips` files; `MetricKit` is possible but delayed | Last resort. LOW value without symbolication. |
| Optional live syslog from Windows | `pymobiledevice3 syslog live` over USB (uses the existing Apple USB driver) | LOW confidence, unverified here; mention only as a bonus. |

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Project generation | XcodeGen 2.46.0 | Tuist (latest stable not obvious; CLI `4.213.0-canary` and Atlas 0.47.1 on releases page) | Needs Swift manifests, its own install and cloud-ish features. Overkill for one target; more moving parts to break an expensive build. |
| Project generation | XcodeGen | Hand-written `project.pbxproj` | Possible, but any typo is found only on CI at 10x cost; fragile to merge and tooling changes. |
| Project generation | XcodeGen | Pure Swift Package | SwiftPM cannot emit a signable iOS app bundle (the app-product type exists only in Swift Playgrounds). |
| Build command | `xcodebuild build` + manual `Payload` zip | `xcodebuild archive` then `-exportArchive` | Export re-signs; adds failure modes for no gain. Plain archive without export also works (`Products/Applications/*.app`), so it is an acceptable fallback. |
| Build wrapper | Raw `xcodebuild` | fastlane / xcpretty / `setup-xcode` action | Ruby gems and extra actions add install minutes and failure points. The runner already has the Xcode versions. |
| CI host | GitHub Actions `macos-26` | `macos-15` | Default Xcode there is 16.4; you would need `xcode-select` to reach Xcode 26. Offers no benefit for an iOS 18 target. |
| CI host | GitHub Actions | Codemagic free tier | 500 free macOS M2 minutes per month for personal accounts (not teams), 1 concurrent build, so 2.5x the private-repo GitHub allowance. A genuine fallback if minutes run out (MEDIUM: from Codemagic docs via search; needs account/card checks). |
| CI host | GitHub Actions | Xcode Cloud | Requires the paid Developer Program. |
| CI host | `macos-26` standard | `-large` / `-xlarge` labels (`macos-26-xlarge`, `macos-latest-large`) | Larger runners are not covered by included minutes and are paid. A wrong label silently burns money. |
| Persistence | JSON files | SwiftData | `@Model` macros produce opaque errors when you cannot compile locally; reported `ModelActor` background-insert and `@Query` refresh issues on iOS 18, and a forum report of ~5,000 upserts taking ~15 min. Wrong tool for tens of thousands of status rows. |
| Persistence | JSON files | GRDB 7.11.1 now | Good library, but it adds SPM resolution and compile time to every metered build, and v1 does not need a queryable inventory. First thing to add if that changes. |
| Keychain | Own 40-line wrapper | KeychainAccess / SwiftKeychainWrapper | A dependency for one `kSecClassGenericPassword` item. |
| Logging | `os.Logger` + file | CocoaLumberjack / swift-log | Dependency for something 60 lines do. `swift-log` only adds value if multiple backends are needed. |
| HTTP | URLSession | Alamofire | No benefit; adds a package. |
| Upload mode (v1) | Foreground `.default` session, chunked `PATCH` | Background `URLSession` or iOS 26 `PHAssetResourceUploadJobChangeRequest` / `PHBackgroundResourceUploadExtension` | Background is explicitly out of scope. The iOS 26 extension API is deprecated from iOS 27 in favour of a new protocol, needs an extension target (extra App ID), does whole-resource jobs only (no byte ranges), is not testable in the Simulator and has a reported iOS 26.2 regression. Revisit only in the background milestone, with a spike. |
| QR scan | `DataScannerViewController` | AVFoundation `AVCaptureMetadataOutput` | More boilerplate. Use AVFoundation only if the scanner is unavailable on the user's phone. |

## What NOT to use

- **SwiftData, Core Data** (see above).
- **Swift 6 language mode / strict concurrency = complete** in v1. It converts warnings into build-failing errors.
- **`PHImageManager.requestImage` / `requestData(for: PHAsset)`**: return rendered or converted data, which defeats the whole project.
- **`PHAssetResourceManager.requestData` accumulated into memory** for videos (OOM risk on multi-GB files). Use `writeData(for:toFile:)` to a temp file, then stream-hash and stream-upload from disk.
- **`NSAllowsArbitraryLoads` as the first choice.** Apple forum notes say IP-based connections behaved differently from iOS 17 on, so test the minimal `NSAllowsLocalNetworking` first; widen only if the spike fails (see Pitfalls below).
- **macOS image labels `macos-latest`** for anything you need reproducible, and any `-large`/`-xlarge` label.
- **Committing a generated `.xcodeproj`.** It will drift from `project.yml`.
- **Running macOS CI on every push.**

## Decision for the user (flag for the roadmap)

**Private repo = about 200 macOS minutes a month; public repo = unlimited.** GitHub Free gives 2,000 included minutes per month for private repositories, and macOS jobs consume them at 10x. Standard GitHub-hosted runners are free for public repositories. The iOS source holds no secrets (the device key lives in the Keychain at runtime). Options:
1. Keep the whole repo private and accept about 35-60 deliberate builds a month (assuming 3-6 billed minutes per build; **that duration is an unverified estimate**, so measure it in the first CI run).
2. Put only the iOS app in a **separate public repo** and build there for unlimited builds. The server stays private.
3. Fallback if the allowance runs out: Codemagic's 500 free minutes.
This was decided as "private" in PROJECT.md, so keep private unless the allowance proves too small. The roadmap should add a "measure real build minutes" task to phase 1.

The free allowance only works if `spending limit = $0` stays set on the account (the default); otherwise overage is billed ($0.062 per macOS minute).

## Installation

```bash
# Windows dev machine: nothing to install to edit Swift. Optional syntax check:
#   winget install --id Swift.Toolchain -e --source winget    (needs VS 2022 Community prerequisites; Swift 6.4.0 listed on swift.org)
# or use the Linux CI syntax-check job instead of installing anything locally.

# CI (macos-26 runner)
brew install xcodegen        # 2.46.0 at time of research
xcodegen generate
# then the xcodebuild recipe above
```

No SPM, CocoaPods or Carthage dependencies in v1.

## Sources

- GitHub runner images README (labels and status; macOS 26 arm64 `macos-latest`/`macos-26`, macOS 15 arm64, macOS 14 deprecated; Xcode 27 preview): https://github.com/actions/runner-images - HIGH
- `macos-26` arm64 image Xcode list (default 26.6; 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1; iOS SDKs 26.0-26.5): https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-26-arm64-Readme.md - HIGH
- `macos-15` arm64 image (default Xcode 16.4; also 26.0.1-26.3; iOS 18.0-18.5 SDKs): https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-15-arm64-Readme.md - HIGH
- GitHub Actions billing (GitHub Free 2,000 min/month private; standard runners free for public repos; macOS 3/4-core M1/Intel $0.062/min vs Linux $0.006; artifact storage 500 MB on Free; larger runners not covered by included minutes): https://docs.github.com/en/billing/concepts/product-billing/github-actions and https://docs.github.com/en/billing/reference/actions-minute-multipliers - HIGH. The 10x macOS multiplier is stated in GitHub's docs text per search result; the rate ratio ($0.062/$0.006 ≈ 10.3) is consistent - MEDIUM-HIGH.
- AltStore FAQ: App IDs https://faq.altstore.io/altstore-classic/app-ids ; Activating Apps https://faq.altstore.io/altstore-classic/activating-apps.md ; Error codes https://faq.altstore.io/altstore-world/error-codes ; Troubleshooting https://faq.altstore.io/altstore-classic/troubleshooting-guide ; Release notes https://faq.altstore.io/release-notes/altstore.md and https://faq.altstore.io/release-notes/altserver.md - HIGH
- Apple membership comparison (personal team limits): https://developer.apple.com/support/compare-memberships/ - HIGH
- Apple forums on ATS and IP addresses (iOS 17 change, TN3179 local network privacy, iOS 18.4 "Local network prohibited" bug fixed in 18.6): https://developer.apple.com/forums/thread/747421 , https://developer.apple.com/forums/thread/788044 - MEDIUM
- Unsigned archive flags: https://developer.apple.com/forums/thread/109122 and community guides - MEDIUM
- XcodeGen 2.46.0 (2026-07-16): https://github.com/yonaskolb/XcodeGen/releases - HIGH
- GRDB.swift 7.11.1 (2026-06-18): https://github.com/groue/GRDB.swift - HIGH (version)
- Swift for Windows (6.4.0, winget): https://www.swift.org/install/windows/ - HIGH
- iOS 26 PhotoKit background upload extension notes: https://developer.apple.com/forums/thread/819034 , https://developer.apple.com/forums/thread/815316 - LOW-MEDIUM
- Codemagic free tier (500 min macOS M2, personal accounts): https://docs.codemagic.io/billing/pricing/ - MEDIUM
- Files-app exposure caveat on iOS 18: https://developer.apple.com/forums/thread/765329 - MEDIUM
- Repository facts: `C:/codes/claude/photosync/server/app.ts` (route list, QR URL format), `shared/schemas.ts` (`CHUNK_SIZE`).
