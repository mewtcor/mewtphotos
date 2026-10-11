# Phase 1: Build, Install and Pair - Research

**Researched:** 2026-10-11
**Domain:** No-Mac iOS delivery pipeline (GitHub Actions Linux + macOS, unsigned `.ipa`, AltStore free-account sideload) plus a minimal SwiftUI walking skeleton that pairs with the existing Fastify server over plain HTTP
**Confidence:** MEDIUM-HIGH. CI facts, Apple plist/ATS/Local Network behaviour, AltStore signing behaviour and the server contract were read from primary sources or source code this session. Everything that only an Apple toolchain or the real iPhone can prove (Xcode 26 + XcodeGen + local package build, unsigned `.ipa` acceptance, Keychain across an AltStore refresh) is explicitly flagged as a device/CI check, not a fact.

<user_constraints>
## User Constraints (from CONTEXT.md)

No CONTEXT.md exists for this phase: the user chose to plan without `/gsd-discuss-phase`. There are therefore no discuss-phase locked decisions. The binding inputs are the roadmap and requirements, reproduced here so the planner treats them as locked.

### Locked Decisions (ROADMAP.md "Planning Notes -> Research resolutions adopted", applicable to Phase 1)
- CI Mac runner is `macos-26` with an explicit Xcode 26.x selection printed in the log; never `macos-latest` or large runners; re-check the label in Phase 1.
- ATS: `NSAllowsLocalNetworking` only; Phase 1 proves plain-HTTP reach to the PC's IP, and widens only if that fails, recording why.
- Swift 6 mode for the pure Swift package (checked on Linux), Swift 5 for the app target (`SWIFT_VERSION` set per target).
- Local state is small atomic JSON files; no GRDB (Phases 4-6, but do not add a database in Phase 1 either).
- Temp exports to `temporaryDirectory` (not used in Phase 1).
- The repository stays private as decided; if the monthly Mac allowance runs out, making it public or using another CI host is the user's call.
- Plan on about 25 Mac builds a month until Phase 1 records real billed minutes.
- Delivery rules: logic in the pure Swift package tested on Linux on every push; app target only adapts Apple APIs; Mac builds manual and batched; the phase ends with a short device test on the real iPhone from an AltStore-installed build.
- Gate after Phase 1: if the unsigned build cannot be installed with AltStore, cannot reach the PC over plain HTTP, or loses its device key on relaunch or AltStore refresh (FEAS-01), stop and re-plan the install route.
- UI: the user chose to plan without a UI-SPEC; the UI is a plain SwiftUI walking-skeleton form. Mode is `mvp`.

### Claude's Discretion
Everything not listed above: repo layout inside `ios/`, workflow structure and triggers, how the plist gate is implemented, test framework choice for the Swift package, file formats for local state, wording of the in-app screen.

### Deferred Ideas (OUT OF SCOPE)
QR scanning (PAIR-01, Phase 4), plain-English reachability diagnosis (PAIR-04, Phase 4), editable/forgettable pairing (PAIR-05, Phase 4), anything PhotoKit (Phases 2+), Bonjour, HTTPS pinning, background sessions, GRDB, "days until AltStore expiry" display (CONV-06, v2), pushing logs to the PC dashboard (CONV-05, v2), any server change (Phase 1 needs none, see below).
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BLD-01 | Whole project in a private GitHub repo with lockfile committed | "First-time repository setup" section; `package-lock.json` is untracked today; `gh` token lacks `workflow` scope |
| BLD-02 | Every push runs server tests and iOS logic-package tests on Linux, incl. contract test vs real server | `ci.yml` design; Swift 6.4 preinstalled on `ubuntu-24.04`; contract test uses unmodified `server/main.ts` and the existing `/admin/pairing` endpoint |
| BLD-03 | Manual Mac build -> unsigned `.ipa`; fails early if a permission text is missing | `ios-build.yml` recipe; checked-in `Info.plist` + `check_info_plist.py` run first on Linux and again first on macOS; negative-control test |
| BLD-04 | Install via AltStore; re-install keeps the same app (one fixed bundle ID, no extensions, no entitlements) | AltSign/AltStore source read: bundle ID rewrite `id.TEAMID`, entitlements come wholesale from the profile, App ID reused on re-install |
| BLD-05 | Log export from iPhone (share sheet or Files), never contains the device key | `UIFileSharingEnabled` + `ShareLink`; `DeviceKey` redaction type + `RunLog` scrubber; contract test greps the log for the real token |
| BLD-06 | App shows installed version and build | `CFBundleShortVersionString`/`CFBundleVersion` from `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`; plus git SHA custom plist key |
| BLD-07 | Billed Mac minutes per build measured and recorded | Rates and rounding rule cited; `run timing` REST endpoint is closing down, so use billing UI/usage report plus job step summary |
| FEAS-01 | Plain-HTTP reach from AltStore build; device key survives relaunch and AltStore refresh | ATS doc (iOS 17+ blocks IPs by default; `NSAllowsLocalNetworking` re-enables), TN3179 Local Network behaviour, Keychain default access group doc, launch-evidence logging design |
| PAIR-02 | Pair by typing PC address and code | Verbatim server pairing contract; `ServerAddress` parser; contract test |
| PAIR-03 | Device key in Keychain, pairing remembered across launches | Keychain pattern (`AfterFirstUnlockThisDeviceOnly`, no access group); JSON `PairingStore` for non-secret fields |
</phase_requirements>

## Summary

Phase 1 needs **no server change**. The existing `/api/v1/health`, `/pair`, `/status` and the loopback-only `/admin/pairing` endpoint are enough, even for a headless contract test in CI: start the unmodified `server/main.ts` with `PHOTOSYNC_PORT` and `PHOTOSYNC_DATA_DIR` set on an `ubuntu-24.04` runner, then let the Swift contract test read the pairing code from `GET /api/v1/admin/pairing` over `127.0.0.1` exactly as the dashboard does. All other work is new files: a `ios/` tree (XcodeGen spec, checked-in `Info.plist`, thin SwiftUI app, a Swift 6 `PhotoSyncCore` package), two workflows (`ci.yml` on Linux for every code push, `ios-build.yml` on `macos-26` by hand), and a plist-check script. The Linux runner already carries Swift 6.4, Node 22, Python 3.12 and `gh`, so the cheap loop needs no installation steps.

Three findings change the project-level research. (1) Apple's current `NSAllowsLocalNetworking` page says that **since iOS 17 ATS no longer allows connections to IP addresses by default**, and that the local-networking exception is what re-enables "unqualified domains, `.local` domains, and IP addresses". The roadmap decision (`NSAllowsLocalNetworking` only) is therefore correct and grounded, but the SUMMARY's premise that ATS ignores IP literals is wrong for iOS 17+; the IP-CIDR `NSExceptionDomains` entry is the documented fallback before `NSAllowsArbitraryLoads`. (2) `URLSessionConfiguration.waitsForConnectivity` is marked `unavailable` on non-Darwin platforms and `allowsExpensiveNetworkAccess` / `allowsConstrainedNetworkAccess` do not exist in swift-corelibs-foundation at all, so any Core code that sets them fails the Linux build; session configuration must live in the app target. (3) The REST "workflow run timing" endpoint that would give billed minutes is documented as "in the process of closing down", so BLD-07 must read billed minutes from the billing usage report and use job step summaries only as a cross-check.

The residual risk is entirely on Apple hardware: whether XcodeGen + a local SPM package + Xcode 26.6 + `CODE_SIGNING_ALLOWED=NO` yields a good `.app`, whether AltStore accepts it, whether the Local Network grant and Keychain item survive an AltStore refresh (the re-sign changes the code signature, which TN3179 says is how local network privacy tracks identity). The plan should therefore spend Mac builds deliberately: expect 3-5 in this phase (first install and refresh test; install-over test; one or two fix builds), each roughly 5-8 wall-clock minutes at 10x.

**Primary recommendation:** Build the whole Linux-checkable surface first and get it green (repo, `ci.yml`, Core package, contract test, plist gate with negative control, `swiftc -parse` of the app sources), only then spend the first Mac build; make the first Mac build carry the complete walking skeleton plus launch-evidence logging so one install answers FEAS-01 as far as possible.

## Project Constraints (from CLAUDE.md)

Extracted from `C:\Users\mewt cor\.claude\CLAUDE.md` and `C:\codes\claude\photosync\.claude\CLAUDE.md`. Treated with the same authority as locked decisions.

