---
phase: 01-build-install-and-pair
plan: 02
subsystem: ios-core
tags: [swift, swift-testing, swiftpm, github-actions, linux, urlsession, contract-tests]

requires:
  - phase: 01-build-install-and-pair
    provides: "ci.yml with guarded Swift steps, scripts/ci-watch.sh"
provides:
  - "Package PhotoSyncCore (Swift 6, tools 6.0, no dependencies) building and testing on ubuntu-24.04"
  - "ServerClient: health(), pair(code:deviceName:), status(key:) with typed errors (server, network, unexpectedResponse, invalidInput)"
  - "DeviceKey: redacting, non-serialisable wrapper for the device key"
  - "ServerAddress.parse: strict typed-address and QR-link parser with plain-English errors"
  - "Serialized real-server contract suite ServerContractTests, FakeTransport test double"
affects: [01-03, 01-04, 01-05, 01-06]

plan_head_before: ea50a5c69eb40bfc0ae41e4316c0d58822297865
plan_head_after: 4db10047a022e77c4f7206613585b602f473b706

actuals:
  tokens: 9900
  tasks: 2
  commits: 4

tech-stack:
  added: []
  patterns:
    - "Core is Linux-testable: HTTPTransport seam, no Darwin-only session options"
    - "One serialized contract suite; later plans extend ServerContractTests rather than add a suite"
    - "Secrets wrapped at the moment they enter the app (DeviceKey), single reveal accessor"

key-files:
  created:
    - ios/Packages/PhotoSyncCore/Package.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/HTTPTransport.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/DeviceKey.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/ServerClient.swift
    - ios/Packages/PhotoSyncCore/Sources/PhotoSyncCore/ServerAddress.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Contract/ServerContractTests.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Unit/FakeTransport.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Unit/ServerClientTests.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Unit/ServerAddressTests.swift
    - ios/Packages/PhotoSyncCore/Tests/PhotoSyncCoreTests/Unit/DeviceKeyRedactionTests.swift
  modified:
    - scripts/ci-watch.sh

key-decisions:
  - "Swift Testing works under swift test on the runner (Swift 6.4); no XCTest fallback needed"
  - "Wire types live as a banner section in ServerClient.swift (recorded deviation from PATTERNS' separate Wire.swift)"
  - "NetworkFailure maps URLError explicitly to domain NSURLErrorDomain and code rawValue, with an NSError fallback for other errors, so Linux and Darwin report the same domain and code"

requirements-completed: [BLD-02, PAIR-02]

coverage:
  - id: D1
    description: "Swift on Linux pairs with the unmodified server: health, pair with a freshly fetched code, status with the issued key (chunkSize 8388608, non-empty serverName, deviceName Contract Test)"
    requirement: BLD-02
    verification:
      - kind: integration
        ref: "ServerContractTests.healthIdentifiesPhotoSync, pairThenStatusWithTheIssuedKey in CI run 38168846425 (swift test: 25 tests in 4 suites passed)"
        status: pass
    human_judgment: false
  - id: D2
    description: "Wrong code is server 403 bad_pairing_code, unknown key is 401 unauthorized, closed port is a network error in NSURLErrorDomain; exactly one wrong-code request in the whole run"
    requirement: BLD-02
    verification:
      - kind: integration
        ref: "ServerContractTests.wrongPairingCodeIsRefused, unknownKeyIsUnauthorized, closedPortIsANetworkError; grep -ro ZZZZZZZZ in Tests prints 1"
        status: pass
    human_judgment: false
  - id: D3
    description: "The CI run fails when the contract URL is missing or zero tests ran"
    requirement: BLD-02
    verification:
      - kind: unit
        ref: "contractBase() records an Issue and throws without PHOTOSYNC_CONTRACT_URL; ci.yml 'Test run with [1-9]' count check passed on the HEAD swift test log"
        status: pass
    human_judgment: true
    rationale: "The missing-URL failure path is by construction (Issue.record plus throw); no CI run was made without the variable to see it fail."
  - id: D4
    description: "DeviceKey and every ServerClientError description never contain the key text"
    requirement: PAIR-02
    verification:
      - kind: unit
        ref: "DeviceKeyRedactionTests (interpolation, describing, reflecting, dump, array/dictionary/optional, Mirror children) and ServerClientTests.errorsNeverContainTheKey"
        status: pass
    human_judgment: false
  - id: D5
    description: "ServerAddress accepts ip, ip:port, http://ip:port, the QR form and hostnames; rejects https, empty, bad ports, userinfo, query, extra path, IPv6, bad octets, leading zeros, non-ASCII hosts, each with its own error case"
    requirement: PAIR-02
    verification:
      - kind: unit
        ref: "ServerAddressTests.accepts (9 rows) and rejects (24 rows)"
        status: pass
    human_judgment: false
  - id: D6
    description: "Device names are trimmed and clamped to 80 UTF-16 code units on whole Characters before sending"
    requirement: PAIR-02
    verification:
      - kind: unit
        ref: "ServerClientTests.longEmojiNamesAreClampedToEightyUnitsWithoutSplittingACharacter"
        status: pass
    human_judgment: false
  - id: D7
    description: "Contract tests are order-independent and race-free (own fresh code per pairing test, one serialized suite, server on port 18787 with a per-run data dir)"
    requirement: BLD-02
    verification:
      - kind: integration
        ref: "@Suite(.serialized) ServerContractTests; ci.yml 'Start the real server' and 'Contract suite reached the server' steps success"
        status: pass
    human_judgment: false

