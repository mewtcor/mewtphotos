# Phase 1: Build, Install and Pair - Pattern Map

**Mapped:** 2026-10-11
**Files analyzed:** 27 new/modified
**Analogs found:** 8 / 27 (all Swift, YAML, plist and Python files have no in-repo analog)

Note: the existing server/shared/tests/docs files are currently untracked in git (`??`); paths are as they exist on disk. They are the only code in the repo. No Swift, `.github/`, `ios/` exist. For anything without an analog the planner should use the RESEARCH.md code examples (Info.plist, project.yml, Package.swift, ios-build.yml, ci.yml skeleton, check_info_plist.py, Keychain adapter, transport, contract test) and the shipped wire contract below.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `.gitignore` (modify) | config | n/a | `.gitignore` (itself) | exact (append) |
| `.gitattributes` (new) | config | n/a | none | no analog |
| `.github/workflows/ci.yml` | config (CI) | batch | none (`package.json` scripts are the commands it calls) | no analog |
| `.github/workflows/ios-build.yml` | config (CI) | batch | none | no analog |
| `ios/project.yml` | config | n/a | none | no analog |
| `ios/MewtPhotos/Info.plist` | config | n/a | none | no analog |
| `ios/scripts/check_info_plist.py` | utility (gate) | transform | none (only PowerShell `scripts/start-backup.ps1` exists, different language) | no analog |
| `ios/Packages/MewtPhotosCore/Package.swift` | config | n/a | none | no analog |
| `.../Sources/MewtPhotosCore/Wire.swift` | model | request-response | `shared/schemas.ts` (PairRequest, ClientStatus, health) + `server/app.ts` 187-217 | contract-match |
| `.../ServerClient.swift` | service | request-response | `web/src/api.ts`, `web/src/uploader.ts` (JS client of same API) | role-match |
| `.../HTTPTransport.swift` | service | request-response | `web/src/api.ts` (ApiError / NetworkError mapping) | role-match |
| `.../ServerAddress.swift` | utility | transform | `web/src/Phone.tsx` (parses `#pair=CODE` fragment) | partial |
| `.../DeviceKey.swift` | model/utility | n/a | `server/security.ts` (`hashToken`, never-log-secrets rule) | partial |
| `.../PairingStore.swift` | store | file-I/O | `server/config.ts` (`loadSettings`/`saveSettings`) | partial |
| `.../RunLog.swift` | utility | file-I/O | `Ctx.log` in `server/engine.ts` / `server/app.ts` | partial |
| `.../LaunchEvidence.swift` | utility | transform | none | no analog |
| `.../Tests/MewtPhotosCoreTests/Unit/*` | test | transform | `tests/units.test.ts` | role-match |
| `.../Tests/MewtPhotosCoreTests/Contract/*` | test | request-response | `tests/helpers.ts` `startServer` + `tests/engine.test.ts` | role-match |
| `ios/MewtPhotos/MewtPhotosApp.swift`, `ContentView.swift`, `AppModel.swift`, `AppEnvironment.swift`, `KeychainDeviceKeyStore.swift` | component/store | event-driven | `web/src/Phone.tsx` (pairing + status form) | partial |
| `docs/iphone-device-checklist.md` (name TBD, Phase 1 device test) | docs | n/a | `docs/iphone-test-checklist.md` | exact style |
| README / docs updates for build + install | docs | n/a | `docs/setup-windows.md` | role-match |

## Pattern Assignments

### `.gitignore` (modify, append)

**Analog:** `.gitignore` lines 1-4 (one pattern per line, trailing slash for dirs):
```
node_modules/
web/dist/
*.log
.tmp-tests/
```
Append: `.build/`, `.swiftpm/`, `build/`, `Payload/`, `*.ipa`, `ios/MewtPhotos.xcodeproj/`, `DerivedData/`, `.DS_Store`. Do not add `package-lock.json`; BLD-01 needs it committed. Do not ignore `*.log` exceptions needed by CI; the existing `*.log` rule is fine (CI build.log is not committed).

### `ios/.../Wire.swift` (model, request-response)

**Analog:** `shared/schemas.ts` + `server/app.ts` (verbatim contract). Swift Codable structs must mirror exactly; Swift field names equal the JSON keys.