- Git commits: never add a `Co-Authored-By:` trailer or any Claude/Anthropic attribution; never add "Generated with Claude Code" to PR descriptions.
- Cost: free; no paid developer membership, no Mac purchase or rental.
- Build: iOS builds only on GitHub Actions macOS runners from a private repo; builds few and deliberate.
- Install: unsigned `.ipa` via AltStore with a free Apple ID (7-day expiry, limited app count).
- Debugging: no on-device debugger; in-app logging and log export from day one.
- Compatibility: reuse `/api/v1` as it stands; any server change small, additive, covered by existing tests (Phase 1 needs none).
- Platform: iOS 18+, Windows 11 PC. Network: plain HTTP on LAN with the ATS local-networking exception.
- Safety: read-only photo library in effect; Truthfulness: never show backed up unless server returned `verified`/`duplicate`.
- Tech stack: Swift / SwiftUI / URLSession, as few third-party packages as possible (this research recommends zero Swift packages).
- GSD workflow: file changes go through a GSD command (`/gsd-execute-phase` for planned work).
- TypeScript conventions for any new TS/test code in this repo: named exports only, `.ts` import extensions, `import type`, module header comment stating purpose, no `console` in library code, tests as `tests/<name>.test.ts`, helpers without `.test` suffix, `erasableSyntaxOnly` (no enums).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Pairing handshake, token issue, code throttling | Windows server (`server/security.ts`, `server/app.ts`) | iPhone app (client) | Already built; app only calls `POST /pair` |
| Address parsing, request building, error mapping, redaction, log writing, pairing-state persistence | `PhotoSyncCore` package (Swift 6, Linux-tested) | App target (wires it up) | Delivery rule: all logic in Core so it is tested at 1x cost |
| Keychain storage of the device key | iPhone app target (`Security` framework adapter) | Core defines `DeviceKeyStoring` protocol + in-memory fake | `Security` is Apple-only; Core must compile on Linux |
| `URLSession` configuration (`waitsForConnectivity`, cellular off) | iPhone app target | Core `HTTPTransport` takes a ready `URLSession` | Those properties are unavailable on Linux (verified) |
| Permission texts, ATS exception, file-sharing keys | Checked-in `Info.plist` (build input) | CI plist gate (Linux + macOS) | Missing keys must stop the build before the 10x-cost compile |
| Unsigned `.app` -> `.ipa` | macOS runner (`ios-build.yml`) | AltStore re-signs on install | No signing material anywhere in CI |
| Re-signing, App ID, bundle ID rewrite, profile entitlements | AltStore / AltServer (user's existing setup) | - | App must declare no entitlements and not depend on its runtime bundle ID |
| Log retrieval | iPhone (Files via `UIFileSharingEnabled`, `ShareLink`) | Windows (Apple Devices file sharing, unverified) | Zero server change |
| Billed-minute measurement | GitHub billing usage report (human reads) | Job summary elapsed time | Run-timing REST endpoint is closing down |

## Standard Stack

### Core
| Library / Tool | Version | Purpose | Why Standard |
|----------------|---------|---------|--------------|
| Swift | Xcode 26.6's compiler (macOS job); 6.4 on `ubuntu-24.04` (Linux job) [CITED: raw.githubusercontent.com/actions/runner-images Ubuntu2404-Readme "Swift 6.4"] | App and Core | `Package.swift` with `// swift-tools-version: 6.0` builds on both; avoid language features newer than 6.0 so Xcode 26.6 and Swift 6.4 agree |
| SwiftUI + Observation (`@Observable`) | iOS 18 SDK | UI/state | Native; no dependency |
| URLSession | Darwin: iOS SDK; Linux: `FoundationNetworking` | HTTP | Async `data(for:)` exists in swift-corelibs-foundation (`@available(macOS 12.0, iOS 15.0 ...)` extension, no `#if` guard) [VERIFIED: swift-corelibs-foundation URLSession.swift, read this session] |
| Security (Keychain) | iOS SDK | Device key | `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` ("Items with this attribute do not migrate to a new device") [CITED: developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly] |
| Swift Testing (`import Testing`) | ships with Swift 6.x toolchains | Core unit and contract tests | Concise; falls back to XCTest if the first CI run objects [ASSUMED] |
| XcodeGen | 2.46.0 (released 2026-07-16, MIT, 8.8k stars) [VERIFIED: `gh api repos/yonaskolb/XcodeGen`] | Generate the `.xcodeproj` on the runner | Only sane way to define an iOS app project from Windows; not preinstalled on `macos-26` [CITED: macos-26-arm64-Readme] |
| `xcodebuild` | Xcode 26.6 (`/Applications/Xcode_26.6.app`, default on `macos-26`; 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1 also installed) [CITED: macos-26-arm64-Readme, image 20260907.0351.1] | Unsigned build | Documented flags below |
| GitHub Actions runners | `ubuntu-24.04` (Linux job), `macos-26` (arm64 standard; `macos-26-xlarge` is the paid larger runner) [CITED: github.com/actions/runner-images README] | CI | Pin explicitly; `ubuntu-latest` moves to 26.04 in November 2026 [CITED: runner-images issue 14748] |
| `actions/checkout` | v7 (7.0.1, 2026-07-20) | Checkout | [VERIFIED: `gh api repos/actions/checkout/releases/latest`] |
| `actions/setup-node` | v7 (7.1.0, 2026-10-08) | Node for server tests/contract server | [VERIFIED: gh api] ; Node 22.23.3 is also the Ubuntu image default, `node-version: 24` matches the dev machine (24.16.0) |
| `actions/upload-artifact` | v7 (7.0.2, 2026-10-07) | Hand the `.ipa` back | [VERIFIED: gh api] |
| Python 3 (`plistlib`) | 3.12.3 on ubuntu, 3.14.7 on macos-26, 3.14.5 on the dev PC (`python`, not `python3`) | Info.plist gate | Reads XML and binary plists, runs on all three machines [CITED: runner-images READMEs; VERIFIED: `python --version` locally] |
| Vitest | 5.0.3 (existing) | Server tests | Already in repo; 49 tests pass locally in 17 s [VERIFIED: ran `npm test`] |

### Supporting
| Library / Tool | Version | Purpose | When to Use |
|----------------|---------|---------|-------------|
| `xcbeautify` | 3.2.1 preinstalled on macos-26 [CITED: README] | Readable `xcodebuild` log | Pipe with `set -o pipefail`; always also keep the raw log as a failure artifact |
| `gh` CLI | 2.102.0 local, preinstalled on runners | Repo creation, dispatch, watch, log fetch, artifact download | Whole Windows-side feedback loop |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| XcodeGen release zip with pinned sha256 | `brew install xcodegen` | Brew on a brand-new macOS image may compile from source if no bottle exists (billed at 10x); the release zip is 4.3 MB and has a published digest. Use brew only as fallback |
| Generated Info.plist (`info:` block in `project.yml`) | **Checked-in XML `Info.plist`** referenced by `INFOPLIST_FILE` | Checked-in plist can be validated on Linux and on the dev PC with a 30-line script; recommended |
| `ubuntu-24.04` for server tests | `windows-latest` (2x minutes) | Server is Windows-only in practice and the tests were only ever run on Windows. If the first Linux run fails on Windows-specific tests, move only the vitest step to `windows-latest`; the Swift contract test needs Linux |
| Tests spawn the server from Swift (`Process`) | Workflow starts the server before `swift test` | Workflow approach has less Swift code that cannot be compiled locally |
| Swift Testing | XCTest | XCTest is the older, certain-to-work fallback on Linux |

**Installation (macOS job):**
```bash
curl -fsSL -o xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
echo "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806  xcodegen.zip" | shasum -a 256 -c -
unzip -q xcodegen.zip && ./xcodegen/bin/xcodegen --version
```
The digest is the release asset digest [VERIFIED: `gh api repos/yonaskolb/XcodeGen/releases/tags/2.46.0` -> `xcodegen.zip sha256:4d9e34b6...`]. The in-zip layout (`xcodegen/bin/xcodegen`) is [ASSUMED]; the first Mac build will show it. Fallback: `HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen`.

**Version verification:** Actions versions, XcodeGen release and asset digest read with `gh api` today. Runner image versions from the images' READMEs today (macOS 26: image `20260907.0351.1`, Ubuntu 24.04: image `20261004.327.1`).

## Package Legitimacy Audit

This phase installs **no** npm, PyPI, crates or SwiftPM packages (the Swift package is local and has no dependencies; the plist gate uses the Python standard library). The only third-party artifact is the XcodeGen binary.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| XcodeGen 2.46.0 (release zip) | GitHub Releases (not an npm/PyPI/crates package, so `gsd-tools package-legitimacy check` does not apply) | repo created 2017-07-19 | n/a (8,842 stars, MIT, not archived, last push 2026-09-13) | github.com/yonaskolb/XcodeGen | OK by manual review | Approved; pin version and sha256 in the workflow |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

No marketplace Actions are used; only first-party `actions/*`. Do not add `swift-actions/*`, `maxim-lobanov/setup-xcode` or similar third-party actions (explicit `DEVELOPER_DIR` replaces them).

## Architecture Patterns

### System Architecture Diagram

```
 Windows dev PC (no Swift)                GitHub (private repo, branch main)                       iPhone (iOS 18+)            Windows PC (server)
 ─────────────────────────                ────────────────────────────────                         ────────────────            ───────────────────
 edit Swift/YAML/plist ──git push──▶ ci.yml  [ubuntu-24.04, every code push, 1x]
                                       │ npm ci → typecheck → vitest (49)
                                       │ check_info_plist.py  (+ negative control: must FAIL on a stripped copy)
                                       │ swiftc -parse ios/PhotoSync/*.swift  (syntax only)
                                       │ node server/main.ts (bg) ── PHOTOSYNC_PORT=18787, DATA_DIR=$RUNNER_TEMP
                                       │ swift test (PhotoSyncCore): unit ┐
                                       │                                   └ contract ──HTTP 127.0.0.1──▶ real server
                                       ▼                                      health / admin/pairing / pair / status
                                   green ✓ ◀── user: gh run watch / Actions tab

 gh workflow run ios-build.yml ──▶ ios-build.yml [macos-26, manual only, 10x]
   (user deliberately)                │ 1 check_info_plist.py on checked-in Info.plist  → fail early with message
                                      │ 2 DEVELOPER_DIR=Xcode_26.6, print xcodebuild/swift versions
                                      │ 3 xcodegen (pinned zip) → ios/PhotoSync.xcodeproj
                                      │ 4 xcodebuild build  Release  generic/platform=iOS  CODE_SIGNING_ALLOWED=NO …
                                      │ 5 Payload/PhotoSync.app → PhotoSync.ipa ; unzip -l ; plist check inside ipa
                                      │ 6 job summary: elapsed → upload-artifact (ipa, 7 days; raw log on failure)
 gh run download ◀─────────────────────┘
   │ PhotoSync.ipa ─▶ iCloud Drive / Files ──────────────────────▶ AltStore "My Apps" + ─▶ re-sign (profile entitlements, id.TEAMID)
   │                                                                  │ launch → SwiftUI form
   │                                                                  │ type address + code ──POST /pair {code,deviceName}──▶ server.pair → {token,deviceId}
   │                                                                  │ token → Keychain ; non-secret state → pairing.json
   │                                                                  │ GET /health, GET /status (Bearer) ───────────────────▶ 200 {serverName,…}
   │                                                                  │ RunLog (token redacted) → Documents/photosync.log
   └◀── Files / Apple Devices / ShareLink ◀───────────────────────────┘
```

### Recommended Project Structure
```
photosync/
├── .gitattributes                         # LF for ios/**, .github/**, *.py, *.yml, *.plist, *.swift
├── .gitignore                             # + .build/ .swiftpm/ build/ Payload/ *.ipa ios/PhotoSync.xcodeproj/ DerivedData/ .DS_Store
├── .github/workflows/
│   ├── ci.yml                             # Linux, every code push
│   └── ios-build.yml                      # macOS, workflow_dispatch only
├── ios/
│   ├── project.yml                        # XcodeGen spec (never commit the .xcodeproj)
│   ├── PhotoSync/                         # APP TARGET, Swift 5 mode, Apple-only glue (target < ~400 lines in Phase 1)
│   │   ├── Info.plist                     # checked in, hand-written XML
│   │   ├── PhotoSyncApp.swift
│   │   ├── ContentView.swift
│   │   ├── AppModel.swift                 # @MainActor @Observable
│   │   ├── KeychainDeviceKeyStore.swift   # implements Core's DeviceKeyStoring
│   │   └── AppEnvironment.swift           # builds URLSession (waitsForConnectivity), paths, Core objects
│   ├── Packages/PhotoSyncCore/            # PURE SWIFT, tools 6.0, Swift 6 mode, no dependencies
│   │   ├── Package.swift
│   │   ├── Sources/PhotoSyncCore/
│   │   │   ├── ServerAddress.swift        # parse "ip", "ip:port", "http://ip:port", "http://ip:port/#pair=CODE"
│   │   │   ├── DeviceKey.swift            # redacting wrapper + DeviceKeyStoring protocol + InMemoryDeviceKeyStore
│   │   │   ├── Wire.swift                 # Codable mirrors: HealthResponse, PairRequest, PairResponse, ClientStatus, ServerErrorBody
│   │   │   ├── HTTPTransport.swift        # protocol + URLSession implementation (#if canImport(FoundationNetworking))
│   │   │   ├── ServerClient.swift         # health(), pair(), status()
│   │   │   ├── PairingStore.swift         # atomic JSON for non-secret pairing state
│   │   │   ├── RunLog.swift               # actor: append, flush, rotate, scrub known secrets
│   │   │   └── LaunchEvidence.swift       # launch counter + bundle-id/keychain facts → log lines (FEAS-01 evidence)
│   │   └── Tests/PhotoSyncCoreTests/      # Unit/, Contract/
│   └── scripts/check_info_plist.py        # required-keys gate (source plist, built .app plist, or .ipa)
└── (server/ shared/ web/ tests/ unchanged)
```

### Pattern 1: Cheap-first gating (Linux catches what Mac would bill 10x for)
**What:** Every check that can run without Apple tooling runs in `ci.yml` and again as the first step of the Mac job: plist gate, `swiftc -parse`, Core compile + tests, server tests.
**When to use:** Always; this is the whole economic argument of the project.
**Example (`ci.yml` skeleton):**
```yaml
# Source: composed from verified action versions above; NOT yet run (first push is the check) [ASSUMED]
name: ci
on:
  push:
    paths-ignore: ['.planning/**', 'docs/**', '**/*.md']
  workflow_dispatch:
concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }
permissions: { contents: read }
jobs:
  checks:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v7
        with: { node-version: 24, cache: npm }
      - run: npm ci
      - run: npm run typecheck
      - run: npm test
      - name: Info.plist gate (must pass)
        run: python3 ios/scripts/check_info_plist.py ios/PhotoSync/Info.plist
      - name: Info.plist gate negative control (must fail)
        run: |
          grep -v NSPhotoLibraryUsageDescription ios/PhotoSync/Info.plist > "$RUNNER_TEMP/bad.plist" || true
          if python3 ios/scripts/check_info_plist.py "$RUNNER_TEMP/bad.plist"; then echo "gate did not fail"; exit 1; fi
      - run: swiftc -version && swiftc -parse ios/PhotoSync/*.swift
      - name: Start the real server
        run: |
          mkdir -p "$RUNNER_TEMP/ps-data"
          PHOTOSYNC_DATA_DIR="$RUNNER_TEMP/ps-data" PHOTOSYNC_PORT=18787 \
            nohup node --disable-warning=ExperimentalWarning server/main.ts > "$RUNNER_TEMP/server.out" 2>&1 &
          for i in $(seq 1 60); do curl -sf http://127.0.0.1:18787/api/v1/health && exit 0; sleep 0.5; done
          cat "$RUNNER_TEMP/server.out"; exit 1
      - name: swift test (unit + contract)
        working-directory: ios/Packages/PhotoSyncCore
        env: { PHOTOSYNC_CONTRACT_URL: 'http://127.0.0.1:18787' }
        run: swift --version && swift test
```
Notes: `CI=true` is set by Actions, which the contract tests use to turn "server not configured" into a failure instead of a skip. Do **not** set `PHOTOSYNC_HOST=127.0.0.1`: `server/main.ts` would then bind the same address twice (`app.listen` on 127.0.0.1, then the LAN server on `lanIp`) and exit with EADDRINUSE; leave it unset and it binds loopback plus the runner's private NIC (see Pitfall 9).

### Pattern 2: Headless contract test through the existing admin endpoint
**What:** The Swift test calls `GET {base}/api/v1/admin/pairing` (loopback + `Host: 127.0.0.1:<port>` satisfies `requireAdmin`), reads `code`, then drives `ServerClient.pair` etc. over real HTTP. No new server entry point, no server change.
**When to use:** Every contract test that needs a fresh pairing code (the code rotates after each successful pairing).
**Example:** see "Code Examples -> contract test".

### Pattern 3: Redaction by construction, then by scrubbing
**What:** `DeviceKey` is a struct whose `description`, `debugDescription` and `customMirror` return `<redacted>`; the raw string is reachable only via `.revealForAuthorization()` used in one place (building the header). `RunLog` additionally holds a set of registered secrets (device key, pairing code) and replaces them in every line before writing.
**When to use:** All logging. Never log request headers.

### Pattern 4: Launch evidence for a debugger-less gate
**What:** On every launch the app logs one block: build number, version, git SHA, `Bundle.main.bundleIdentifier`, AltStore original id (if present), launch counter, Keychain read result (found / not found / OSStatus), `pairing.json` present or not, and (after first connection) health result with the `NSError` domain/code/underlying code. After an AltStore refresh, diffing the two launch blocks answers FEAS-01 without a debugger.

### Anti-Patterns to Avoid
- **Setting `waitsForConnectivity`, `allowsExpensiveNetworkAccess` or `allowsConstrainedNetworkAccess` anywhere in Core:** compile failure on Linux (see Pitfall 3).
- **Parsing user-entered addresses with `URL(string:)`:** behaviour of bare `host:port` differs between swift-foundation versions/platforms; tests green on Linux could differ on Darwin. Parse by hand (split scheme / host / port), then build with `URLComponents`.
- **Generating `Info.plist` from `project.yml` `info:`:** hides the keys from Linux checks. Use the checked-in file.
- **Committing the generated `.xcodeproj`, an `.entitlements` file, an `AppIcon` asset catalog, or app extensions in Phase 1:** each adds failure modes or burns App IDs for no gain (skip the icon; AltStore shows a placeholder).
- **Running the Mac job on push:** it is `workflow_dispatch` only.
- **Hard-coding the runtime bundle ID** anywhere: AltStore rewrites it.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| iOS project file | `project.pbxproj` by hand | XcodeGen `project.yml` | Any typo is found only on a 10x build |
| Plist validation | regex over XML | Python `plistlib` | Reads both XML and binary plists, so one script checks source plist, built `.app` and `.ipa` |
| Zipping the `.ipa` | custom packaging code | `mkdir Payload && cp -R … && zip -qry PhotoSync.ipa Payload` | `Payload/` must be the top-level folder |
| Re-signing / profile / App ID | anything | AltStore | It rewrites bundle ID, replaces entitlements wholesale from the profile, and reuses the App ID |
| HTTP client | socket code | `URLSession` | Required by ATS/Local Network behaviour anyway |
| Secret storage | file/UserDefaults for the key | Keychain | The key grants upload rights on the PC |
| Hashing, JSON | anything | Not needed in Phase 1 | CryptoKit/JSON land in later phases |
| QR scan | anything | Deferred to Phase 4 | Phase 1 is typed entry only |
| Mac-minute accounting | log scraping | Billing "Usage" report | Source of truth for what is billed |

**Key insight:** every hand-rolled piece in this phase is code that can only be validated on a 10x build or on the phone; the lazy path is the one that keeps the Apple-only surface to a few hundred lines.

## Runtime State Inventory

Not applicable: greenfield addition (no rename/refactor/migration). Nothing in the existing server stores or registers anything that Phase 1 changes. One related fact: each native pairing creates a new row in the server's `devices` table (the Safari page has its own device row), so the PC dashboard will list the app as a separate paired device.

## Common Pitfalls

### Pitfall 1: Unsigned `.ipa` builds fine but is not a valid payload
**What goes wrong:** zip has the wrong top-level folder, wrong product path, or an app built for the simulator; AltStore reports 1007/2007 "invalid format".
**Why it happens:** `xcodebuild build` output path differs from memory; `-sdk` guessed; `-destination` wrong.
**How to avoid:** `-destination 'generic/platform=iOS'` (no `-sdk`, so no hard-coded SDK number: the macos-26 README lists iOS SDKs 26.0-26.5 while the default Xcode is 26.6, so do not write `iphoneos26.6`); `ls build/Build/Products/*/` before copying; after zipping run `unzip -l PhotoSync.ipa | head` and run the plist gate on `Payload/PhotoSync.app/Info.plist` extracted from the ipa; assert `Payload/PhotoSync.app/PhotoSync` exists.
**Warning signs:** AltStore errors 1007, 2007, 3009 (non-ASCII app name; keep `CFBundleName` ASCII) [CITED: faq.altstore.io/altstore-classic/error-codes.md].

### Pitfall 2: XcodeGen + local package + Xcode 26 untested together
**What goes wrong:** package not linked, product name mismatch, or Swift 6 package imported into a Swift 5 target errors.
**How to avoid:** product name equals package name (`PhotoSyncCore`) so `dependencies: - package: PhotoSyncCore` needs no `product:` [CITED: XcodeGen ProjectSpec.md]. Keep the library product static/automatic (no embedded framework). **Prepared fallback (one-line change):** if package resolution fails on the first Mac build, add `../Packages/PhotoSyncCore/Sources/PhotoSyncCore` as a second `sources:` entry of the app target and drop the `packages:` block; same files, no package.
**Warning signs:** `xcodebuild` error "Missing package product" or "no such module PhotoSyncCore".

### Pitfall 3: Darwin-only URLSession settings break the Linux build
**What goes wrong:** `swift test` on Linux fails to compile Core.
**Why:** In swift-corelibs-foundation `waitsForConnectivity` is declared `@available(*, unavailable, message: "Not available on non-Darwin platforms")` [VERIFIED: URLSessionConfiguration.swift lines 247-249 read this session; quote: `open var waitsForConnectivity: Bool { NSUnsupported() }`], and a code search for `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` in the repo returns 0 results [VERIFIED: `gh api search/code`, total_count 0 for both]. `allowsCellularAccess` is available.
**How to avoid:** Core's `URLSessionTransport(session:)` takes a prepared session; the app's `AppEnvironment` builds `URLSessionConfiguration.default` with `waitsForConnectivity = true`, `allowsCellularAccess = false`, `timeoutIntervalForRequest`, `httpMaximumConnectionsPerHost`. Tests use `.default`.

### Pitfall 4: Local Network prompt looks like a connection failure
**What goes wrong:** first `GET /health` fails with `NSURLErrorNotConnectedToInternet` (-1009) while the system alert is on screen.
**Why:** TN3179: "If the system presents a local network alert in response to one of your local network operations, it may deny the operation immediately, before the user has responded to the alert", so use `URLSession` with `waitsForConnectivity` enabled or add retry logic [CITED: developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy.md]. A request made while the app is in the background with the privilege undetermined is denied without a prompt.
**How to avoid:** `waitsForConnectivity = true` on the app's session, a bounded `timeoutIntervalForResource` (about 30 s), one automatic retry after a -1009 on the very first connection, and a hint line "If iOS asked to allow Local Network access, tap Allow, then try again". Log domain + code + underlying code, never only `localizedDescription` (-1009 local network, -1022 ATS, -1200 TLS, -1001 timeout, -1004 cannot connect) [CITED: Apple DTS forum thread 788044 for the ATS-vs-LNP split].
**Warning signs:** works after a phone reboot; iOS 18.0-18.5 had a stale-denied-state bug (FB14321888) fixed in iOS 18.6 [CITED: TN3179 "Historical considerations"]. Record the phone's exact iOS version in the test sheet.

### Pitfall 5: Local Network grant or Keychain item lost after an AltStore refresh
**What goes wrong:** pairing disappears after "Refresh All", or the Local Network prompt returns.
**Why:** TN3179: "Local network privacy tracks the identity of your program using its code signature". AltStore re-signs on every refresh; whether the grant survives is not documented. For Keychain the default access group is `teamID.bundleID` [CITED: developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps.md: "If you don't specify any keychain access groups, then the app ID is the default"], and AltStore keeps team and rewritten bundle ID stable (see AltStore facts below), so the Keychain item should survive; this is a hypothesis for the device test, not a fact.
**How to avoid:** do not specify `kSecAttrAccessGroup`; log Keychain read status at launch; design the "key missing but pairing.json present" state as a visible "re-pair needed" message that is logged, so the gate result is observable. If the grant is lost but the key survives, that is not a gate failure; record it.

### Pitfall 6: Missing permission text discovered only on the phone
**How to avoid:** `check_info_plist.py` required keys (see Code Examples) run (a) in `ci.yml` on every push with a negative control, (b) as the first step of `ios-build.yml` before any Mac time is spent on compiling, (c) on the plist inside the final `.ipa`. The script prints which key is missing or empty and exits non-zero.

### Pitfall 7: `workflow` scope missing, push of `.github/workflows` rejected
**What goes wrong:** `git push` fails with "refusing to allow an OAuth App to create or update workflow ... without `workflow` scope".
**Evidence:** `gh auth status` shows token scopes `'gist', 'read:org', 'repo'` [VERIFIED: ran it this session]; the error is a known GitHub behaviour [CITED: dev.to "Can't push to GitHub: refusing to allow an OAuth App to create or update workflow without workflow scope"].
**How to avoid:** a user checkpoint before the first workflow push: `gh auth refresh -h github.com -s workflow` (interactive device flow). Also `user` scope is needed only if the billing REST API is wanted (not required).

### Pitfall 8: Linux CI cost eats the Mac allowance
**What goes wrong:** the 2,000 free minutes are shared; Linux at 1x on every push plus Mac at about 10x.
**How to avoid:** `paths-ignore` for `.planning/**`, `docs/**`, `**/*.md` (GSD commits planning docs constantly); `concurrency` with `cancel-in-progress`; `setup-node` npm cache; one Linux job instead of two (each job rounds up to a whole minute). Interpretation to confirm: "every push runs the tests" is implemented as "every push that changes code or workflows".

### Pitfall 9: Starting `server/main.ts` on a CI runner
**What goes wrong:** assumptions about `main.ts` on Linux are untested: `pickLanAddress()` picks the runner's NIC and the server binds loopback plus that NIC; default backup folder resolves to `~/Pictures/iPhone Backup` (no PowerShell on Linux, falls back, `server/config.ts` lines 17-31) but is never written to in Phase 1.
**How to avoid:** poll `/api/v1/health` before `swift test`, dump `server.out` on failure. **Fallback if `main.ts` misbehaves on the runner:** add `tests/contract/serve.ts` (a 25-line copy of the `startServer` setup in `tests/helpers.ts` lines 27-41 using `buildApp({ db, port: 0, lanIp: null, ... })`) and print the port as JSON. Do not pre-build this; only on evidence.

### Pitfall 10: Pairing throttle during tests
`MAX_FAILURES = 8` wrong codes per source IP per 5 minutes returns 429 [quoted below]. Contract tests use at most one wrong code, and run against a server started fresh in each CI run. Document in the device checklist: do not mash the Pair button with a wrong code.

### Pitfall 11: Re-install path burning App IDs or creating a second icon
**What goes wrong:** changing bundle ID between builds creates a new App ID (limit 10 per 7 days) and a second app.
**Evidence:** AltServer registers/reuses App IDs by exact (rewritten) bundle ID: `fetchAppIDs ... appIDs.first(where: { $0.bundleIdentifier == bundleID })`, creating one only if none matches; the rewrite is `updatedParentBundleID = parentBundleID + "." + team.identifier` [VERIFIED: AltStore `ALTDeviceManager+Installation.swift` raw source]. Same ipa bundle ID + same Apple ID => same App ID, so repeat installs and refreshes cost nothing.
**How to avoid:** fix the bundle ID once (Open Question 1), never change it, no extensions, no entitlements.

### Pitfall 12: Platform behaviour drift between Linux tests and Darwin runtime
Foundation APIs differ subtly between platforms (URL parsing, date/number formatting). Keep Core on boring APIs (manual string parsing, `JSONEncoder/Decoder` with default strategies, `FileManager` atomic writes, `Data`). Anything Darwin-only goes behind a protocol with an app-target implementation.

## Code Examples

All Swift/YAML below was composed from API knowledge and documents read this session; it has **not** been compiled anywhere. Treat it as the intended shape, tagged [ASSUMED] for compile-correctness. Discrete server values are quoted verbatim from files read this session.

### Server contract Phase 1 depends on (verbatim)
`server/app.ts:202-217`:
```ts
  app.get(`${API}/health`, async () => ({ ok: true, name: 'photosync', apiVersion: 1 }));

  app.post(`${API}/pair`, async (req) => {
    const body = PairRequest.parse(req.body);
    pairing.consume(body.code, req.ip);
    const token = newToken();
    const id = randomUUID();
    run(db, 'INSERT INTO devices (id, name, token_hash, created_at) VALUES (?, ?, ?, ?)', id, body.deviceName, hashToken(token), Date.now());
    ctx.log('info', 'paired', `Paired a new device: "${body.deviceName}".`);
    return { token, deviceId: id };
  });

  app.get(`${API}/status`, async (req): Promise<ClientStatus> => {
    const device = requireDevice(req);
    return { deviceName: device.name, serverName: os.hostname(), chunkSize: CHUNK_SIZE, concurrency: settings.concurrency, maxFileBytes: settings.maxFileBytes };
  });
```
`shared/schemas.ts:4-5, 14-17, 146-159`:
```ts
export const API = '/api/v1';
export const CHUNK_SIZE = 8 * 1024 * 1024;
export const PairRequest = z.object({
  code: z.string().min(1).max(32),
  deviceName: z.string().trim().min(1).max(80),
});
export interface PairingInfo {
  code: string;
  expiresAt: number;
  url: string | null;
  qrSvg: string | null;
}
export interface ClientStatus {
  deviceName: string;
  serverName: string;
  chunkSize: number;
  concurrency: number;
  maxFileBytes: number;
}
```
`server/security.ts:72-75, 93, 96, 100` (error codes and normalisation):
```ts
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // no look-alikes (0/O, 1/I/L)
const CODE_TTL_MS = 10 * 60 * 1000;
const MAX_FAILURES = 8;
const FAILURE_WINDOW_MS = 5 * 60 * 1000;
      throw new HttpError(429, 'too_many_attempts', 'Too many wrong pairing codes. Wait a few minutes and try again.');
    const given = Buffer.from(input.toUpperCase().replace(/[^A-Z0-9]/g, ''));
      throw new HttpError(403, 'bad_pairing_code', 'That pairing code is wrong or has expired. Check the dashboard for the current code.');
```
`server/app.ts:167, 147` (auth and network errors) and `app.ts:187-189` (error body shape):
```ts
    if (!device) throw new HttpError(401, 'unauthorized', 'This device is not paired. Scan the QR code on the Windows dashboard.');
    if (!isLocalNetworkAddress(req.ip)) throw new HttpError(403, 'forbidden_network', 'This server only accepts connections from the local network.');
    if (err instanceof HttpError) return reply.code(err.status).send({ error: err.code, message: err.message, ...err.extra });
    if (err instanceof z.ZodError) return reply.code(400).send({ error: 'invalid_request', message: z.prettifyError(err) });
```
`server/app.ts:360-366` (what the dashboard and the contract test read, loopback only via `requireAdmin`):
```ts
  app.get(`${API}/admin/pairing`, async (req): Promise<PairingInfo> => {
    requireAdmin(req);
    const { code, expiresAt } = pairing.current();
    // The code rides in the URL fragment, which browsers never send to a server or log.
    const url = lanUrl() && `${lanUrl()}/#pair=${code}`;
    return { code, expiresAt, url, qrSvg: url ? await QRCode.toString(url, { type: 'svg', margin: 1 }) : null };
  });