duration: about 20min
completed: 2026-10-12
status: complete
---

# Phase 1 Plan 02: Swift Core package, pairing client and address parser Summary

**PhotoSyncCore (Swift 6, no dependencies) compiles and passes 25 tests on Linux in Actions, including a serialized contract suite that pairs with the unmodified Fastify server, plus a redacting DeviceKey and a strict hand-written ServerAddress parser.**

## Performance

- **Duration:** about 20 min
- **Completed:** 2026-10-11T19:41Z (shell clock, UTC)
- **Tasks:** 2 of 2
- **Files:** 10 created, 1 modified

## Accomplishments

- Task 1 (tracer): `Package.swift`, `HTTPTransport`, `DeviceKey`, `ServerClient` and `ServerContractTests` went green on the first push. The `Start the real server`, `swift test (unit + contract)` and `Contract suite reached the server` steps all executed for the first time and succeeded: `swift` is on PATH, the backgrounded server survives between steps, and unmodified `server/main.ts` runs headless on the runner. Swift version on the runner: 6.4.
- Task 2: `ServerAddress` plus the three unit suites and `FakeTransport`; green on the first push. Final test run: `Test run with 25 tests in 4 suites passed` (5 contract, 20 unit; the parameterised address table counts per row).
- Core compiles with no Darwin-only session options and never references an administration route; only the test target reads the pairing code.

## Task Commits

1. **Task 1: Pair against the real server from Swift** - `3d944d2` (feat). CI run 38168587623, success.
2. **Task 2 RED: failing tests** - `f64e7d6` (test)
3. **Task 2 GREEN: ServerAddress** - `81cf69b` (feat). CI run 38168846425, success.
4. **Fix to scripts/ci-watch.sh** - `4db1004` (fix), see Deviations.

Push-and-fix iterations used: 1 of 4 for Task 1, 1 of 4 for Task 2 (no failed run). No `ci.yml` change was needed. Swift Testing, not XCTest, is in use.

## Verification results

- `bash scripts/ci-watch.sh ci.yml` after Task 1: "ci.yml run 38168587623 succeeded".
- `bash scripts/ci-watch.sh ci.yml steps '^(Start the real server|swift test|Contract suite reached the server)' 3`: three steps, all success.
- `bash scripts/ci-watch.sh ci.yml` after Task 2: "ci.yml run 38168846425 succeeded"; `... log 'Test run with [1-9][0-9]* tests?'` exit 0 (after the script fix below), and a negative control (`Test run with 999 tests`) exit 1.
- Acceptance greps for both tasks (tools-version, no `.package(`, no Darwin-only flags, no `/admin` in Sources, `redacted` present and no Codable-family names in DeviceKey.swift, `8388608` in the contract test, one `ZZZZZZZZ`, no `URL(string` in ServerAddress.swift, `defaultPort` and 8787, required literals in each test file, `actor FakeTransport`): all pass.

