---
phase: 01-build-install-and-pair
plan: 04
subsystem: ios-app
tags: [swift, swiftui, xcodegen, keychain, pairing, launch-evidence]

requires:
  - phase: 01-build-install-and-pair
    provides: "PhotoSyncCore pairing flow, stores and run log (01-02, 01-03)"
provides:
  - "ios/project.yml: one application target, iOS 18, Swift 5 for the app, bundle id com.mewtcor.photosync"
  - "KeychainDeviceKeyStore: device key in the Keychain, this device only, after first unlock"
  - "AppEnvironment and AppModel: session flags for the app only, launch line, connection check, plain-English states"
  - "ContentView: pairing form, status, version and git SHA, Export log share sheet"
  - "LaunchFacts and LaunchCounter in Core, pinned by Linux tests"
affects: [01-05, 01-06]

commits:
  - 81af85b feat(01-04): app target that pairs through the Core flow
  - 7129f08 feat(01-04): launch evidence line, connection check on launch, version and log export

key-files:
  created:
    - ios/project.yml
    - ios/PhotoSync/PhotoSyncApp.swift
    - ios/PhotoSync/ContentView.swift
    - ios/PhotoSync/AppModel.swift
    - ios/PhotoSync/KeychainDeviceKeyStore.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/LaunchEvidence.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Unit/LaunchEvidenceTests.swift
  modified:
    - ios/PhotoSync/Info.plist

key-decisions:
  - "Bundle identifier com.mewtcor.photosync, chosen at the Task 1 checkpoint. Permanent: changing it creates a second App ID and orphans the key."
  - "AppEnvironment folded into AppModel.swift, keeping the app at four Swift files plus the environment type (plan allowed this)."
  - "The code field is cleared after every pairing attempt. Core does not say whether a request reached the PC, so 'after any attempt that reached the PC' cannot be honoured exactly. Cost: one re-entry after a network failure."
  - "Local Network usage text reworded to 'PhotoSync connects to your PC on this Wi-Fi network.' (carry-over from 01-03)."

requirements-completed: [PAIR-02, PAIR-03, BLD-04, BLD-05, FEAS-01]

status: ci-green-not-compiled
---

# Plan 01-04 summary

The first app that can pair: a PhotoSync target that stores its key in the Keychain, reports what it found at launch, and exports its log.

## Verification

- CI on `81af85b`: green, including `iOS static checks`, `Parse app sources` and `swift test`.
- CI on `7129f08` (run 38180301404): green. `swift test` reported 50 tests in 7 suites, including `LaunchEvidenceTests`.
- Local greps from the acceptance criteria all pass: no entitlements, no access-group or sync attributes, no Photos imports, no backup wording in app sources, app Swift is 257 lines (limit 400).

## Not verified

- **The app has not been compiled.** CI only parses the app's Swift files. The first real compile is Plan 05, on a macOS runner.
- The Info.plist check (`check_info_plist.py`) runs in CI and passed. This machine has no Python, so I did not run it locally.
- On-device behaviour is deferred to Plan 06: the Local Network prompt, the share sheet, and the layout.