```
Environment for a headless server: `server/main.ts:11-12`: `const port = Number(process.env.PHOTOSYNC_PORT ?? 8787);` `const lanIp = process.env.PHOTOSYNC_HOST ?? pickLanAddress();` and `server/config.ts:13`: `return process.env.PHOTOSYNC_DATA_DIR ?? path.join(process.env.LOCALAPPDATA ?? os.homedir(), 'PhotoSync');`.

Consequences for the Swift side: pair body `{"code": <string>, "deviceName": <1-80 chars>}`; response `{"token","deviceId"}`; the code is case-insensitive and non-alphanumerics are stripped server-side, so the app only trims whitespace; entropy is 31^8 ~ 2^39.6 behind an 8 per 5 minutes per-IP throttle; QR URL form is `http://<ip>:<port>/#pair=<CODE>` (parse it when pasted into the address field); error bodies are `{error, message, ...extra}`.

### Info.plist (checked in; hand-written XML) [ASSUMED compile/launch-correct, keys are Apple-documented]
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>PhotoSync</string>
  <key>CFBundleDisplayName</key><string>PhotoSync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  <key>PhotoSyncGitSHA</key><string>$(GIT_SHA)</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
  <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
  <key>UIFileSharingEnabled</key><true/>
  <key>LSSupportsOpeningDocumentsInPlace</key><true/>
  <key>NSPhotoLibraryUsageDescription</key><string>PhotoSync reads your photo library to back it up to your PC. It never changes or deletes anything.</string>
  <key>NSLocalNetworkUsageDescription</key><string>PhotoSync connects to your PC on this Wi-Fi network to back up your photos.</string>
  <key>NSCameraUsageDescription</key><string>Used only to scan the pairing QR code shown on your PC.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
