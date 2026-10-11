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

Task IDs are `{plan}-T{task}` (plan numbers 01 to 06; tasks numbered as in each PLAN.md, where a checkpoint also takes a number).
Every Swift or workflow check is verified through `bash scripts/ci-watch.sh ci.yml` (pushes HEAD, waits for the Linux run, exits non-zero unless it succeeded); its `steps` and `log` modes assert individual steps and log lines.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-01-T2 | 01 | 1 | BLD-01 | T-01-01 | Repo is private; lockfile tracked; no secret-like files tracked | smoke | `gh repo view --json isPrivate --jq .isPrivate` prints true; `git ls-files package-lock.json` | ❌ W0 | ⬜ pending |
| 01-01-T2 | 01 | 1 | BLD-02 | T-01-02, T-01-03 | Server tests run on Linux, token read-only, minutes protected | CI | `bash scripts/ci-watch.sh ci.yml` | ❌ W0 | ⬜ pending |
| 01-02-T1 | 02 | 2 | BLD-02 | T-01-06, T-01-08 | Wrong pairing code is refused (403); bad key gets 401; one wrong code per run | integration | `bash scripts/ci-watch.sh ci.yml` then `bash scripts/ci-watch.sh ci.yml log 'Test run with [1-9][0-9]* tests?'` (CI step runs `swift test --filter Contract` with `PHOTOSYNC_CONTRACT_URL`) | ❌ W0 | ⬜ pending |
| 01-01-T3 | 01 | 1 | BLD-03 | T-01-04 | Missing, blank or non-text permission string names the key and exits non-zero | unit | `python ios/scripts/check_info_plist.py --self-test` (also run in CI) | ❌ W0 | ⬜ pending |
| 01-05-T2 | 05 | 5 | BLD-03 | T-01-20, T-01-22, T-01-23 | Manual Mac build yields unsigned ipa; fails first on a bad plist | CI | `bash scripts/ci-watch.sh ios-build.yml dispatch`; `gh run download RUN -n PhotoSync-ipa`; `unzip -l` | ❌ W0 | ⬜ pending |
| 01-04-T2 | 04 | 4 | BLD-04 | T-01-16, T-01-19 | No entitlements, one bundle ID, no extensions, no Photos framework import | static | `bash scripts/ci-watch.sh ci.yml steps '^iOS static checks$' 1` | ❌ W0 | ⬜ pending |
| 01-02-T2 | 02 | 2 | BLD-05 | T-01-06 | Device key never reaches a description or dump (type-level) | unit | `bash scripts/ci-watch.sh ci.yml` (suite `DeviceKeyRedactionTests`, selectable with `swift test --filter Redaction`) | ❌ W0 | ⬜ pending |
| 01-03-T1 | 03 | 3 | BLD-05 | T-01-10 | Real server-issued token and code absent from log, pairing.json and temp files | integration | `bash scripts/ci-watch.sh ci.yml` (contract test greps the `RunLog` snapshots) | ❌ W0 | ⬜ pending |
| 01-05-T2 | 05 | 5 | BLD-06 | T-01-25 | CFBundleVersion equals the workflow run number; git SHA embedded | static | workflow step (`plutil` equality) plus `python ios/scripts/check_info_plist.py --built .ci-tmp/ipa-A/PhotoSync.ipa` | ❌ W0 | ⬜ pending |
| 01-02-T2 | 02 | 2 | PAIR-02 | T-01-07 | Strict address parsing (http only, host + optional port) | unit | `bash scripts/ci-watch.sh ci.yml` (suite `ServerAddressTests`) | ❌ W0 | ⬜ pending |
| 01-03-T1 | 03 | 3 | PAIR-02 | T-01-07 | Typed address and code pair against the real server | integration | `bash scripts/ci-watch.sh ci.yml` (extension of `ServerContractTests`) | ❌ W0 | ⬜ pending |
| 01-03-T2 | 03 | 3 | PAIR-03 | T-01-11, T-01-13 | Key stored via a single seam; corruption gives "re-pair needed" | unit (fake store) | `bash scripts/ci-watch.sh ci.yml` (suites `PairingStoreTests`, `PairingFlowTests`) | ❌ W0 | ⬜ pending |
| 01-04-T2 | 04 | 4 | PAIR-03 | T-01-14 | Keychain item after-first-unlock this-device-only, no access group, no sync | static | source greps in the task acceptance criteria | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ios/Packages/PhotoSyncCore/Package.swift` + `Tests/PhotoSyncCoreTests/{Unit,Contract}` (ServerAddress, DeviceKey redaction, RunLog scrub/rotate, ServerClient with fake transport, PairingStore, contract)
- [ ] `.github/workflows/ci.yml` and `.github/workflows/ios-build.yml`
- [ ] `ios/scripts/check_info_plist.py` + negative-control CI step
- [ ] `ios/PhotoSync/Info.plist`, `ios/project.yml`
- [ ] `docs/ios-phase1-device-test.md` (Plan 06 T1) and `.planning/phases/01-build-install-and-pair/01-GATE.md` (Plan 05 T3 skeleton, Plan 06 T3 completion): go/no-go + minutes table
- [ ] `scripts/ci-watch.sh` (Plan 01 T2): push-and-wait helper used by every verify command in this phase
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
