<!-- GSD:project-start source:PROJECT.md -->

## Project

**PhotoSync**

PhotoSync backs up an iPhone's photos and videos to a Windows PC over the home Wi-Fi, with no cloud
service and no cost. A Windows server (already built) receives, verifies and files the media; today
the phone side is a Safari page. This project adds a native iPhone app so that one tap backs up
everything new as untouched originals. It is a personal tool for one user, one iPhone and one PC.

**Core Value:** Every photo and video on the iPhone reaches the PC as its untouched original — including both halves
of Live Photos — and nothing is ever reported as backed up unless the PC has verified it.

### Constraints

- **Cost**: Free — no paid developer membership, no Mac purchase or rental. Why: stated project goal.
- **Build**: iOS builds run on GitHub Actions macOS runners from a private repository. Why: no Mac; free allowance for private repos is limited (roughly 20–40 builds a month, to be checked), so builds must be few and deliberate.
- **Install**: Unsigned `.ipa` installed and refreshed by AltStore with a free Apple ID (7-day expiry, limited app count). Why: only free install route from Windows.
- **Debugging**: No on-device debugger. Why: no Mac. The app needs good in-app logging and a way to export logs from day one.
- **Compatibility**: Reuse `/api/v1` as it stands; server changes must be small, additive and covered by the existing test suite. Why: the PC side is working and tested.
- **Platform**: iOS 18+ on the phone, Windows 11 on the PC. Why: the user's actual devices.
- **Network**: Plain HTTP on the local network (ATS local-networking exception). Why: HTTPS pinning is deferred.
- **Safety**: Read-only access to the photo library in effect — never delete or modify assets. Why: this is a backup tool; the phone holds the only other copy.
- **Truthfulness**: Never show an item as backed up unless the server returned `verified` or `duplicate`. Why: core value.
- **Tech stack**: Swift / SwiftUI / PhotoKit / URLSession with as few third-party packages as possible. Why: every dependency lengthens CI builds and cannot be debugged locally.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->

## Technology Stack

## Languages

- TypeScript 7.0.2 (`typescript` devDependency) - all server code (`server/*.ts`), shared schemas (`shared/*.ts`), web UI (`web/src/*.ts`, `web/src/*.tsx`), and tests (`tests/*.ts`). Strict mode, `noEmit` (see `tsconfig.json`).
- TSX/React - dashboard and phone pages (`web/src/Dashboard.tsx`, `web/src/Phone.tsx`, `web/src/main.tsx`).
- CSS - `web/src/styles.css` (single stylesheet, supports light and dark via `color-scheme`).
- HTML - `web/index.html` (Vite entry), `web/dist/index.html` (built output, committed to working tree but git-ignored).
- PowerShell 5.1+ - launcher `scripts/start-backup.ps1`, invoked by `Start Backup.cmd`. Also shells out to `powershell.exe` at runtime to read the Windows Pictures known folder (`server/config.ts`).
- Batch - `Start Backup.cmd` (double-click entry point).

## Runtime

- Node.js >= 22.18 (declared in `package.json` `engines`). Installed locally: v24.16.0.
- The server runs TypeScript directly with Node's type stripping: `node --disable-warning=ExperimentalWarning server/main.ts` (no build step for the server). The `--disable-warning` flag suppresses the Node warning for experimental type stripping.
- Uses Node built-ins only for persistence and crypto: `node:sqlite` (`DatabaseSync`, `server/db.ts`), `node:crypto`, `node:net` (`BlockList` for LAN address checks, `server/security.ts`), `node:child_process`, `node:fs/promises`, `node:http`.
- Target platform: Windows 11 (launcher, `LOCALAPPDATA`, PowerShell, `cmd /c start`). Code also has non-Windows fallbacks (`os.homedir()`), but the product is Windows-only in practice.
- Browser runtime for the phone: iOS Safari (XHR uploads, `localStorage`). No service worker or PWA manifest is present; `web/index.html` sets `apple-mobile-web-app-capable` meta tags for Add to Home Screen.
- npm (version not pinned; `package-lock.json` present and committed to working tree).
- Lockfile: present (`package-lock.json`, lockfileVersion not verified).
- Installer invoked automatically by `scripts/start-backup.ps1` on first run (`npm install` when `node_modules` is missing).

## Frameworks