```
Rationale for what is in and out: Apple's ATS page: "In iOS 17, iPadOS 17, and macOS 14, ATS no longer allows connections to IP addresses by default" and "The local networking exception tells newer versions of the OS to ignore the arbitrary loads key, and enable access to unqualified domains, `.local` domains, and IP addresses that they would otherwise restrict" [CITED: developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking.md]. So `NSAllowsLocalNetworking` is the required and sufficient key; no `NSAllowsArbitraryLoads`. **Fallback ladder if the device test fails with a TLS/ATS error (-1200/-1022):** (1) add `NSExceptionDomains` entries for the private ranges (Apple: "Add individual IP addresses and classless inter-domain routing (CIDR) ranges in the `NSExceptionDomains` dictionary") with `NSExceptionAllowsInsecureHTTPLoads`; (2) only then `NSAllowsArbitraryLoads`; record why. `UIFileSharingEnabled`: "Place the files in a `Documents` folder located in the app's home directory" [CITED: developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled.md]. Photos and camera strings are included now (unused until Phases 2/4) so the plist never changes again and the gate has a real required list. No `NSBonjourServices` (TN3179 requires it only for Bonjour use). No `UIBackgroundModes`.

### `ios/project.yml` [ASSUMED; schema keys from XcodeGen ProjectSpec.md read this session]
```yaml
name: PhotoSync
options:
  deploymentTarget: { iOS: "18.0" }