Pair request (`shared/schemas.ts:14-17`):
```ts
export const PairRequest = z.object({
  code: z.string().min(1).max(32),
  deviceName: z.string().trim().min(1).max(80),
});
```
Responses (`server/app.ts:202-217`):
```ts
app.get(`${API}/health`, async () => ({ ok: true, name: 'mewtphotos', apiVersion: 1 }));
...
return { token, deviceId: id };
...
return { deviceName: device.name, serverName: os.hostname(), chunkSize: CHUNK_SIZE, concurrency: settings.concurrency, maxFileBytes: settings.maxFileBytes };
```
`ClientStatus` (`shared/schemas.ts:153`): `deviceName, serverName, chunkSize, concurrency, maxFileBytes` (all non-optional, numbers are ints).
Error body (`server/app.ts:187-189`): `{ error: <snake_case code>, message: <human text>, ...extra }`. Swift `ServerErrorBody` must decode `error` and `message` and tolerate extra keys. Known codes for Phase 1: `bad_pairing_code` (403), `too_many_attempts` (429), `unauthorized` (401), `forbidden_network` (403), `invalid_request` (400).
Bounds to enforce client-side: deviceName 1-80 chars trimmed; code trimmed only (server upper-cases and strips non-alphanumerics).

### `ios/.../ServerClient.swift` and `HTTPTransport.swift` (service, request-response)

**Analog:** `web/src/api.ts` (error classification: server errors to `ApiError` carrying status/code/extra, network failures to `NetworkError`; retry keys on class, not message text). Read that file when planning; mirror its two-class split as two Swift error cases (`.server(status, code, message)` and `.network(domain, code, underlying)`).

Routes and auth: `GET {base}/api/v1/health` (no auth), `POST {base}/api/v1/pair` JSON body (no auth), `GET {base}/api/v1/status` with header `Authorization: Bearer <token>` (`server/app.ts:164-167` `requireDevice`; 401 `unauthorized` when missing/unknown).

Platform rule (RESEARCH Pitfall 3): no `waitsForConnectivity`, `allowsExpensiveNetworkAccess`, `allowsConstrainedNetworkAccess` in Core; `URLSessionTransport(session:)` takes a prepared session; those settings go in the app's `AppEnvironment.swift`. Use `#if canImport(FoundationNetworking) import FoundationNetworking #endif`. Build URLs by manual host/port parse then `URLComponents`, never `URL(string:)` on user input.

### `ios/.../ServerAddress.swift` (utility, transform)

**Analog:** the QR URL form produced by `server/app.ts:360-366`:
```ts
const url = lanUrl() && `${lanUrl()}/#pair=${code}`;
```
Parser must accept `ip`, `ip:port`, `http://ip:port`, and `http://ip:port/#pair=CODE` (default port 8787 per `MEWTPHOTOS_PORT` in `server/main.ts`). Unit tests copy the style of `tests/units.test.ts` (table of input and expected output).

### `ios/.../DeviceKey.swift`, `RunLog.swift` (utility)

**Analog (rule):** `server/security.ts` stores only a SHA-256 of tokens (`hashToken`) and `CLAUDE.md` logging rule: "Never log secrets: tokens, pairing codes, or the raw Authorization header." Log code convention from `ctx.log`: stable snake_case `code` per event (`paired`, `verify_failed`); reuse that shape for `RunLog` lines (level, code, message). Contract test must grep the produced log for the real token and fail if found (BLD-05).

### `ios/.../PairingStore.swift` (store, file-I/O)

**Analog:** `server/config.ts` `loadSettings` / `saveSettings` (single small JSON blob, defaults filled when absent). Swift version: Codable struct, `Data.write(to:options:.atomic)`, return nil when file absent (mirrors "return `null` for not found"). Only non-secret fields (server URL, deviceId, deviceName, serverName); token goes to Keychain.

### `ios/MewtPhotos/*.swift` app target (component, event-driven)

**Analog:** `web/src/Phone.tsx` for screen flow: enter address and code, Pair, then show "Connected to {serverName}", persisted pairing reloaded on launch, errors shown as the server's `message` text (the server messages already say what to do next). Show version and build (BLD-06) from `CFBundleShortVersionString`, `CFBundleVersion`, `MewtPhotosGitSHA`. Keychain adapter and transport shapes: RESEARCH.md "Keychain adapter" (line 588) and "Core transport + client shape" (line 614). Keep app target under ~400 lines.

### Tests: `Tests/MewtPhotosCoreTests/Unit` (test, transform)

**Analog:** `tests/units.test.ts` (pure-function tables; SHA-256 checked against a reference implementation, i.e. test against an independent oracle). Swift Testing, one file per Core type.

### Tests: `Tests/MewtPhotosCoreTests/Contract` (test, request-response)