- Fastify 5.12.5 - HTTP server and routing. Built in `server/app.ts` via `buildApp()`. Versioned API under `/api/v1`.
- `@fastify/static` 10.1.6 - serves `web/dist` for the dashboard and phone pages (`server/app.ts`).
- Zod 4.6.5 - request and response validation; schemas live in `shared/schemas.ts` and are reused by the web client.
- React 19.3.0 and react-dom 19.3.0 - UI for `web/src/Dashboard.tsx` and `web/src/Phone.tsx`. Entry `web/src/main.tsx` uses `StrictMode` and `createRoot`.
- Vitest 5.0.3 - test runner. Config: `vitest.config.ts` (`environment: 'node'`, includes `tests/**/*.test.ts`, `testTimeout: 60_000`).
- Test files: `tests/engine.test.ts`, `tests/units.test.ts`, shared helpers in `tests/helpers.ts`. README reports 49 tests.
- Vite 8.3.4 - dev server and production bundler for the web UI. Config: `vite.config.ts` (`root: 'web'`, output `web/dist`, dev proxy `/api` to `http://127.0.0.1:8787`).
- `@vitejs/plugin-react` 6.1.2 - React transform for Vite.
- TypeScript 7.0.2 - `tsc --noEmit` type checking only (`npm run typecheck`). Compiler options in `tsconfig.json` include `verbatimModuleSyntax`, `erasableSyntaxOnly` (required for Node type stripping), `allowImportingTsExtensions`, `module: preserve`, `moduleResolution: bundler`, `types: ["node", "vite/client"]`.

## Key Dependencies

- `fastify` 5.12.5 - the whole HTTP surface (`server/app.ts`, `server/main.ts`).
- `exifreader` 4.48.0 - reads EXIF `DateTimeOriginal` / QuickTime creation time to choose the `YYYY\MM` folder. Read-only (`server/metadata.ts`). Only the first 1 MiB of each file is parsed.
- `qrcode` 1.5.4 - renders the pairing QR code in the terminal (`server/main.ts`) and as data for the dashboard (`server/app.ts`).
- `zod` 4.6.5 - input validation at the trust boundary (`shared/schemas.ts`, `server/app.ts`, `server/engine.ts`).
- `react` / `react-dom` 19.3.0 - web UI.
- `@fastify/static` 10.1.6 - static asset serving.
- `vite` 8.3.4, `vitest` 5.0.3, `typescript` 7.0.2, `@vitejs/plugin-react` 6.1.2.
- `@types/node` ^26.6.5, `@types/react` / `@types/react-dom` ^19.3.0, `@types/qrcode` ^1.5.6.
- SQLite via `node:sqlite` (`server/db.ts`). Chosen over `better-sqlite3` to avoid native compilation on Windows. Runs in WAL mode with `synchronous=FULL`, `foreign_keys=ON`, `busy_timeout=5000`. Experimental in Node, hence the 22.18 minimum.
- SHA-256 - `node:crypto` on the server (`server/engine.ts`, `server/security.ts`). A hand-written JavaScript implementation is used on the phone page (`shared/sha256.ts`) because Safari disables `crypto.subtle` on plain `http://` origins.
- Network address selection and private-range checks - `node:os` and `node:net` (`server/security.ts`). No third-party network libraries.
- No ORM or query builder; raw SQL in `server/db.ts` and `server/engine.ts`.
- No logging library; logging is a custom function writing to the `logs` table and `server.log` (`server/app.ts`, `server/config.ts`).
- No cloud SDKs, no HTTP client library (server-side), no auth library, no state-management library on the web side.
- No Electron or Tauri. README records a possible future Tauri sidecar only.
- No CSS framework or component library.

## Configuration