packages:
  PhotoSyncCore:
    path: Packages/PhotoSyncCore
targets:
  PhotoSync:
    type: application
    platform: iOS
    sources: [PhotoSync]
    dependencies:
      - package: PhotoSyncCore
    settings:
      base:
        SWIFT_VERSION: "5.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.mewtcor.photosync   # PLACEHOLDER: user confirms once, then never changes
        INFOPLIST_FILE: PhotoSync/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        GIT_SHA: dev
        TARGETED_DEVICE_FAMILY: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "18.0"
        # no CODE_SIGN_ENTITLEMENTS, no entitlements: key, no capabilities
```
XcodeGen facts used: `packages:` accepts a local `path:`; `dependencies: - package: <name>` with `product:` defaulting to the package name; `INFOPLIST_FILE` set in `settings` is respected and `Info.plist` files are never added to a build phase [CITED: github.com/yonaskolb/XcodeGen Docs/ProjectSpec.md].

### `Package.swift` [ASSUMED]
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "PhotoSyncCore",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "PhotoSyncCore", targets: ["PhotoSyncCore"])],
  targets: [
    .target(name: "PhotoSyncCore"),                                  // Swift 6 language mode by default with tools 6.0
    .testTarget(name: "PhotoSyncCoreTests", dependencies: ["PhotoSyncCore"]),
  ]
)
```