## TDD note

Task 2 carries `tdd="true"`. The RED commit (`f64e7d6`) contains the tests before any `ServerAddress` exists, and the GREEN commit (`81cf69b`) follows; a `test(01-02)` then `feat(01-02)` pair is in the log. **The RED step was not executed as a run**: there is no Swift toolchain on this PC, and a CI run of the RED commit would only show a compile error for the missing `ServerAddress` type, which the gate classifies as a load failure rather than valid RED. The classifier (`check tdd-red-evidence`) was therefore not run and no RED evidence record exists; the semantic assessment is that RED was by construction (the tests reference a type that did not exist). The plan is `type: execute`, not `type: tdd`, so no plan-level gate applies.

## Decisions Made

- Swift Testing is used as planned and works under `swift test` on Swift 6.4 on `ubuntu-24.04`.
- `NetworkFailure(_:)` handles `URLError` explicitly (domain fixed to `NSURLErrorDomain`, code from `URLError.code.rawValue`) so Linux and iPhone report the same domain and code; other errors go through `NSError`.
- `URLSessionTransport` is `@unchecked Sendable` because `URLSession` is not guaranteed `Sendable` on corelibs-foundation; it holds one immutable session.
- `pair` rejects an empty code and an empty (or all-whitespace) name with `.invalidInput` before touching the transport; a name that is empty after clamping (a single Character wider than 80 units) is also rejected.
- Public `init`s were added to the public wire types (not in the interfaces block) so later plans' tests and previews can construct them; the exported API otherwise matches the interfaces block exactly.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `ci-watch.sh log` mode reported "no match" on a large log**
- **Found during:** Task 2 verify (`ci-watch.sh ci.yml log 'Test run with [1-9][0-9]* tests?'`)
- **Issue:** the script piped the captured log into `grep -q`; `grep -q` exits on the first match, `printf` dies of SIGPIPE on the 80 KB log, and `pipefail` turned a present line into a failure. The script from Plan 01 had only ever matched small logs.
- **Fix:** read the captured log through a here-string (`grep -Eq "$REGEX" <<<"$LOG"`). Verified with a positive and a negative control.
- **Files modified:** `scripts/ci-watch.sh`
- **Commit:** `4db1004`

### Plan-process deviations

- **File layout:** wire types are a section inside `ServerClient.swift` instead of a separate `Wire.swift`, as the plan itself recorded.
- **No RED run** for Task 2 (see TDD note).
- **`HEAD` CI run:** the last commit (`4db1004`) changes only `scripts/ci-watch.sh`, which CI does not execute, and was verified locally against run 38168846425, the run for the last source commit `81cf69b`.

**Total deviations:** 1 auto-fixed (bug), 3 process notes. **Impact:** none on scope.

## Auth gates

None.

## Known Stubs

None.

## Known gaps carried forward

- Nothing here has run on a Darwin toolchain: `URLSessionTransport` and `NetworkFailure` behave as written on Linux, and the iPhone build in Plan 04 is the first Darwin compile of Core under Xcode's Swift.
- The missing-`PHOTOSYNC_CONTRACT_URL` failure path was not exercised in CI (it is by construction).
- `ServerAddress` does not lower-case hosts; `DESKTOP-AB12` keeps its case. Harmless to URL loading, noted for the Plan 03 pairing store (compare hosts case-insensitively if it ever matters).

## Threat Flags

None. The only new network surface is the client side of existing `/api/v1` routes; the test-only loopback pairing read lives in the test target (T-01-09, accepted). T-01-06 (key redaction), T-01-07 (strict parser), T-01-08 (single wrong code per run) and T-01-SC (no packages) are implemented and covered by tests or greps.

## Self-Check: PASSED

- Files present: all 10 created files listed in key-files, plus the modified `scripts/ci-watch.sh`.
- Commits reachable from HEAD: `3d944d2`, `f64e7d6`, `81cf69b`, `4db1004`.