- `PHOTOSYNC_PORT` - HTTP port, default `8787` (`server/main.ts`). Set by `scripts/start-backup.ps1 -Port` for that process only.
- `PHOTOSYNC_HOST` - forces the LAN address shown to the iPhone; overrides auto-detection (`server/main.ts`).
- `PHOTOSYNC_DATA_DIR` - location of `photosync.db` and `server.log`; default `%LOCALAPPDATA%\PhotoSync` (`server/config.ts`).
- `LOCALAPPDATA` / `os.homedir()` - used only to derive the default data directory.
- Backup destination, organize-by-date toggle, per-file size limit (default 50 GB), optional storage quota (default 0 = unlimited), minimum free space (default 1 GB), concurrency (default 2), and stop-with-dashboard behavior. Defaults in `server/config.ts` (`loadSettings`). Destination default: `<Pictures>\iPhone Backup`.
- `vite.config.ts` - Vite root `web`, React plugin, output `web/dist`, `emptyOutDir: true`, dev proxy for `/api`.
- `vitest.config.ts` - Vitest node environment and test glob.
- `tsconfig.json` - strict type checking across `server`, `shared`, `web/src`, `tests`, and root `*.ts`.
- `.gitignore` - ignores `node_modules/`, `web/dist/`, `*.log`, `.tmp-tests/`.
- `npm start` - `node --disable-warning=ExperimentalWarning server/main.ts`
- `npm run build` - `vite build`
- `npm run dev:web` - `vite` dev server for the web UI
- `npm run typecheck` - `tsc --noEmit`
- `npm test` - `vitest run`
- `npm run verify` - `node --disable-warning=ExperimentalWarning server/verify-cli.ts` (re-hash stored files, `server/verify.ts`)

## Platform Requirements