### `ios-build.yml` skeleton (Mac, manual) [ASSUMED; flags from STACK.md / unsigned-ipa guides, corroborated by anazhd/ipa-builder using `CODE_SIGNING_ALLOWED=NO` and `Payload/`]
```yaml
name: ios-build
on: { workflow_dispatch: {} }
concurrency: { group: ios-build, cancel-in-progress: true }
permissions: { contents: read }
env:
  XCODE: /Applications/Xcode_26.6.app
jobs:
  build:
    runs-on: macos-26                 # standard arm64 runner; never macos-latest, never -xlarge/-large/-intel
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@v7
      - name: Start clock and fail early on a missing permission text
        run: |
          echo "T0=$(date +%s)" >> "$GITHUB_ENV"
          python3 ios/scripts/check_info_plist.py ios/PhotoSync/Info.plist
      - name: Select Xcode and print versions
        run: |
          test -d "$XCODE" || { echo "Xcode 26.6 not on this image:"; ls /Applications | grep Xcode; exit 1; }
          echo "DEVELOPER_DIR=$XCODE/Contents/Developer" >> "$GITHUB_ENV"
          sudo xcode-select -s "$XCODE/Contents/Developer" && xcodebuild -version && swift --version
      - name: XcodeGen (pinned)
        run: |
          curl -fsSL -o xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
          echo "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806  xcodegen.zip" | shasum -a 256 -c -
          unzip -q xcodegen.zip && ./xcodegen/bin/xcodegen --version
          (cd ios && ../xcodegen/bin/xcodegen generate)
      - name: Build (unsigned)
        run: |
          set -o pipefail
          xcodebuild build -project ios/PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
            -destination 'generic/platform=iOS' -derivedDataPath build \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
            CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER}" GIT_SHA="${GITHUB_SHA::7}" 2>&1 | tee build.log | xcbeautify
      - name: Package ipa and verify
        run: |
          ls build/Build/Products/
          mkdir Payload && cp -R build/Build/Products/Release-iphoneos/PhotoSync.app Payload/
          zip -qry PhotoSync.ipa Payload
          unzip -l PhotoSync.ipa | head -20
          unzip -p PhotoSync.ipa 'Payload/PhotoSync.app/Info.plist' > built-Info.plist
          python3 ios/scripts/check_info_plist.py built-Info.plist
          test -f Payload/PhotoSync.app/PhotoSync
      - name: Record elapsed time
        if: always()
        run: echo "mac job wall time: $(( $(date +%s) - T0 )) s (billing rounds each job up to whole minutes)" >> "$GITHUB_STEP_SUMMARY"
      - uses: actions/upload-artifact@v7
        with: { name: PhotoSync-ipa, path: PhotoSync.ipa, retention-days: 7, compression-level: 0 }
      - uses: actions/upload-artifact@v7
        if: failure()
        with: { name: build-log, path: build.log, retention-days: 3 }
```
Notes: the `-quiet`/log noise tradeoff favours keeping the raw `build.log` because the only compiler is on CI. Fetching a failed log from Windows: `gh run view <id> --log-failed`. If `DEVELOPER_DIR` plus `xcode-select -s` feels redundant, keep both for the first run and remove one once proven.

### `ios/scripts/check_info_plist.py` [ASSUMED; plistlib is stdlib]
```python
#!/usr/bin/env python3
"""Fail if a required Info.plist key is missing or empty. Reads XML or binary plists."""
import plistlib, sys

REQUIRED_TEXT = ["NSPhotoLibraryUsageDescription", "NSLocalNetworkUsageDescription", "NSCameraUsageDescription"]

def main(path: str) -> int:
    with open(path, "rb") as f:
        p = plistlib.load(f)
    problems = [f"missing or empty usage text: {k}" for k in REQUIRED_TEXT if not str(p.get(k, "")).strip()]
    if p.get("NSAppTransportSecurity", {}).get("NSAllowsLocalNetworking") is not True:
        problems.append("NSAppTransportSecurity.NSAllowsLocalNetworking must be true")
    for k in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace"):
        if p.get(k) is not True:
            problems.append(f"{k} must be true (log export through Files)")
    if "NSAllowsArbitraryLoads" in p.get("NSAppTransportSecurity", {}):
        problems.append("NSAllowsArbitraryLoads must not be set without a recorded reason")
    for line in problems:
        print(f"ERROR {path}: {line}", file=sys.stderr)
    return 1 if problems else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```
