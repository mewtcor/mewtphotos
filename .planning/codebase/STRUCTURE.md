# Codebase Structure

**Analysis Date:** 2026-10-11

## Directory Layout

```
mewtphotos/                          # project root (single npm package, "private": true)
├── server/                         # Node/TypeScript backend, run directly (no build)
│   ├── main.ts                     # process entry point (npm start)
│   ├── app.ts                      # buildApp(): Fastify routes, guards, SSE, static files
│   ├── engine.ts                   # transfer engine: receive, hash, dedupe, place, commit, recover
│   ├── db.ts                       # SQLite schema, openDb, tx, typed query helpers
│   ├── config.ts                   # settings row, dataDir(), validateDestination()
│   ├── security.ts                 # pairing, tokens, LAN ACL, filename + path guards, HttpError
│   ├── metadata.ts                 # EXIF / QuickTime capture-date reader
│   ├── verify.ts                   # verifyBackup(): re-hash stored files, DB checks
│   └── verify-cli.ts               # npm run verify wrapper
├── shared/                         # code imported by server, web and tests
│   ├── schemas.ts                  # API prefix, chunk size, Zod schemas, response types
│   └── sha256.ts                   # incremental pure-JS SHA-256 for the phone page
├── web/                            # React UI (bundled by Vite)
│   ├── index.html                  # Vite entry HTML
│   ├── src/
│   │   ├── main.tsx                # picks Dashboard or Phone by pathname
│   │   ├── Dashboard.tsx           # PC dashboard page (admin API, SSE)
│   │   ├── Phone.tsx               # iPhone page (pairing, picker, progress)
│   │   ├── uploader.ts             # per-file resumable upload driver
│   │   ├── api.ts                  # fetch wrapper, device token storage, formatters
│   │   └── styles.css              # the only stylesheet
│   └── dist/                       # BUILD OUTPUT (gitignored): index.html + assets/
├── tests/                          # Vitest suites (node environment)
│   ├── engine.test.ts              # integration tests through buildApp + HTTP
│   ├── units.test.ts               # SHA-256, filenames, paths, network, pairing
│   └── helpers.ts                  # startServer(), rawRequest(), sha256(), PHONE_IP
├── docs/                           # user and design documentation (markdown)
│   ├── api.md                      # HTTP API reference
│   ├── setup-windows.md            # install / run guide
│   ├── troubleshooting.md
│   ├── ios-shortcut.md             # Apple Shortcut setup
│   ├── iphone-test-checklist.md    # manual device test checklist
│   └── ROADMAP_IOS_COMPANION.md    # native iOS app plan
├── scripts/
│   └── start-backup.ps1            # PowerShell launcher (checks Node, installs, builds, runs)
├── Start Backup.cmd                # double-click wrapper around scripts/start-backup.ps1
├── README.md                       # overview, quick start, architecture decisions, security summary
├── package.json                    # scripts, dependencies, engines (Node >= 22.18)
├── package-lock.json               # npm lockfile
├── tsconfig.json                   # strict TS, noEmit, includes server/shared/web/src/tests/*.ts
├── vite.config.ts                  # root: web, outDir: web/dist, dev proxy /api -> 8787
├── vitest.config.ts                # includes tests/**/*.test.ts
├── .gitignore                      # node_modules/, web/dist/, *.log, .tmp-tests/
└── .planning/codebase/             # generated codebase maps (this document lives here)
```

Runtime-only locations (outside the repo, not committed):
- `%LOCALAPPDATA%\MewtPhotos\mewtphotos.db` (+ `-wal`, `-shm`) and `server.log`. Override with `MEWTPHOTOS_DATA_DIR`.
- Backup folder, default `<Pictures>\iPhone Backup\YYYY\MM\…`, with `.incoming\<uuid>.part` for in-flight transfers. Chosen in the dashboard.

## Directory Purposes

**`server/`:**
- Purpose: Everything that runs on the Windows PC as the backup service.
- Contains: Only `.ts` files. Flat, no subfolders. Each file has one role (see layers in ARCHITECTURE.md).
- Key files: `server/app.ts` (routes), `server/engine.ts` (correctness-critical transfer logic), `server/db.ts` (schema).

**`shared/`:**
- Purpose: Wire contract and code that must be identical on both sides.
- Contains: `schemas.ts` (Zod + types), `sha256.ts` (browser hash).
- Key files: `shared/schemas.ts` (change here first when altering any request or response shape).