**Analog:** `tests/helpers.ts` `startServer` lines 27-41: how the real server is stood up and a code fetched.
```ts
const built = await buildApp({ db, port: 0, lanIp: null, webDir: path.join(root, 'no-web'), ...options });
const { app, pairing } = built;
...
const res = await app.inject({ method: 'POST', url: `${API}/pair`, remoteAddress: PHONE_IP, payload: { code: pairing.current().code, deviceName: 'Test iPhone' } });
token = (res.json() as { token: string }).token;
```
Swift contract test does the same over real HTTP: read `code` from `GET /api/v1/admin/pairing` (loopback, `Host: 127.0.0.1:<port>`), then `ServerClient.pair`, `status`, one wrong-code case (`bad_pairing_code`, max one; throttle is 8 per 5 min per IP). Base URL from env `MEWTPHOTOS_CONTRACT_URL`; when `CI=true` and the var is missing, fail rather than skip. Fallback if `server/main.ts` misbehaves on Linux: `tests/contract/serve.ts` copying lines 27-41 of `tests/helpers.ts` (TS conventions: `.ts` import extensions, `import type`, named exports, purpose header comment, no console in library code).

### `.github/workflows/ci.yml` / `ios-build.yml`

No in-repo analog. Commands to call come from `package.json` scripts (lines 10-17): `npm run typecheck` (`tsc --noEmit`), `npm test` (`vitest run`), server start `node --disable-warning=ExperimentalWarning server/main.ts` (`npm start`). Env: `MEWTPHOTOS_PORT`, `MEWTPHOTOS_DATA_DIR` (do not set `MEWTPHOTOS_HOST`, per RESEARCH Pitfall 9). Use the skeletons in RESEARCH.md lines 215-254 and 504-547. Pin `ubuntu-24.04` and `macos-26`.

### `docs/iphone-device-checklist` (docs)

**Analog:** `docs/iphone-test-checklist.md` lines 1-16: title, one-paragraph purpose, "Record the iOS version: ____ iPhone model: ____" line, numbered `## N. Section` headings with `- [ ]` items, a results table where outcomes need recording. For Phase 1 sections: install via AltStore, pair, relaunch, AltStore refresh then relaunch (FEAS-01 evidence: diff of launch blocks), log export, Mac-minute record (BLD-07). Include the warning "do not mash Pair with a wrong code" (Pitfall 10).

## Shared Patterns

### Error shape and codes
**Source:** `server/security.ts` `HttpError(status, code, message, extra?)`, `server/app.ts:187-189`
**Apply to:** `Wire.swift`, `ServerClient.swift`, ContentView error text. Switch on `error` code, display `message`.

### Never expose secrets
**Source:** `.claude/CLAUDE.md` "Logging" section; `server/security.ts` `hashToken`
**Apply to:** `DeviceKey`, `RunLog`, `AppModel`. Redact by type, scrub known secrets from every log line, never log headers.

### File header comments and naming
**Source:** `.claude/CLAUDE.md` "Code Style" (a one or two line purpose comment opens each file; section banners `// ---- name ----`; `/** */` docs on non-obvious exports). Apply the same to Swift (`///`) and Python files.

### Truthfulness
Phase 1 shows no backup state. Do not add any "backed up" label; it comes only after `verified` or `duplicate` in later phases.

### Safety / scope
No server change in Phase 1. If one appears necessary, it must be additive and covered by `tests/engine.test.ts`-style tests.

## No Analog Found

| File | Role | Data Flow | Reason |
|---|---|---|---|
| `.gitattributes` | config | n/a | none exists |
| `.github/workflows/ci.yml`, `ios-build.yml` | CI config | batch | no `.github/` directory |
| `ios/project.yml` | XcodeGen spec | n/a | no iOS project |
| `ios/MewtPhotos/Info.plist` | plist | n/a | no iOS project |
| `ios/scripts/check_info_plist.py` | gate script | transform | no Python in repo (use RESEARCH.md line 560) |
| `ios/Packages/MewtPhotosCore/Package.swift` | Swift package | n/a | no Swift in repo |
| `KeychainDeviceKeyStore.swift`, `AppEnvironment.swift`, `LaunchEvidence.swift` | Apple adapters | n/a | no Swift; use RESEARCH.md lines 588-662 |

## Metadata

**Analog search scope:** `server/`, `shared/`, `web/src/`, `tests/`, `docs/`, `scripts/`, root config files; confirmed no `*.swift`, `.github/`, `ios/`
**Files read directly:** `shared/schemas.ts` (grep), `server/app.ts` (grep + RESEARCH verbatim excerpts), `tests/helpers.ts`, `docs/iphone-test-checklist.md`, `.gitignore`, `package.json`, RESEARCH.md lines 1-547 (remaining lines 548-842 hold Swift/Python snippets, validation and security sections; planner should read them)
**Not read in detail (planner should open):** `web/src/api.ts`, `web/src/Phone.tsx`, `server/security.ts`, `server/config.ts`, `tests/units.test.ts`; excerpts above for these rely on CLAUDE.md and RESEARCH descriptions
**Tracked-source gate:** all cited analogs are under `server/ shared/ web/ tests/ docs/`; they are untracked (`??`) but are original source, not mirrors
**Pattern extraction date:** 2026-10-11