Run locally on the dev PC with `python ios/scripts/check_info_plist.py ios/PhotoSync/Info.plist` (the dev machine's `python3` alias is a Store stub; `python` works).

### Keychain adapter (app target) [ASSUMED]
```swift
import Security
import PhotoSyncCore

struct KeychainDeviceKeyStore: DeviceKeyStoring {
  private let service = "photosync.device-key", account = "device-key"
  func load() -> KeyLoadResult {                     // .found(DeviceKey) / .notFound / .failed(OSStatus)
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var out: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    if st == errSecItemNotFound { return .notFound }
    guard st == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8) else { return .failed(st) }
    return .found(DeviceKey(s))
  }
  func save(_ key: DeviceKey) -> OSStatus {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    return SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                       kSecValueData as String: Data(key.revealForAuthorization().utf8),
                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
  }
}
```
No `kSecAttrAccessGroup`, so the default group (app ID) is used. Log the returned `OSStatus` (never the value).

### Core transport + client shape [ASSUMED]
```swift
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
public struct URLSessionTransport: HTTPTransport {
  let session: URLSession                                   // configured by the caller (Darwin-only options live in the app)
  public init(session: URLSession) { self.session = session }
  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, resp) = try await session.data(for: request) // exists in corelibs (verified) and on iOS 15+
    guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, http)
  }
}
```
`ServerClient` builds requests for `GET /api/v1/health`, `POST /api/v1/pair` (JSON body, `Content-Type: application/json`) and `GET /api/v1/status` (`Authorization: Bearer <key>`); decodes non-2xx bodies as `ServerErrorBody { error, message }`; never passes the key to the logger.

### Contract test (Swift Testing) [ASSUMED]
```swift
import Testing
import Foundation
@testable import PhotoSyncCore

let contractURL = ProcessInfo.processInfo.environment["PHOTOSYNC_CONTRACT_URL"]

@Test("CI must have configured the contract server")
func contractConfigured() { if ProcessInfo.processInfo.environment["CI"] != nil { #expect(contractURL != nil) } }

@Test(.enabled(if: contractURL != nil)) func pairsAndReadsStatusWithoutLeakingTheKey() async throws {
  let base = URL(string: contractURL!)!
  let transport = URLSessionTransport(session: .shared)
  // 1. code comes from the same endpoint the dashboard uses (loopback only)
  let info = try await ServerClient.adminPairingInfo(base: base, transport: transport)
  let log = RunLog(directory: FileManager.default.temporaryDirectory.appendingPathComponent("contract-\(UUID())"))
  let client = ServerClient(base: base, transport: transport, log: log)
  let paired = try await client.pair(code: info.code, deviceName: "Contract Test")
  await log.register(secret: paired.token)
  let status = try await client.status(key: DeviceKey(paired.token))
  #expect(status.chunkSize == 8 * 1024 * 1024)            // CHUNK_SIZE in shared/schemas.ts:5
  #expect(!status.serverName.isEmpty)
  #expect(await log.snapshot().contains(paired.token) == false)
}
```
Other contract cases: `GET /health` returns `ok == true` and `name == "photosync"` and `apiVersion == 1`; one wrong code returns error `bad_pairing_code` (403); `status` with a made-up key returns `unauthorized` (401).

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| ATS ignores IP literals | iOS 17+ blocks IP addresses by default; `NSAllowsLocalNetworking` re-enables them | iOS 17 | The SUMMARY premise was wrong; the chosen key is still the right one |
| `macos-latest` = whatever | `macos-latest` -> macOS 26 arm64; pin `macos-26`; `-xlarge`/`-large`/`-intel` labels are separate (paid) | 2026 | Pin the standard label |
| `ubuntu-latest` = 24.04 | `ubuntu-latest` becomes Ubuntu 26.04 in November 2026 | announced 2026-09-17 | Pin `ubuntu-24.04` so Swift 6.4 / Node 22 stay stable |
| `GET .../actions/runs/{id}/timing` for billed minutes | "This endpoint is in the process of closing down" | 2026 | Use the billing usage report; elapsed time in step summary as cross-check |
| Billing described as minute multipliers | Docs now list per-minute rates: macOS 3/4-core `$0.062`, Linux 2-core `$0.006`, Windows `$0.010`; Free plan 2,000 minutes, 500 MB artifacts | 2026 | Ratio 0.062/0.006 ~ 10.3x; treat "about 190-200 Mac minutes a month" as an estimate until BLD-07 measures it |
| `brew install xcodegen` | pinned release zip with checksum | - | No Homebrew surprises on a fresh image |
| Apple docs are JS-only | Appending `.md` to a developer.apple.com documentation URL returns readable markdown | observed this session | Useful for re-checking any plist/API claim |

**Deprecated/outdated:** `NSAllowsArbitraryLoads` as a first choice; `allowsExpensiveNetworkAccess` in cross-platform code; brew-installed XcodeGen on the metered runner.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `xcodebuild build -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` yields `build/Build/Products/Release-iphoneos/PhotoSync.app` on Xcode 26.6 | ios-build.yml | First Mac build fails; workflow prints the products folder so the fix is a one-line path change (costs one build) |
| A2 | AltStore (Classic, current) accepts the unsigned `.ipa` and installs it | BLD-04 | Gate fails; re-plan install route (AltSign overwrites signing wholesale, so likely fine) |
| A3 | Installing a newer `.ipa` with the same bundle ID via AltStore "+" updates in place (one icon, data kept) | BLD-04/criterion 3 | Could create a prompt or a second app; the device test settles it |
| A4 | Keychain item and `pairing.json` survive AltStore "Refresh All" | FEAS-01 | Gate failure (this is exactly what the gate measures) |
| A5 | The Local Network grant survives a refresh (code signature tracking may reset it) | Pitfall 5 | App re-prompts after weekly refresh; acceptable if foreground, record it |
| A6 | Swift 6.4 is on `PATH` on `ubuntu-24.04` without extra setup (installed under `/usr/share/swift/usr/bin` by the image script) | ci.yml | Add one `PATH` export line |
| A7 | `swiftc -parse` accepts SwiftUI/`@main`/`#Preview` sources without SDK modules | ci.yml | Drop that step (it is only a typo filter) |
| A8 | Unmodified `server/main.ts` runs headless on the Ubuntu runner (binds loopback + runner NIC, falls back to `~/Pictures`) | Pitfall 9 | Add the small `tests/contract/serve.ts` fallback |
| A9 | The existing vitest suite passes on Linux | ci.yml | Move the vitest step to `windows-latest` (2x minutes) |
| A10 | `xcodegen.zip` unpacks to `xcodegen/bin/xcodegen` | ios-build.yml | Use `find` or brew fallback |
| A11 | XcodeGen 2.46.0 + local package + Xcode 26.6 + Swift 5 app importing a Swift 6 package compiles | Pitfall 2 | Use the prepared `sources:` fallback |
| A12 | `ShareLink(item: fileURL)` offers Save to Files / share of the file; the Files-app route via `UIFileSharingEnabled` works for AltStore-signed builds (AltStore's `ResignAppOperation.swift` does not touch those keys, verified) | BLD-05 | Either route suffices for the criterion; add a `Transferable` `FileRepresentation` wrapper if ShareLink only shares a link |
| A13 | Apple Devices (Windows) shows a file-sharing view for apps with `UIFileSharingEnabled` | Log retrieval | Fall back to Files -> iCloud Drive |
| A14 | The `.ipa` can reach the phone via iCloud Drive for Windows (installed because AltServer requires it) then AltStore "+" -> Files | Delivery | Download the artifact zip in Safari on the phone (Files unzips it) |
| A15 | AltStore stores the original bundle ID under the Info.plist key `ALTBundleIdentifier` | LaunchEvidence | Field shows "-" |
| A16 | Billing: the Free plan's 2,000 included minutes are consumed by macOS jobs at about 10x (so about 190-200 Mac minutes) | BLD-07 | Measured by BLD-07 itself |
| A17 | Bundle ID `com.mewtcor.photosync` is acceptable to the user | project.yml | Placeholder; must be confirmed once (immutable afterwards) |
| A18 | `gh auth refresh -s workflow` is the right way to add the missing scope | Repo setup | Create a new token with `repo` + `workflow` instead |
| A19 | Swift Testing runs under `swift test` on the preinstalled Linux toolchain | Core tests | Switch the tests to XCTest |

## Open Questions

1. **Bundle identifier (immutable).**
   - What we know: one ID forever; AltStore appends the team ID; length/ASCII rules apply (error 3009 for non-ASCII names).
   - What's unclear: the user's preferred reverse-DNS prefix.
   - Recommendation: ask once at the start of the build plan; default `com.mewtcor.photosync` (GitHub handle). Record it in `01-GATE.md`.
2. **Exact iOS version on the phone.** 18.0-18.5 have the Local Network stale-state bug (fixed in 18.6). Ask for it and put it in the device test sheet.
3. **Do the 49 server tests pass on Linux?** Unknown until the first `ci.yml` run. Plan a decision point after the first run: keep Linux or move vitest to `windows-latest`.
4. **How is the `.ipa` delivered to the phone, and how does AltStore handle install-over?** Plan a documented route (artifact -> `gh run download` -> iCloud Drive -> AltStore "+") and let the device test confirm; a Windows-side "Sideload .ipa" menu entry was not confirmed in official docs.
5. **"Every push" scope.** Recommended interpretation: every push that changes code/workflows (docs and `.planning` pushes skipped to protect the allowance). Confirm this is acceptable.
6. **Billing guardrail.** Ask the user to confirm the account has no payment method/budget that could bill past the free allowance (the new billing UI uses "budgets"; a $0 budget for Actions is the safe setting) before the first Mac build. [CITED: STACK.md; not re-verified on the live billing page].
7. **Keep `.planning/` in the private repo?** It is already tracked (`git ls-files` shows `.planning/*` and `.claude/CLAUDE.md`); default yes, private repo.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Node.js / npm | server tests, local dev | yes | v24.16.0 | - |
| `npm test` / `npm run typecheck` | regression gate | yes, pass | 49 tests, 17 s; typecheck 0.6 s [VERIFIED locally] | - |
| `gh` CLI | repo creation, dispatch, watch, logs, artifact download | yes | 2.102.0, logged in as `mewtcor` | - |
| `gh` token `workflow` scope | pushing `.github/workflows/*` | **no** (scopes: gist, read:org, repo) | - | `gh auth refresh -h github.com -s workflow` (user, interactive) |
| `gh` token `user` scope | billing REST API | no | - | Billing UI usage report (manual) |
| Python | plist gate locally | yes as `python` | 3.14.5 (`python3` is a Microsoft Store stub) | run via `python` |
| Swift toolchain | local Swift compile/test | **no** | - | None needed: Linux CI is the compiler. Optional `winget install Swift.Toolchain` is not recommended for Phase 1 (heavy prerequisites, FoundationNetworking on Windows unverified) |
| WSL distro | local Linux checks | **no** (WSL installed, no distribution) | - | Use CI |
| Docker | - | no | - | not needed |
| Git remote | CI | none yet | branch is `master` | rename to `main` and create private repo |
| GitHub Actions free minutes | CI | private repo: 2,000 min/month | - | Public repo or another CI host is the user's call (roadmap) |
| Ubuntu runner | Linux job | yes | `ubuntu-24.04` image 20261004.327.1: Swift 6.4, Node 22.23.3 (24.21.0 cached), Git 2.55.0, `gh` 2.102.0, Python 3.12.3 | - |
| macOS runner | Mac job | yes | `macos-26` image 20260907.0351.1, macOS 26.6.2, Xcode 26.6 default | - |
| AltStore + AltServer + iTunes/iCloud | install | already set up by the user (not probed) | - | - |
| iPhone on iOS 18+ | device test | user-owned (exact version unknown) | - | - |

**What can be checked locally on this Windows machine:** server tests and typecheck; the plist gate script (including its negative control); starting the real server (`npm start`) and exercising `/health`, `/admin/pairing`, `/pair`, `/status` with `curl` to see the contract by hand; workflow YAML only by pushing (no local linter installed); `gh workflow run` / `gh run watch --exit-status` / `gh run view --log-failed` for the remote loop.
**What cannot be checked locally:** any Swift compile or test, XcodeGen, `xcodebuild`, the merged Info.plist, `.ipa` validity, AltStore install, Local Network behaviour, Keychain persistence. Linux CI covers Core compile/tests; only the first and later Mac builds and the phone cover the rest.

**Missing dependencies with no fallback:** none blocking, but the `workflow` token scope must be added by the user before the first workflow push.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Vitest 5.0.3 (server, existing); Swift Testing via `swift test` on Swift 6.4 / `ubuntu-24.04` (Core); Python script with a CI negative control (plist gate); GitHub Actions as the harness; human device checklist |
| Config file | `vitest.config.ts` (existing); `ios/Packages/PhotoSyncCore/Package.swift` (Wave 0); `.github/workflows/ci.yml` (Wave 0) |
| Quick run command | local: `npm test && npm run typecheck && python ios/scripts/check_info_plist.py ios/PhotoSync/Info.plist`; remote: `git push` then `gh run watch --exit-status` |
| Full suite command | the same `ci.yml` run (server tests, plist gate + negative control, `swiftc -parse`, `swift test` incl. contract) plus a manual `ios-build.yml` run |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BLD-01 | Repo is private; `package-lock.json` tracked | smoke | `gh repo view --json isPrivate,defaultBranchRef` ; `git ls-files package-lock.json` | Wave 0 |
| BLD-02 | Push runs server + Swift tests incl. contract and goes green | CI | `gh run list --workflow ci.yml --limit 1 --json conclusion` == success | Wave 0 (`ci.yml`) |
| BLD-02 | Contract: health, pair, wrong code 403, status 200/401 against the real server | integration | `swift test --filter Contract` with `PHOTOSYNC_CONTRACT_URL` | Wave 0 (`Tests/.../Contract`) |
| BLD-03 | Missing permission text stops the build with a clear message | unit | `python ios/scripts/check_info_plist.py <stripped copy>` exits non-zero and names the key; CI negative control | Wave 0 |
| BLD-03 | Manual Mac build yields unsigned `.ipa` containing `Payload/PhotoSync.app` | CI | `gh workflow run ios-build.yml`; `gh run watch`; `gh run download -n PhotoSync-ipa`; `unzip -l` | Wave 0 (`ios-build.yml`) |
| BLD-04 | No entitlements, one bundle ID, no extensions | static | CI step: fail if any `*.entitlements` file exists or `project.yml` contains `entitlements`/`CODE_SIGN_ENTITLEMENTS`/`extension` targets | Wave 0 |
| BLD-04 | Install-over keeps one icon and data | manual (device) | Checklist step | Wave 0 (`docs/ios-phase1-device-test.md`) |
| BLD-05 | Device key never in log (type-level) | unit | `swift test --filter Redaction` (`"\(key)"`, `String(reflecting:)`, `dump` all redacted) | Wave 0 |
| BLD-05 | Real token never in log (behavioral) | integration | contract test greps `RunLog` snapshot for the token issued by the real server | Wave 0 |
| BLD-05 | Export via share sheet or Files works | manual (device) | Checklist step | Wave 0 |
| BLD-06 | Version/build shown | static + manual | plist gate on built plist asserts `CFBundleVersion` is the run number; device checklist reads the screen | Wave 0 |
| BLD-07 | Billed Mac minutes recorded for >= 2 builds | manual/doc | `01-GATE.md` has a table: run id, wall seconds, billed minutes from the Usage report | Wave 0 |
| FEAS-01 | Plain HTTP reaches PC; key survives relaunch and AltStore refresh | manual (device) | Checklist: launch-evidence log blocks before/after refresh; PC dashboard shows device and last-seen | Wave 0 |
| PAIR-02 | Typed address+code pairs | unit + integration + manual | `ServerAddress` parse table tests; contract pair; device pairing | Wave 0 |
| PAIR-03 | Key in Keychain, pairing remembered | unit (fake store) + manual | `PairingStore` round trip/corruption tests; device relaunch | Wave 0 |

### Sampling Rate
- **Per task commit:** local quick run (seconds); for Swift/YAML edits, push and `gh run watch --exit-status` (Linux job, minutes, 1x).
- **Per wave merge:** a green `ci.yml` run on the pushed commit.
- **Phase gate:** green `ci.yml`, at least two successful `ios-build.yml` runs with recorded minutes, and the signed-off device checklist, written as the go/no-go note, before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `ios/Packages/PhotoSyncCore/Package.swift` + `Tests/PhotoSyncCoreTests/{Unit,Contract}` (ServerAddress, DeviceKey redaction, RunLog scrub/rotate, ServerClient with fake transport, PairingStore, contract)
- [ ] `.github/workflows/ci.yml` and `ios-build.yml`
- [ ] `ios/scripts/check_info_plist.py` + negative-control step
- [ ] `ios/PhotoSync/Info.plist`, `ios/project.yml`
- [ ] `docs/ios-phase1-device-test.md` (checklist in the style of `docs/iphone-test-checklist.md`), `.planning/phases/01-build-install-and-pair/01-GATE.md` (go/no-go + minutes table)
- [ ] `.gitattributes`, `.gitignore` additions
- [ ] Framework install: none (Swift and Node are preinstalled on the runner)

## Security Domain

`security_enforcement` is enabled (absent = enabled), ASVS level 1.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes (pairing) | Server-side: 8 chars from a 31-symbol alphabet, 10-minute TTL, 8 failures per 5 min per IP, constant-time compare, token hashed at rest (read in `server/security.ts`). App must send the code only to the address the user typed and never log it |
| V3 Session Management | limited | Long-lived bearer device key; revoke by deleting the device in the dashboard; app treats 401 as "re-pair" |
| V4 Access Control | no new surface | Server unchanged; app uses sender API only, never `/admin` |
| V5 Input Validation | yes | Strict hand-written `ServerAddress` parser (http only, host + optional port, reject empty/other schemes); server already validates bodies with Zod |
| V6 Cryptography | no hand-rolled crypto | Token generated server-side; app stores it, does not derive anything |
| V7 Error handling and logging | yes | `DeviceKey` redacting type + `RunLog` scrubber + contract test asserting the real token is absent; never log `Authorization`; log NSError codes not secrets |
| V8 Data protection | yes | Keychain `AfterFirstUnlockThisDeviceOnly`, no access group, no iCloud sync; log file lives in `Documents` which is visible via Files, so it must be secret-free |
| V9 Communications | accepted risk | Plain HTTP on the home LAN by project constraint (HTTPS pinning deferred, CONV-04); token and code cross the LAN in clear text. Document in the device sheet |
| V14 Configuration | yes | No entitlements, minimal ATS (`NSAllowsLocalNetworking` only), no `NSAllowsArbitraryLoads`, workflows with `permissions: contents: read`, first-party actions only, XcodeGen pinned by version and sha256, artifact retention 7 days, no secrets in CI (none needed) |

### Known Threat Patterns for this stack
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Device key written to a log that the user then exports/pastes | Information disclosure | Redacting type, scrubber, contract-test assertion, no header logging |
| Wrong/hostile server at the typed address receives the pairing code | Spoofing / Info disclosure | Accepted for a typed-address v1 (single user, home LAN); code is one-time and rotates on use |
| Brute-forcing the pairing code over the LAN | Elevation | Server throttle (8 per 5 min per IP) and 10-minute rotation; unchanged |
| LAN eavesdropping on plain HTTP | Information disclosure | Accepted by constraint; deferred HTTPS pinning (CONV-04) |
| Supply-chain tampering with the build tool | Tampering | Pinned XcodeGen version + sha256, first-party actions only |
| Workflow/permission creep (write tokens, secrets) | Elevation | `contents: read`, no secrets, private repo, single owner |
| Unsigned `.ipa` artifact exposure | Information disclosure | Contains no secrets; private repo; 7-day retention |
| Keychain item lost -> silent half-paired state | Denial of service | Explicit "re-pair needed" state, logged at launch |

## Sources

### Primary (HIGH confidence)
- Repository files read this session: `server/app.ts` (lines 60-217, 355-473), `server/security.ts` (25-120), `server/main.ts`, `server/config.ts`, `shared/schemas.ts`, `tests/helpers.ts`, `package.json`, `vitest.config.ts`, `tsconfig.json`, `.gitignore`, `docs/api.md`; ran `npm test` (49 pass, 17 s) and `npm run typecheck` (pass)
- `.planning/ROADMAP.md`, `REQUIREMENTS.md`, `STATE.md`, `PROJECT.md`, `research/SUMMARY.md`, `STACK.md`, `ARCHITECTURE.md`, `PITFALLS.md` (project-level research, built on and corrected where noted)
- Apple docs (markdown form via `.md` suffix): NSAllowsLocalNetworking; Preventing Insecure Network Connections; TN3179 Understanding local network privacy; UIFileSharingEnabled; LSSupportsOpeningDocumentsInPlace; ShareLink; kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; Sharing access to keychain items among a collection of apps
- AltStore source: `AltServer/Devices/ALTDeviceManager+Installation.swift` (bundle ID rewrite, App ID reuse), `AltStore/Operations/ResignAppOperation.swift` (Info.plist keys touched; no file-sharing keys), AltSign `ALTSigner.mm` (entitlements = profile entitlements only) from raw.githubusercontent.com
- swift-corelibs-foundation `URLSession.swift` (async APIs, `@unchecked Sendable`), `URLSessionConfiguration.swift` (`waitsForConnectivity` unavailable), GitHub code search (`allowsExpensiveNetworkAccess`, `allowsConstrainedNetworkAccess`: 0 results)
- GitHub runner-images READMEs: macos-26-arm64 (image 20260907.0351.1) and Ubuntu2404 (image 20261004.327.1); runner-images repository table of labels; runner-images issues 14748/14747 (ubuntu-latest -> 26.04 in Nov 2026)
- `gh api`: XcodeGen 2.46.0 release and asset digests, repo stats; latest releases of `actions/checkout`, `upload-artifact`, `setup-node`, `cache`; `gh auth status` scopes
- GitHub docs: billing reference (rates, per-job rounding), Actions billing concepts (Free 2,000 min, 500 MB), REST "Get workflow run usage" (closing down)
- XcodeGen `Docs/ProjectSpec.md` (info, packages, settings, INFOPLIST_FILE)

### Secondary (MEDIUM confidence)
- Apple Developer Forums thread 788044 (DTS: ATS vs Local Network privacy errors; iOS 18 bug fixed in 18.6)
- AltStore FAQ pages: activating apps (deactivation backs up data; 3 active sideloaded apps), error codes (1007, 2007, 2009, 1009, 3009, 3010, 3011, 3013), App IDs (10 per week)
- `anazhd/ipa-builder` (unsigned `.ipa` on GitHub macOS runners with `CODE_SIGNING_ALLOWED=NO` for Sideloadly/AltStore)

### Tertiary (LOW confidence, validate in the first builds)
- Forum/community material on unsigned archives (as in STACK.md); the rest of the Assumptions Log (A1-A19)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH for versions/labels/billing rates (read today); MEDIUM for how XcodeGen, the local package and Xcode 26.6 behave together
- Architecture: HIGH for the CI/Linux split and server contract (code read); MEDIUM for app-target adapters (uncompiled)
- Pitfalls: HIGH for Linux/Darwin API gaps and ATS/LNP facts (primary sources); MEDIUM for AltStore refresh effects (source-derived reasoning, device test pending)

**Research date:** 2026-10-11
**Valid until:** about 2026-10-25 for runner images, Actions versions and billing text (fast-moving: Ubuntu label changes in November, macOS images update frequently); Apple/AltStore behaviours 30+ days.
