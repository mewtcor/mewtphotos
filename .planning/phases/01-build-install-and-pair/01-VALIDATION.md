---
phase: "01"
slug: "build-install-and-pair"
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
status: draft
nyquist_compliant: false
wave_0_complete: false
created: "2026-10-11"
---

# Phase 01 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: `01-RESEARCH.md` § Validation Architecture.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Vitest 5.0.3 (server, existing); Swift Testing via `swift test` on `ubuntu-24.04` (PhotoSyncCore); Python plist gate with a CI negative control; GitHub Actions as the harness; human device checklist |
| **Config file** | `vitest.config.ts` (existing); `ios/Packages/PhotoSyncCore/Package.swift` (Wave 0); `.github/workflows/ci.yml` (Wave 0) |
| **Quick run command** | `npm test && npm run typecheck && python ios/scripts/check_info_plist.py ios/PhotoSync/Info.plist` |
| **Full suite command** | `git push` then `gh run watch --exit-status` (the `ci.yml` run), plus a manual `ios-build.yml` run |
| **Estimated runtime** | ~60 seconds local; a few minutes for the Linux CI job |

---

## Sampling Rate

- **After every task commit:** Run the quick run command; for Swift/YAML edits, push and `gh run watch --exit-status` (Linux job, 1x minutes)
- **After every plan wave:** A green `ci.yml` run on the pushed commit
- **Before `/gsd-verify-work`:** Green `ci.yml`, at least two successful `ios-build.yml` runs with recorded minutes, and the signed-off device checklist written as the go/no-go note
- **Max feedback latency:** 60 seconds local; one Linux CI run for Swift

---

## Per-Task Verification Map

Task IDs are assigned by the planner; this map is keyed by requirement until plans exist.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | TBD | BLD-01 | — | Repo is private; lockfile tracked | smoke | `gh repo view --json isPrivate` ; `git ls-files package-lock.json` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BLD-02 | — | N/A | CI | `gh run list --workflow ci.yml --limit 1 --json conclusion` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BLD-02 | — | Wrong pairing code is refused (403); bad key gets 401 | integration | `swift test --filter Contract` with `PHOTOSYNC_CONTRACT_URL` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BLD-03 | — | N/A | unit | `python ios/scripts/check_info_plist.py <stripped copy>` exits non-zero and names the key | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BLD-03 | — | N/A | CI | `gh workflow run ios-build.yml`; `gh run download -n PhotoSync-ipa`; `unzip -l` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BLD-04 | TBD | No entitlements, one bundle ID, no extensions | static | CI step fails on any `*.entitlements` file or entitlement/extension keys in `project.yml` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BLD-05 | TBD | Device key never reaches the log (type-level) | unit | `swift test --filter Redaction` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BLD-05 | TBD | Real server-issued token absent from the log | integration | contract test greps the `RunLog` snapshot | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BLD-06 | — | N/A | static | plist gate on the built plist asserts `CFBundleVersion` is the run number | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | PAIR-02 | TBD | Strict address parsing (http only, host + optional port) | unit + integration | `ServerAddress` parse table tests; contract pair | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | PAIR-03 | TBD | Key stored in Keychain only; corruption gives "re-pair needed" | unit (fake store) | `PairingStore` round trip / corruption tests | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ios/Packages/PhotoSyncCore/Package.swift` + `Tests/PhotoSyncCoreTests/{Unit,Contract}` (ServerAddress, DeviceKey redaction, RunLog scrub/rotate, ServerClient with fake transport, PairingStore, contract)
- [ ] `.github/workflows/ci.yml` and `.github/workflows/ios-build.yml`
- [ ] `ios/scripts/check_info_plist.py` + negative-control CI step
- [ ] `ios/PhotoSync/Info.plist`, `ios/project.yml`
- [ ] `docs/ios-phase1-device-test.md` and `.planning/phases/01-build-install-and-pair/01-GATE.md` (go/no-go + minutes table)
- [ ] `.gitattributes`, `.gitignore` additions
- [ ] Framework install: none (Swift and Node are preinstalled on the runner)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Install-over keeps one icon and its data | BLD-04 | Needs AltStore and the real iPhone | Device checklist step in `docs/ios-phase1-device-test.md` |
| Log export through share sheet or Files | BLD-05 | iOS share sheet cannot be driven from CI | Device checklist step |
| Version and build shown in the app | BLD-06 | Needs the installed build | Read the screen, compare with the CI run number |
| Billed Mac minutes recorded for at least 2 builds | BLD-07 | Read from the GitHub Usage report | Fill the table in `01-GATE.md` (run id, wall seconds, billed minutes) |
| Plain HTTP reaches the PC; key survives relaunch and AltStore refresh | FEAS-01 | No simulator, no Mac | Launch-evidence log blocks before/after refresh; PC dashboard shows the device and last-seen |
| Typed address + code pairs; pairing remembered | PAIR-02, PAIR-03 | Real Keychain and LAN | Pair, quit, relaunch, confirm still paired |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s local
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