**`web/src/`:**
- Purpose: The two pages. No router library; `main.tsx` checks `location.pathname`.
- Contains: One component file per page, one transport file, one stylesheet.
- Key files: `web/src/Phone.tsx` (largest UI, 365 lines), `web/src/Dashboard.tsx` (274 lines), `web/src/uploader.ts` (136 lines).

**`web/dist/`:**
- Purpose: Vite output served by Fastify at `/`.
- Generated: Yes (`npm run build`). Committed: No (gitignored). The launcher builds it when `web/dist/index.html` is missing.

**`tests/`:**
- Purpose: Automated tests (49 tests per README).
- Contains: `*.test.ts` (Vitest picks up only `tests/**/*.test.ts`), `helpers.ts` (not a test file).
- Key files: `tests/helpers.ts` (`startServer` builds a real app against a temp DB and temp folder; reuse it for any integration test).

**`docs/`:**
- Purpose: Human-facing documentation. Not read by the build.
- Contains: Markdown only.

**`scripts/`:**
- Purpose: Windows launcher. Changes nothing system-wide (no firewall or env changes outside the process).

**`.planning/`:**
- Purpose: GSD planning artifacts. `.planning/codebase/` holds the maps consumed by planning and execution commands.
- Generated: Yes. Committed: decided by the project workflow (`.planning/` is not in `.gitignore`).

## Key File Locations

**Entry Points:**
- `server/main.ts`: Server process start; signal handling; prints QR and pairing code.
- `server/verify-cli.ts`: `npm run verify`.
- `web/src/main.tsx`: Browser entry for both pages.
- `scripts/start-backup.ps1`: Windows launcher.

**Configuration:**
- `package.json`: scripts (`start`, `build`, `dev:web`, `typecheck`, `test`, `verify`), engines.
- `tsconfig.json`: strict compiler options, `allowImportingTsExtensions`, `verbatimModuleSyntax`, `erasableSyntaxOnly`. Imports must use `.ts` extensions.
- `vite.config.ts`: web build root and dev proxy.
- `vitest.config.ts`: test glob, 60 s timeout.
- `server/config.ts`: runtime settings defaults (`loadSettings`) and data directory rule.
- `shared/schemas.ts`: `CHUNK_SIZE`, `UPLOAD_CONTENT_TYPE`, `API` prefix, `SettingsUpdate` limits.

**Core Logic:**
- `server/engine.ts`: upload lifecycle, placement, recovery.
- `server/app.ts`: HTTP surface and access rules.
- `server/security.ts`: auth, network policy, filename rules.
- `server/db.ts`: schema and transactions.
- `server/metadata.ts`: capture date for folder layout.
- `server/verify.ts`: integrity audit.

**Testing:**
- `tests/engine.test.ts`: uploading, interrupted transfers, restarts and recovery, verification, completeness reporting, access control, stopping with the dashboard.
- `tests/units.test.ts`: browser SHA-256 parity, filename and path rules, LAN classification, pairing throttle.
- `tests/helpers.ts`: fixtures and HTTP helpers.

## Naming Conventions

**Files:**
- Server and shared modules: lowercase single word, `camelCase`-free, e.g. `engine.ts`, `security.ts`. Exception: `verify-cli.ts` (kebab-case for a CLI entry).
- Web components: PascalCase `.tsx` matching the exported component: `Dashboard.tsx`, `Phone.tsx`.
- Web non-component modules: lowercase `.ts`: `api.ts`, `uploader.ts`.
- Tests: `<area>.test.ts` (`engine.test.ts`, `units.test.ts`); helpers `helpers.ts`.
- Docs: lowercase kebab-case, except the roadmap `ROADMAP_IOS_COMPANION.md`.
- PowerShell: kebab-case `start-backup.ps1`.

**Directories:**
- Lowercase single words: `server`, `shared`, `web`, `tests`, `docs`, `scripts`.

