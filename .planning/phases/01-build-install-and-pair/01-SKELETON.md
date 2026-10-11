# Walking Skeleton - PhotoSync iPhone App

**Phase:** 1
**Generated:** 2026-10-11

## Capability Proven End-to-End

An AltStore-installed iPhone app, built on GitHub Actions without a Mac, takes a typed PC address and pairing code, reaches the Windows server over plain HTTP, keeps its device key in the Keychain across relaunch and an AltStore refresh, and exports a log that never contains that key.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| App framework | SwiftUI app target, Swift 5 language mode, iOS 18.0 minimum, iPhone only, `@Observable` model | Locked by the roadmap (Swift 5 for the app target) and the user's iOS 18+ phone; native, no third-party packages |
| Logic layer | Local Swift package `PhotoSyncCore`, Swift 6 mode (tools 6.0), zero dependencies, Foundation and FoundationNetworking only | All logic (address parsing, wire client, pairing flow, log, stores) compiles and is tested on a Linux runner at 1x minutes; the app target only adapts Apple APIs |
| Project generation | XcodeGen 2.46.0 (release zip, pinned sha256) generating the project on the runner; the generated project is never committed | Only workable way to define an iOS app project from Windows; pinned to avoid Homebrew surprises on a metered runner |
| Info.plist | Hand-written XML checked in at `ios/PhotoSync/Info.plist`, validated by `ios/scripts/check_info_plist.py` | Missing permission texts must fail on Linux and as the first Mac step, before any compile time is billed |
| Network | `URLSession` with `waitsForConnectivity` on and cellular off (app target only); ATS exception `NSAllowsLocalNetworking` only; no `NSAllowsArbitraryLoads` | Roadmap-locked ATS choice; Apple documents the local-networking key as the one that re-enables IP-address access on iOS 17 and later |
| Secret storage | Keychain generic password, service `photosync.device-key`, account `device-key`, after-first-unlock this-device-only, no access group, no iCloud sync | The key grants upload rights on the PC; default access group keeps it with the AltStore-stable app ID |
| Local state | `pairing.json` (non-secret facts, versioned `schema: 1`) and a launch counter in Application Support; no database | Roadmap-locked: small atomic JSON, no GRDB; keeps Files-visible Documents limited to the scrubbed log |
| Logging | `RunLog` actor writing `photosync.log` (rotated once) in Documents, secrets scrubbed by construction and by registration, stable snake_case event codes | No debugger exists; the log is the evidence channel and must be exportable (share sheet and Files) |
| CI shape | `ci.yml` on `ubuntu-24.04` for every code push (typecheck, vitest, plist gate and self-test, static iOS policy checks, `swiftc -parse`, real-server `swift test`); `ios-build.yml` on `macos-26`, manual dispatch only | Cheap-first: Linux catches everything it can; Mac minutes are scarce and every Mac build is a deliberate act |
| Install route | Unsigned `.ipa` (`CODE_SIGNING_ALLOWED=NO`) re-signed by the user's existing AltStore; one fixed bundle ID, no extensions, no entitlements | Project constraint (free, no Mac, no paid membership); fixed ID keeps one App ID and one app across refreshes |
| Directory layout | `ios/project.yml`, `ios/PhotoSync/` (app), `ios/Packages/PhotoSyncCore/` (package: `Sources`, `Tests/.../Unit`, `Tests/.../Contract`), `ios/scripts/`, `.github/workflows/`, `scripts/ci-watch.sh`, server tree unchanged | One place per concern; app target stays under 400 lines |
| Server contract | `/api/v1` unchanged; Phase 1 uses only `GET /health`, `POST /pair`, `GET /status` (and the loopback `GET /admin/pairing` from test code only) | Compatibility constraint; no server change needed for the skeleton |

## Stack Touched in Phase 1

- [x] Project scaffold (private repo, package, XcodeGen spec, plist, build/test runners, CI) - Plans 01 to 05
- [x] Routing/entry - the one real "route" is the pairing handshake against the real server (health, pair, status) - Plan 02
- [x] Persistence - one real write and one real read of both stores: Keychain item plus `pairing.json`, restored after a simulated relaunch (Linux) and a real relaunch and AltStore refresh (phone) - Plans 03, 04, 06
- [x] UI - one interactive form (address, code, Pair) wired to the flow, plus status, version and log export - Plan 04
- [x] Deployment - CI build to unsigned `.ipa`, AltStore install on the real iPhone, documented in the device checklist - Plans 05, 06

## Out of Scope (Deferred to Later Slices)

- QR scanning (PAIR-01), plain-English reachability diagnosis with Settings links (PAIR-04), editable and forgettable pairing (PAIR-05) - Phase 4
- Any PhotoKit use, library permission prompts, diagnostics screens, originals export - Phases 2 and 4 to 6
- Bonjour discovery, HTTPS pinning, background URL sessions, GRDB, change tokens, days-until-AltStore-expiry display, pushing logs to the PC dashboard - v2 or later
- Any server change (Phase 1 needs none)
- App icon, launch artwork, localisation, iPad layout

## Subsequent Slice Plan

Each later phase adds one vertical slice on top of this skeleton without altering its architectural decisions:

- Phase 2: Feasibility on the real iPhone - diagnostics screen listing stored parts per item, byte-identical original export, video upload speed, iCloud/hidden/burst behaviour (go/no-go gate)
- Phase 3: PC server upgrades - Live Photo pairing, Hidden folder, truthful already-backed-up check, resumable failed moves (Windows only)
- Phase 4: Pair and see what is missing - QR pairing, library access states, read-only count of items the PC does not have
- Phase 5: Back up photos - "Back up now" with live progress and a PC-verified result
- Phase 6: Videos, Live Photos, iCloud downloads and retry