- Windows 11 (documented in `docs/setup-windows.md`; the author's machine runs Node 24.16).
- Node.js 22.18 or newer. No Python, no native build toolchain (`node:sqlite` avoids compilation).
- npm for installing dependencies.
- Runs as a local foreground process on the Windows PC, started by `Start Backup.cmd`. No server hosting, no container, no service install.
- Listens on `127.0.0.1` (dashboard) and the PC's private-range LAN address (iPhone), plain HTTP only.
- Data stored under `%LOCALAPPDATA%\PhotoSync` (SQLite database and log); photos stored under the configured backup folder (default `Pictures\iPhone Backup\YYYY\MM\...`).
- Client: iOS Safari page reached via QR code; optional Apple Shortcut (`docs/ios-shortcut.md`). No native iOS code exists in the repository (`docs/ROADMAP_IOS_COMPANION.md` is a proposal only).

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

## Naming Patterns

- Server modules are lowercase single words: `server/app.ts`, `server/engine.ts`, `server/db.ts`, `server/config.ts`, `server/security.ts`, `server/metadata.ts`, `server/verify.ts`.
- Shared contract and utilities: `shared/schemas.ts`, `shared/sha256.ts`.
- Web UI: React components are PascalCase (`web/src/Dashboard.tsx`, `web/src/Phone.tsx`); non-component modules are lowercase (`web/src/api.ts`, `web/src/uploader.ts`, `web/src/main.tsx`, `web/src/styles.css`).
- Tests: `tests/<name>.test.ts` (`tests/engine.test.ts`, `tests/units.test.ts`); shared test utilities live in `tests/helpers.ts` (no `.test` suffix so Vitest does not collect it).
- CLI entry points carry a `-cli` suffix: `server/verify-cli.ts`. The server entry is `server/main.ts`.
- Note: `shared/sha256.ts` header comment refers to `tests/sha256.test.ts`, which does not exist; the SHA-256 tests are in `tests/units.test.ts`. Keep comments pointing at real files.
- camelCase verbs for actions: `createUpload`, `appendChunk`, `finishUpload`, `cancelUpload`, `sessionSummary`, `validateDestination`, `loadSettings`, `saveSettings`.
- Predicates use `is`/`has`-style or plain nouns: `isLocalNetworkAddress`, `isLoopback`, `plausibleTime`, `fileIntact`, `statOrNull`.
- Module-private helpers are not exported (`function errorCode`, `async function statOrNull`, `function classify` in `server/engine.ts`). Export only what other modules or tests use.
- Factories/builders use `build*` (`buildApp` in `server/app.ts`); starters use `start*` (`startServer` in `tests/helpers.ts`).
- camelCase for locals and module state (`lanIp`, `lastDeviceActivity`, `verifyRunning` in `server/app.ts`).
- SCREAMING_SNAKE_CASE for module constants: `GB` in `server/config.ts`, `API`, `CHUNK_SIZE`, `UPLOAD_CONTENT_TYPE`, `COVERAGE_NOTICE` in `shared/schemas.ts`, `STALE_UPLOAD_MS`, `MAX_FAILURES`, `CODE_TTL_MS` in `server/security.ts`, `K` in `shared/sha256.ts`.
- Byte and time sizes are written as arithmetic, not magic numbers: `50 * GB`, `1024 ** 3`, `10 * 60 * 1000`, `60_000` (numeric separators are used for ms values).
- Interfaces for object shapes, named with nouns: `Settings`, `Overview`, `SessionSummary`, `UploadResult`, `FileRow`, `UploadRow`, `DeviceRow`, `Ctx`, `AppOptions`, `BuiltApp`, `CaptureDate`.
- Database row types end in `Row` and mirror SQL column names in snake_case (`last_modified`, `final_path`, `e2e_verified` in `server/db.ts`). Application-facing types use camelCase.
- Zod schemas are PascalCase values that double as request contracts: `PairRequest`, `SessionCreate`, `UploadCreate`, `SettingsUpdate` in `shared/schemas.ts`. Derive TypeScript types from them with `z.infer` or `type` imports instead of duplicating.
- Type-only imports are explicit: `import type { ... }` (required by `verbatimModuleSyntax: true` in `tsconfig.json`).
- Avoid `as any`. The codebase has none; casts are localized to the thin helpers in `server/db.ts` (`get`, `all`) and to parsed JSON bodies.

## Code Style

- No formatter config is present (no `.prettierrc`, no `biome.json`). Follow the observed style:
- Module-level `// comments` open each file with a one- or two-line purpose statement, e.g. `server/engine.ts`: "The transfer engine: resumable receive -> read-back hash -> ...". Follow this for new files.
- No ESLint or other linter is configured. Correctness is enforced by the TypeScript compiler (`npm run typecheck`).
- Strictness flags in `tsconfig.json` that code must satisfy: `strict`, `noImplicitOverride`, `noFallthroughCasesInSwitch`, `erasableSyntaxOnly` (no `enum`, no parameter properties, no namespaces; use `const` objects and union types), `verbatimModuleSyntax` (explicit `import type`), `allowImportingTsExtensions` (imports use `.ts` extensions, e.g. `import { get } from './db.ts'`).
- Never use `// @ts-ignore` or `eslint-disable`; none exist. Fix the type instead.

## Import Organization

- None. Use relative paths with explicit `.ts` extensions. `tsconfig.json` uses `moduleResolution: "bundler"`.
- Server code always imports the shared contract by relative path (`../shared/schemas.ts`); the web app does the same from `web/src/` (`../../shared/schemas.ts`). Do not duplicate API types on either side.
- None. Import from the defining module directly.

## Error Handling

- Expected, user-facing failures throw `HttpError` from `server/security.ts`: `new HttpError(status, code, message, extra?)`. The `code` is a stable snake_case machine identifier (`bad_destination`, `hash_mismatch`, `unsupported_type`, `unknown_session`, `too_many_attempts`). The `message` is written for the person reading the dashboard or phone, and usually says what to do next.
- A single Fastify error handler in `server/app.ts` (`app.setErrorHandler`) converts errors to JSON `{ error, message, ...extra }`:
- Routes do not wrap handlers in try/catch just to format errors; throw and let the handler respond. Validate input at the route boundary with Zod: `const body = PairRequest.parse(req.body);`.
- Filesystem and stream errors go through `classify(ctx, filename, err)` in `server/engine.ts`, which maps Node error codes (`ENOSPC`, `EACCES`, `EPERM`) to user-facing `HttpError`s and logs a plain-language diagnosis once.
- Swallow errors only where absence is the expected answer, and say so in a comment. Examples: `statOrNull` (returns null on `ENOENT`, rethrows otherwise), `picturesDir` falling back to `~/Pictures` in `server/config.ts`, `.catch(() => [])` on `readdir` in tests.
- Background work reports failures through the structured log rather than throwing into the void: `.catch((err: unknown) => ctx.log('error', 'verify_failed', ...))` in `server/app.ts`.
- Type-narrow unknown errors with `instanceof` or a helper: `err instanceof Error ? err.message : String(err)`. Use `errorCode(err)` in `server/engine.ts` to read `code` from Node errors.
- Web client: `server`-style errors are mapped to `ApiError` (carries `status`, `code`, `extra`) and network failures to `NetworkError` in `web/src/api.ts`. Retry decisions key on these classes (`retryable` in `web/src/uploader.ts`), not on message text.
- Multi-statement database writes use `tx(db, () => ...)` from `server/db.ts` (`BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK`).
- Nothing reports success before the database commit. Keep this ordering when adding upload states.

## Logging

- Use `ctx.log` for events a user should see on the dashboard. It writes to the `logs` table and the log file, and emits a live `change` event. Pass a stable snake_case `code` (`paired`, `verify_failed`, `insufficient_space`).
- Never log secrets: tokens, pairing codes, or the raw `Authorization` header. The `Ctx.log` doc comment states this rule.
- Request logging is disabled (`logController: new LogController({ disableRequestLogging: true })`) to avoid one line per chunk. Do not re-enable it.
- `console.log` is used only in the entry points `server/main.ts` and `server/verify-cli.ts` for operator-facing output. Library and route code must not call `console`.

## Comments

- Explain *why* a constraint exists, especially for security, durability, or platform quirks. Examples in the codebase:
- Use section banners to split long files: `// ---- network ----`, `// ---- filenames ----`, `// ---- sender API ----`.
- Do not narrate obvious code.
- Use `/** ... */` on exported functions, interfaces, and fields whose behavior is not obvious from the name (`hashToken`, `resolveInside`, `Ctx.emit`, `timeouts`). One or two sentences; state guarantees and failure modes.
- Interface fields carry short `/** */` docs when the meaning is domain-specific (`AppOptions.lanIp`, `SessionCreate.libraryCount`).

## Function Design

- Prefer positional params for two or three simple values. Use an options object for optional or many params: `startServer(settings, options, reuse?)`, `verifyBackup(db, destination, onProgress?)`, `uploadFile(file, opts)`.
- Dependency injection goes through an options object with optional test seams, documented as such: `AppOptions.freeBytes` ("Test seam for disk-full behaviour"), `autoStop` timers in `server/app.ts`. Do not add seams that no test uses.
- Pass the database handle `db: Db` explicitly; there is no global connection.
- Use `Ctx` (`server/engine.ts`) to pass shared runtime state into engine functions rather than module globals.
- Return plain objects matching a shared interface (`UploadResult`, `VerifyReport`, `CaptureDate`). Return `null` for "not found" in lookup helpers (`readCaptureDate` path, `statOrNull`); use `undefined` from `get<T>` for absent DB rows.
- Async functions return `Promise<T>`; never mix callbacks with promises in new code.

## Module Design

- Named exports only. No default exports in the codebase.
- Export types alongside their producers (`export interface Settings` in `shared/schemas.ts`, `export interface Ctx` in `server/engine.ts`).
- Shared contract values (routes, limits, notices) live in `shared/schemas.ts` so the server, the web UI, and the planned native iOS client agree. Add new API constants and request schemas there first.

## Data and Validation Conventions

- All request bodies are validated with Zod schemas from `shared/schemas.ts`. Keep bounds explicit (`.max(200)`, `.int().min(0)`, `z.uuid()`).
- Hashes are lowercase hex SHA-256 validated by the shared `sha256Hex` regex. Compare hashes with `===` only after both are normalized; token and pairing-code comparison uses `timingSafeEqual` (`server/security.ts`).
- Filenames from clients pass through `sanitizeFilename` / `safeMediaFilename` and paths through `resolveInside`. Any new code that writes under the backup folder must use `resolveInside`.
- Timestamps are stored as epoch milliseconds (`INTEGER`) in SQLite; capture dates are local wall-clock ISO strings (`captured_at TEXT`).
- Database schema is a single `SCHEMA` string applied idempotently with `CREATE ... IF NOT EXISTS` in `server/db.ts`. Add new tables/indexes there; there is no migration framework.

## Adding New Code: Checklist

<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

## System Overview

```text

```

## Pattern Overview

- One process, one event loop, one SQLite file (`node:sqlite`, WAL, `synchronous=FULL`). No worker threads, no queue service.
- Server runs TypeScript directly (`node --disable-warning=ExperimentalWarning server/main.ts`); only `web/` is bundled by Vite (`vite.config.ts`, `root: 'web'`).
- Success is reported only after a durable commit: the file is fsynced, re-read and SHA-256 hashed, renamed into place, then the DB row is committed (`server/engine.ts` `finishUpload` → `place` → `commitStored`).
- Resumable offset-based protocol (tus-like `Upload-Offset` semantics) implemented in `server/engine.ts` `appendChunk`; the on-disk file size is the source of truth for resume offset.
- Two trust zones on one port: sender API accepts any private-network client with a paired device token; admin API additionally requires loopback socket and loopback `Host` header (`server/app.ts` `requireAdmin`).
- Dependency injection by options object: `buildApp(opts)` in `server/app.ts` accepts `db`, `port`, `lanIp`, `logFile`, `webDir`, `onStopRequest`, `freeBytes`. Tests replace these (`tests/helpers.ts` `startServer`).

## Layers

- Purpose: Start the server, handle "already running" detection, bind ports, handle signals, stop cleanly.
- Location: `server/main.ts`, `scripts/start-backup.ps1`, `Start Backup.cmd`
- Contains: Port probing (`GET /api/v1/health`), data-dir creation, `openDb`, `buildApp`, QR printing, SIGINT/SIGTERM/SIGHUP handling.
- Depends on: `server/app.ts`, `server/config.ts`, `server/db.ts`, `server/security.ts`
- Used by: `npm start`, the PowerShell launcher.
- Purpose: Route, authenticate, validate request bodies, map errors to JSON, push live events, host the web build.
- Location: `server/app.ts` (single file, ~470 lines, all routes registered inside `buildApp`)
- Contains: request guards (`onRequest` hook), `requireDevice`, `requireAdmin`, error handler, sender routes, admin routes, `/admin/events` SSE, static file serving and SPA fallback, LAN server creation.
- Depends on: `server/engine.ts`, `server/config.ts`, `server/db.ts`, `server/security.ts`, `server/verify.ts`, `shared/schemas.ts`
- Used by: HTTP clients (iPhone page, Shortcuts, dashboard).
- Purpose: Everything that decides whether a file is "safely stored".
- Location: `server/engine.ts`
- Contains: `createUpload` (quota/space checks, resume matching, hash-known duplicate short-circuit), `appendChunk` (offset check, idle timeout, byte limit), `finishUpload` (fsync, hash, client-hash compare, EXIF date, `utimes`), `place` (dedupe, date folder, collision-safe name, rename or cross-drive copy), `commitStored` (transactional DB write), `recover` (startup repair), `sessionSummary` (user-facing message text).
- Depends on: `server/db.ts`, `server/metadata.ts`, `server/security.ts`, `shared/schemas.ts`
- Used by: `server/app.ts`, `server/verify.ts` (imports `hashFile`)
- Purpose: System of record for devices, sessions, uploads (one row per attempt), files (one row per distinct content hash), logs, settings.
- Location: `server/db.ts`
- Contains: `SCHEMA` string (`CREATE TABLE IF NOT EXISTS …`), `openDb`, `tx` (BEGIN IMMEDIATE wrapper), typed helpers `get`, `all`, `run`, row interfaces `FileRow`, `UploadRow`, `DeviceRow`.
- Depends on: `node:sqlite`
- Used by: everything stateful. No ORM, no migrations framework; schema evolves by `CREATE TABLE IF NOT EXISTS`.
- Purpose: Load/save the single JSON `settings` row, compute data dir, validate backup folder, discover real Pictures folder.
- Location: `server/config.ts`
- Contains: `dataDir()` (env `PHOTOSYNC_DATA_DIR` or `%LOCALAPPDATA%\PhotoSync`), `loadSettings`, `saveSettings`, `validateDestination`, PowerShell call for the Pictures known folder.
- Depends on: `server/db.ts`, `server/security.ts`, `shared/schemas.ts` (type)
- Used by: `server/main.ts`, `server/app.ts`, `server/engine.ts`, `server/verify-cli.ts`
- Purpose: Pairing codes, device tokens, LAN address policy, filename sanitising, path containment, the `HttpError` type.
- Location: `server/security.ts`
- Contains: `Pairing` class (8-char code, 10-minute TTL, per-IP throttling), `newToken`/`hashToken` (only SHA-256 of token stored), `isLocalNetworkAddress` (RFC 1918 / loopback / link-local / ULA via `BlockList`), `pickLanAddress`, `sanitizeFilename`, `safeMediaFilename` (extension allow-list), `resolveInside`, `HttpError`.
- Depends on: Node built-ins only.
- Used by: `server/app.ts`, `server/engine.ts`, `server/config.ts`, `server/main.ts`.
- Purpose: Read-only extraction of capture date to choose `YYYY\MM` folder.
- Location: `server/metadata.ts`
- Contains: `readCaptureDate(file, ext)` → EXIF `DateTimeOriginal` via `exifreader` for images; hand-written MOV/MP4 `moov/mvhd` atom walker for videos. Returns `null` on any failure (never fails an upload).
- Depends on: `exifreader`, Node `fs/promises`.
- Used by: `server/engine.ts` (`finishUpload`).
- Purpose: Re-hash every stored file, check DB integrity and dangling references, list untracked files in the backup folder.
- Location: `server/verify.ts` (library), `server/verify-cli.ts` (CLI wrapper)
- Depends on: `server/db.ts`, `server/engine.ts` (`hashFile`)
- Used by: `POST /api/v1/admin/verify` in `server/app.ts`; `npm run verify`.
- Purpose: Single source of truth for API paths, chunk size, Zod request schemas, response types, user-facing coverage notice.
- Location: `shared/schemas.ts`, `shared/sha256.ts`
- Contains: `API = '/api/v1'`, `CHUNK_SIZE = 8 MiB`, `UploadCreate`, `SessionCreate`, `SettingsUpdate`, etc. `Sha256` is an incremental pure-JS hash used only by the phone page (Safari disables `crypto.subtle` on plain `http://`).
- Depends on: `zod`
- Used by: server, `web/src/*`, `tests/*`.
- Purpose: Two pages in one bundle, selected by pathname.
- Location: `web/index.html`, `web/src/main.tsx` (`location.pathname.startsWith('/dashboard') ? Dashboard : Phone`), `web/src/Dashboard.tsx`, `web/src/Phone.tsx`, `web/src/uploader.ts`, `web/src/api.ts`, `web/src/styles.css`
- Contains: `Dashboard` (overview polling plus `EventSource('/api/v1/admin/events')`, settings form, verify button, device removal, stop button), `Phone` (pairing, limits, file picker, per-file upload status, session summary, Shortcut setup text), `uploader.ts` (`uploadFile`: local hash → `POST /uploads` → `PATCH` chunks with retry/offset re-sync → `POST …/finish`), `api.ts` (`api()` wrapper, device token in `localStorage`).
- Depends on: `shared/schemas.ts`, `shared/sha256.ts`, React 19.
- Used by: browsers on the PC (dashboard) and iPhone (phone page).

## Data Flow

### Primary Request Path (phone upload of one file)

### Dashboard Live Path

### Startup / Recovery Path

### Verification Path

- Server state: SQLite rows (authoritative) plus in-memory `ctx.active` (Set of upload IDs with a writer), `ctx.placing` (promise chain serialising placement), `ctx.bytesIn` (speed display), `settings` (closure variable mirrored to DB), `pairing` (in-memory code), `dashboards` and `stopTimer` (auto-stop bookkeeping).
- Client state: React `useState`/`useReducer` in `web/src/Phone.tsx` and `web/src/Dashboard.tsx`; device token in `localStorage` key `photosync.deviceToken` (`web/src/api.ts`).

## Key Abstractions

- Purpose: Dependency bundle passed to engine functions: db, settings getter, logger, event emitter, free-space probe, in-flight set, placement queue, byte counter.
- Defined: `server/engine.ts` (interface), instantiated in `server/app.ts`.
- Pattern: Plain object of closures; the engine never imports the HTTP layer.
- Purpose: `uploads` = one row per transfer attempt (including duplicates, failures, cancellations); `files` = one row per distinct SHA-256 that is stored. Completed uploads point to a file via `file_id`.
- Defined: `server/db.ts`.
- Pattern: Status machine on `uploads.status`: `receiving → finalizing → verified | duplicate`; `receiving → failed | cancelled`; earlier failures in the same session become `retried`.
- Purpose: Typed error with HTTP status, machine code and user-facing message. Thrown anywhere, converted once by `app.setErrorHandler` in `server/app.ts`.
- Defined: `server/security.ts`.
- Pattern: Throw, do not reply manually (exception: SSE and the duplicate-free path).
- Purpose: Validate every request body/query and type responses.
- Defined: `shared/schemas.ts`; parsed inline in route handlers (`UploadCreate.parse(req.body)`). `ZodError` is mapped to 400 `invalid_request`.
- Purpose: One-time 8-character code (no look-alike characters), rotates on use, throttled per IP.
- Defined: `server/security.ts`; instance created in `buildApp`; code printed by `server/main.ts`.
- Purpose: Incremental hash for the phone page; verified against `node:crypto` in `tests/units.test.ts`.
- Defined: `shared/sha256.ts`.

## Entry Points

- Location: `server/main.ts`
- Triggers: `npm start`, `Start Backup.cmd`, `scripts/start-backup.ps1` (sets `PHOTOSYNC_PORT`, passes `--no-open`).
- Responsibilities: Duplicate-instance check, DB open, `buildApp`, listen, print QR/pairing info, auto-open dashboard on Windows, signal-driven shutdown that closes Fastify then SQLite.
- Location: `server/verify-cli.ts`
- Triggers: `npm run verify`
- Responsibilities: Opens the existing DB read-write (no server), runs `verifyBackup`, exits 1 on problems.
- Location: `web/index.html` → `web/src/main.tsx`; built output `web/dist/` (gitignored, built by `npm run build`, served by `@fastify/static` in `server/app.ts`).
- Triggers: Browser requests to `/` (phone) and `/dashboard` (PC). Unknown GET paths fall back to `index.html`.
- Location: `server/app.ts`, prefix `/api/v1` (`API` constant in `shared/schemas.ts`).
- Routes: `GET /health`, `POST /pair`, `GET /status`, `POST /sessions`, `GET /sessions/:id`, `POST /sessions/:id/complete`, `POST /uploads`, `GET|PATCH|DELETE /uploads/:id`, `POST /uploads/:id/finish`, `POST /files` (one-shot, for Shortcuts), `GET /files/:sha256`, `POST /assets/check`.
- Location: `server/app.ts` (`requireAdmin`), prefix `/api/v1/admin`.
- Routes: `GET /overview`, `GET /pairing`, `PUT /settings`, `POST /verify`, `DELETE /devices/:id`, `POST /shutdown`, `GET /events` (SSE).

## Architectural Constraints

- **Threading:** Single Node.js event loop. File hashing and copies run as async streams on the main thread (no workers). The only serialization primitive is `serialize()` in `server/engine.ts` (promise chain on `ctx.placing`), which serializes placement, not hashing.
- **Global state:** Module-level exported mutable objects: `autoStop` in `server/app.ts` (timing, mutated by tests) and `timeouts` in `server/engine.ts` (`chunkIdleMs`). Per-process state lives in closures inside `buildApp` (`settings`, `pairing`, `dashboards`, `verifyRunning`, `lastDeviceActivity`). Two servers (dashboard and LAN) share one `handler` via `makeServer` in `server/app.ts`.
- **Circular imports:** None detected. Import direction is: `main` → `app` → `engine` → `db`/`metadata`/`security`; `config` → `db`/`security`; `verify` → `db`/`engine`. `shared/` imports nothing from `server/` or `web/`.
- **Settings are cached:** `settings` is read once at start (`loadSettings(db)` in `buildApp`) and replaced on `PUT /admin/settings`. Engine reads it via `ctx.settings()`. Any other process writing the settings row will not be seen until restart.
- **Database access:** Synchronous `node:sqlite` calls inside async handlers (`server/db.ts` helpers are sync). Long DB work blocks the loop; current row counts keep this acceptable.
- **Single writer per upload:** `ctx.active` Set guards `appendChunk` and `finishUpload` (409 `upload_busy`).
- **Web bundle is build-time:** Changing `web/src` requires `npm run build`; `Start Backup.cmd` builds only if `web/dist/index.html` is missing.
- **Shared types only by relative import:** No workspace or package boundary; `shared/` is imported as `../shared/...` from `server/`, `web/src/`, and `tests/`.

## Anti-Patterns

### Quota and space checks outside the write path

### Logic growing inside `buildApp`

### Bypassing the engine for direct file writes

## Error Handling

- Destructive steps are guarded by `hashFile` comparison before `rm`/`rename` (`place()`, `recover()`).
- Recovery is idempotent: `finishUpload` returns the existing result for `verified`/`duplicate` uploads; `recover()` repairs `finalizing` rows.
- Client retries use `retryable()` and offset re-sync (`web/src/uploader.ts`).

## Cross-Cutting Concerns

<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-fast` for a trivial task inline, with no subagents and no PLAN.md
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