**Code identifiers:**
- Functions: `camelCase` (`createUpload`, `appendChunk`, `finishUpload`).
- Types and interfaces: `PascalCase` (`Ctx`, `UploadRow`, `HttpError`); Zod schema constants also `PascalCase` (`UploadCreate`, `SettingsUpdate`).
- Database tables and columns: `snake_case` (`uploads.session_id`, `files.verify_status`); JSON wire fields are `camelCase` (`sessionId`, `uploadId`) mapped by the server.
- Constants: `UPPER_SNAKE_CASE` for true constants (`CHUNK_SIZE`, `SCHEMA`, `STALE_UPLOAD_MS`, `CODE_ALPHABET`); the API prefix `API` is also upper case.
- HTTP routes: `${API}/...` template strings, never hard-coded `/api/v1` in new code.
- Error codes: `snake_case` strings (`unknown_session`, `offset_mismatch`, `insufficient_space`) and `HttpError` status matches.
- Log codes: `snake_case` (`stored`, `duplicate`, `auto_stop`).

**Imports:**
- Relative paths with explicit `.ts` extension (`import { buildApp } from './app.ts';`). `web/` imports `../../shared/...` and `../shared/...` by relative path.
- Node built-ins use the `node:` prefix (`node:crypto`, `node:sqlite`).

## Where to Add New Code

**New sender (phone or Shortcut) endpoint:**
- Route: `server/app.ts`, inside the `// ---- sender API` section; wrap with `requireDevice(req)`.
- Request/response schema: `shared/schemas.ts` (add Zod schema and exported type).
- Domain logic: `server/engine.ts` (or a new `server/<feature>.ts` taking `Ctx`).
- Test: `tests/engine.test.ts` (add to the matching `describe`) using `startServer` from `tests/helpers.ts`.
- API documentation: `docs/api.md`.

**New admin (dashboard) endpoint:**
- Route: `server/app.ts`, `// ---- admin API` section; first line `requireAdmin(req)`.
- Test: `tests/engine.test.ts` under `access control` or a new `describe`.

**New transfer or storage behaviour:**
- Implementation: `server/engine.ts`. Keep the invariant that success is returned only after `commitStored`.
- Schema change: `SCHEMA` in `server/db.ts` (`CREATE TABLE IF NOT EXISTS` only; add `ALTER TABLE` handling there if an existing column must change, because there is no migration runner).
- Recovery: extend `recover()` in `server/engine.ts` for any new intermediate status.

**New setting:**
- Type and validation: `Settings` interface and `SettingsUpdate` in `shared/schemas.ts`; default in `loadSettings` in `server/config.ts`.
- UI: `SettingsForm` in `web/src/Dashboard.tsx`.

**New dashboard panel or component:**
- Component: `web/src/Dashboard.tsx` (small presentational helpers such as `Tile`, `Connect`, `SessionCounts` live in the same file; add new ones beside them).
- Data: extend `Overview` in `shared/schemas.ts` and `/admin/overview` in `server/app.ts`.

**New phone-page behaviour:**
- Component: `web/src/Phone.tsx`. Transfer logic: `web/src/uploader.ts`. Hashing: `shared/sha256.ts`.

**New metadata source (date folders):**
- `server/metadata.ts`, returning `CaptureDate`. Keep it read-only and non-throwing.

**New shared utility used by server and web:**
- `shared/` (plain module, no Node or DOM-only APIs unless the file is used only on one side).

**New server-only utility:**
- `server/security.ts` if it is security-related; otherwise add a new file in `server/`. There is no `utils/` folder.

**New test helper:**
- `tests/helpers.ts`.

**New script:**
- Node CLI: `server/<name>-cli.ts`, wired in `package.json` `scripts` (follow `verify-cli.ts`).
- Windows: `scripts/` (PowerShell), with a `.cmd` wrapper at the root only if it must be double-clickable.

## Special Directories

**`web/dist/`:**
- Purpose: Built web bundle (`index.html`, hashed `assets/`).
- Generated: Yes, by `npm run build` (Vite, `emptyOutDir: true`).
- Committed: No (`.gitignore`).

**`node_modules/`:**
- Purpose: npm dependencies.
- Generated: Yes, by `npm install`.
- Committed: No (`.gitignore`).

**`.tmp-tests/`:**
- Purpose: Reserved for test scratch output (listed in `.gitignore`); the current helpers create temp dirs with `mkdtemp` in the OS temp folder.
- Generated: Yes. Committed: No.

**`.incoming/` (inside the backup folder, not the repo):**
- Purpose: Partial uploads (`<uuid>.part`). Swept by `recover()` and skipped by `verifyBackup`.
- Generated: Yes, at runtime.

**`.planning/codebase/`:**
- Purpose: Codebase map documents for GSD commands.
- Generated: Yes (by mapper agents). Committed: follows project workflow.

---

*Structure analysis: 2026-10-11*
