---
phase: 01-build-install-and-pair
plan: 03
subsystem: ios-core
tags: [swift, swift-testing, pairing, keychain-seam, runlog, contract-tests]

requires:
  - phase: 01-build-install-and-pair
    provides: "PhotoSyncCore package, ServerClient, DeviceKey, ServerAddress (01-02)"
provides:
  - "DeviceKeyStoring seam with in-memory store and failure injection"
  - "PairingStore: pairing.json schema 1, no secret field, strict re-validation on load"
  - "RunLog actor: secret and Bearer-token scrubbing, line-atomic writes, rotation"
  - "PairingFlow: restore, pair (key saved first, then the record), checkConnection"
  - "Real-server contract tests for QR-link pairing, simulated relaunch, and a secret-free log"
affects: [01-04, 01-05, 01-06]

commits:
  - 7596229 feat(01-03): pair from typed text, remember the PC, keep the key out of the log
  - c6473e5 test(01-03): cover pairing.json round trip and run log scrubbing

key-files:
  created:
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/DeviceKeyStore.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/PairingStore.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/PairingFlow.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/RunLog.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Contract/PairingFlowContractTests.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Unit/PairingStoreTests.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Unit/RunLogTests.swift
  modified:
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/DeviceKey.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/HTTPTransport.swift

key-decisions:
  - "The device key is never written to pairing.json; it goes through DeviceKeyStoring only"
  - "Pairing saves the key first, then the record, so a crash between them leaves no half-paired state"
  - "URLSessionTransport no longer needs an unchecked Sendable conformance"

requirements-completed: [PAIR-02, PAIR-03, BLD-02, BLD-05, FEAS-01]

status: ci-green
---

# Plan 01-03 summary

Pairing from typed text, remembering the PC across launches, and keeping the device key out of the log.

## Verification

- CI on `c6473e5` (run 38178260660): `swift test` (unit and contract) passed, and the contract suite reached the real server.
- The first 01-03 commit (`7596229`) was green in CI (run 38169495363).

## Notes

- The two unit test files were written during 01-03 but left uncommitted. They were committed as `c6473e5` after the feature commit, so CI did not run them until that push.
