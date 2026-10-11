<!-- refreshed: 2026-10-11 -->
# Architecture

**Analysis Date:** 2026-10-11

## System Overview

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                    iPhone (Safari page or Apple Shortcut)                 │
│   web/src/Phone.tsx  ─ web/src/uploader.ts ─ web/src/api.ts               │
│   (hashes each file with shared/sha256.ts, then sends chunks)             │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │ HTTP on LAN, /api/v1/* (Bearer device token)
┌───────────────────────────────▼──────────────────────────────────────────┐
│                 HTTP layer  `server/app.ts` (buildApp)                    │
│  sender routes · admin routes (127.0.0.1 only) · SSE · static web/dist    │
├───────────────────────────────┬──────────────────────────────────────────┤
│  `server/security.ts`         │  `server/config.ts`  (settings, dataDir)  │
│  pairing, tokens, LAN ACL,    │  `server/metadata.ts` (EXIF/QuickTime     │
│  filename + path guards       │   capture date, read-only)                │
└───────────────────────────────┴──────────────┬───────────────────────────┘
                                               │
┌──────────────────────────────────────────────▼───────────────────────────┐
│             Transfer engine  `server/engine.ts`                           │
│  createUpload → appendChunk → finishUpload (hash, dedupe, place, commit) │
│  recover() at startup · sessionSummary() for reporting                    │
└───────────────┬──────────────────────────────────────┬───────────────────┘
                │                                      │
┌───────────────▼──────────────┐          ┌────────────▼──────────────────┐
│ SQLite `server/db.ts`        │          │ Backup folder (user-chosen)   │
│ %LOCALAPPDATA%\PhotoSync\    │          │ YYYY\MM\…  + .incoming\*.part │
│ photosync.db                 │          │                               │
└───────────────▲──────────────┘          └────────────▲──────────────────┘
                │                                      │
                └──────── `server/verify.ts` (re-hash all stored files) ───┘

Process entry: `server/main.ts` (also `server/verify-cli.ts` for `npm run verify`)
Dashboard UI: `web/src/Dashboard.tsx` (talks to /api/v1/admin/* and SSE)
```

## Pattern Overview

**Overall:** Single-process, layered Node.js HTTP service (Fastify) with a transactional file-transfer engine and a SQLite system of record. The server also serves two React pages from one bundle. Shared TypeScript modules define the wire contract used by server, both web pages, and tests.

**Key Characteristics:**
- One process, one event loop, one SQLite file (`node:sqlite`, WAL, `synchronous=FULL`). No worker threads, no queue service.
- Server runs TypeScript directly (`node --disable-warning=ExperimentalWarning server/main.ts`); only `web/` is bundled by Vite (`vite.config.ts`, `root: 'web'`).
- Success is reported only after a durable commit: the file is fsynced, re-read and SHA-256 hashed, renamed into place, then the DB row is committed (`server/engine.ts` `finishUpload` → `place` → `commitStored`).
- Resumable offset-based protocol (tus-like `Upload-Offset` semantics) implemented in `server/engine.ts` `appendChunk`; the on-disk file size is the source of truth for resume offset.
- Two trust zones on one port: sender API accepts any private-network client with a paired device token; admin API additionally requires loopback socket and loopback `Host` header (`server/app.ts` `requireAdmin`).
- Dependency injection by options object: `buildApp(opts)` in `server/app.ts` accepts `db`, `port`, `lanIp`, `logFile`, `webDir`, `onStopRequest`, `freeBytes`. Tests replace these (`tests/helpers.ts` `startServer`).

## Layers

**Entry / process lifecycle:**
- Purpose: Start the server, handle "already running" detection, bind ports, handle signals, stop cleanly.
- Location: `server/main.ts`, `scripts/start-backup.ps1`, `Start Backup.cmd`
- Contains: Port probing (`GET /api/v1/health`), data-dir creation, `openDb`, `buildApp`, QR printing, SIGINT/SIGTERM/SIGHUP handling.
- Depends on: `server/app.ts`, `server/config.ts`, `server/db.ts`, `server/security.ts`
- Used by: `npm start`, the PowerShell launcher.

**HTTP / API layer:**
- Purpose: Route, authenticate, validate request bodies, map errors to JSON, push live events, host the web build.
- Location: `server/app.ts` (single file, ~470 lines, all routes registered inside `buildApp`)
- Contains: request guards (`onRequest` hook), `requireDevice`, `requireAdmin`, error handler, sender routes, admin routes, `/admin/events` SSE, static file serving and SPA fallback, LAN server creation.
- Depends on: `server/engine.ts`, `server/config.ts`, `server/db.ts`, `server/security.ts`, `server/verify.ts`, `shared/schemas.ts`
- Used by: HTTP clients (iPhone page, Shortcuts, dashboard).

**Transfer engine (domain core):**
- Purpose: Everything that decides whether a file is "safely stored".
- Location: `server/engine.ts`
- Contains: `createUpload` (quota/space checks, resume matching, hash-known duplicate short-circuit), `appendChunk` (offset check, idle timeout, byte limit), `finishUpload` (fsync, hash, client-hash compare, EXIF date, `utimes`), `place` (dedupe, date folder, collision-safe name, rename or cross-drive copy), `commitStored` (transactional DB write), `recover` (startup repair), `sessionSummary` (user-facing message text).
- Depends on: `server/db.ts`, `server/metadata.ts`, `server/security.ts`, `shared/schemas.ts`
- Used by: `server/app.ts`, `server/verify.ts` (imports `hashFile`)

**Persistence:**
- Purpose: System of record for devices, sessions, uploads (one row per attempt), files (one row per distinct content hash), logs, settings.
- Location: `server/db.ts`
- Contains: `SCHEMA` string (`CREATE TABLE IF NOT EXISTS …`), `openDb`, `tx` (BEGIN IMMEDIATE wrapper), typed helpers `get`, `all`, `run`, row interfaces `FileRow`, `UploadRow`, `DeviceRow`.
- Depends on: `node:sqlite`
- Used by: everything stateful. No ORM, no migrations framework; schema evolves by `CREATE TABLE IF NOT EXISTS`.

**Configuration / settings:**
- Purpose: Load/save the single JSON `settings` row, compute data dir, validate backup folder, discover real Pictures folder.
- Location: `server/config.ts`
- Contains: `dataDir()` (env `PHOTOSYNC_DATA_DIR` or `%LOCALAPPDATA%\PhotoSync`), `loadSettings`, `saveSettings`, `validateDestination`, PowerShell call for the Pictures known folder.
- Depends on: `server/db.ts`, `server/security.ts`, `shared/schemas.ts` (type)
- Used by: `server/main.ts`, `server/app.ts`, `server/engine.ts`, `server/verify-cli.ts`

**Security primitives:**
- Purpose: Pairing codes, device tokens, LAN address policy, filename sanitising, path containment, the `HttpError` type.
- Location: `server/security.ts`
- Contains: `Pairing` class (8-char code, 10-minute TTL, per-IP throttling), `newToken`/`hashToken` (only SHA-256 of token stored), `isLocalNetworkAddress` (RFC 1918 / loopback / link-local / ULA via `BlockList`), `pickLanAddress`, `sanitizeFilename`, `safeMediaFilename` (extension allow-list), `resolveInside`, `HttpError`.
- Depends on: Node built-ins only.
- Used by: `server/app.ts`, `server/engine.ts`, `server/config.ts`, `server/main.ts`.

**Metadata reader:**
- Purpose: Read-only extraction of capture date to choose `YYYY\MM` folder.
- Location: `server/metadata.ts`
- Contains: `readCaptureDate(file, ext)` → EXIF `DateTimeOriginal` via `exifreader` for images; hand-written MOV/MP4 `moov/mvhd` atom walker for videos. Returns `null` on any failure (never fails an upload).
- Depends on: `exifreader`, Node `fs/promises`.
- Used by: `server/engine.ts` (`finishUpload`).

**Verification:**
- Purpose: Re-hash every stored file, check DB integrity and dangling references, list untracked files in the backup folder.
- Location: `server/verify.ts` (library), `server/verify-cli.ts` (CLI wrapper)
- Depends on: `server/db.ts`, `server/engine.ts` (`hashFile`)
- Used by: `POST /api/v1/admin/verify` in `server/app.ts`; `npm run verify`.

**Shared contract:**
- Purpose: Single source of truth for API paths, chunk size, Zod request schemas, response types, user-facing coverage notice.
- Location: `shared/schemas.ts`, `shared/sha256.ts`
- Contains: `API = '/api/v1'`, `CHUNK_SIZE = 8 MiB`, `UploadCreate`, `SessionCreate`, `SettingsUpdate`, etc. `Sha256` is an incremental pure-JS hash used only by the phone page (Safari disables `crypto.subtle` on plain `http://`).
- Depends on: `zod`
- Used by: server, `web/src/*`, `tests/*`.

**Presentation (web):**
- Purpose: Two pages in one bundle, selected by pathname.
- Location: `web/index.html`, `web/src/main.tsx` (`location.pathname.startsWith('/dashboard') ? Dashboard : Phone`), `web/src/Dashboard.tsx`, `web/src/Phone.tsx`, `web/src/uploader.ts`, `web/src/api.ts`, `web/src/styles.css`
- Contains: `Dashboard` (overview polling plus `EventSource('/api/v1/admin/events')`, settings form, verify button, device removal, stop button), `Phone` (pairing, limits, file picker, per-file upload status, session summary, Shortcut setup text), `uploader.ts` (`uploadFile`: local hash → `POST /uploads` → `PATCH` chunks with retry/offset re-sync → `POST …/finish`), `api.ts` (`api()` wrapper, device token in `localStorage`).
- Depends on: `shared/schemas.ts`, `shared/sha256.ts`, React 19.
- Used by: browsers on the PC (dashboard) and iPhone (phone page).

## Data Flow

### Primary Request Path (phone upload of one file)

1. Phone page computes SHA-256 of the file in 8 MiB slices (`web/src/uploader.ts` `uploadFile`, `shared/sha256.ts`).
2. `POST /api/v1/uploads` → `server/app.ts` route → `requireDevice` → `UploadCreate.parse` → `createUpload` in `server/engine.ts`. If the hash is already stored and intact, returns `status: 'duplicate'` and no bytes are sent.
3. Otherwise `createUpload` checks max size, free space (`ctx.freeBytes`), quota, writes an empty `.incoming\<id>.part`, inserts an `uploads` row with status `receiving`.
4. `PATCH /api/v1/uploads/:id` with `upload-offset` header → `appendChunk` in `server/engine.ts`: offset must equal on-disk size (else 409 `offset_mismatch` with the real offset), bytes are piped through a counting `Transform` into `createWriteStream(..., { flags: 'r+', start: offset })`, 60 s idle timer aborts stalled chunks.
5. `POST /api/v1/uploads/:id/finish` → `finishUpload`: `fsync` temp file, SHA-256 re-read, compare with client hash (422 `hash_mismatch` on mismatch), read capture date (`server/metadata.ts`), set mtime from `last_modified`.
6. `serialize(ctx, () => place(...))` runs placement one at a time (`server/engine.ts`): dedupe against `files` table (re-hashing the existing copy), choose `YYYY\MM` folder if `organizeByDate`, pick collision-safe name (`IMG (2).HEIC`), write `status='finalizing'` intent, `rename` (EXDEV → copy + verify + delete temp), then `commitStored` in a `tx` (`BEGIN IMMEDIATE`) that upserts `files` and sets `uploads.status='verified'`.
7. Response `UploadResult` is returned only after step 6 commits. The dashboard's `change` SSE event triggers a refresh.

### Dashboard Live Path

1. Browser loads `/dashboard` → `web/src/Dashboard.tsx` fetches `GET /api/v1/admin/overview` and `GET /api/v1/admin/pairing`.
2. `EventSource('/api/v1/admin/events')` → `server/app.ts` registers the response on the shared `EventEmitter` (`emitter`). `ctx.log`, `ctx.emit` (in `server/app.ts` `ctx` object) push `change`, `speed`, `verify` events. Ping every 25 s.
3. Each SSE connection increments `dashboards`; when it drops to 0, `stopIfDashboardGone` runs after `autoStop.graceMs` and may call `onStopRequest` (wired to `shutdown` in `server/main.ts`) unless a transfer or recent phone activity is in progress.

### Startup / Recovery Path

1. `server/main.ts` checks for an existing instance by calling `/api/v1/health` before opening the DB.
2. `openDb` creates schema, `loadSettings` seeds defaults (destination `Pictures\iPhone Backup`, found via PowerShell known-folder lookup).
3. `buildApp` runs `recover(ctx)` (`server/engine.ts`): finishes or rolls back `finalizing` uploads, expires stale `receiving` uploads (7 days), deletes orphan `*.part` files.
4. `listen()` binds `127.0.0.1:<port>` and, separately, the LAN address (`server.listen(boundPort, opts.lanIp)`).

### Verification Path

1. `POST /api/v1/admin/verify` (202) or `npm run verify` → `server/verify.ts` `verifyBackup` iterates every `files` row, re-hashes, updates `files.verify_status`, runs `PRAGMA integrity_check`, checks dangling `uploads.file_id`, lists untracked files, persists the report in `settings` key `lastVerify`.

**State Management:**
- Server state: SQLite rows (authoritative) plus in-memory `ctx.active` (Set of upload IDs with a writer), `ctx.placing` (promise chain serialising placement), `ctx.bytesIn` (speed display), `settings` (closure variable mirrored to DB), `pairing` (in-memory code), `dashboards` and `stopTimer` (auto-stop bookkeeping).
- Client state: React `useState`/`useReducer` in `web/src/Phone.tsx` and `web/src/Dashboard.tsx`; device token in `localStorage` key `photosync.deviceToken` (`web/src/api.ts`).

## Key Abstractions

**`Ctx` (transfer context):**
- Purpose: Dependency bundle passed to engine functions: db, settings getter, logger, event emitter, free-space probe, in-flight set, placement queue, byte counter.
- Defined: `server/engine.ts` (interface), instantiated in `server/app.ts`.
- Pattern: Plain object of closures; the engine never imports the HTTP layer.

**`UploadRow` / `FileRow` (two-level record model):**
- Purpose: `uploads` = one row per transfer attempt (including duplicates, failures, cancellations); `files` = one row per distinct SHA-256 that is stored. Completed uploads point to a file via `file_id`.
- Defined: `server/db.ts`.
- Pattern: Status machine on `uploads.status`: `receiving → finalizing → verified | duplicate`; `receiving → failed | cancelled`; earlier failures in the same session become `retried`.

**`HttpError`:**
- Purpose: Typed error with HTTP status, machine code and user-facing message. Thrown anywhere, converted once by `app.setErrorHandler` in `server/app.ts`.
- Defined: `server/security.ts`.
- Pattern: Throw, do not reply manually (exception: SSE and the duplicate-free path).

**Zod schemas as wire contract:**
- Purpose: Validate every request body/query and type responses.
- Defined: `shared/schemas.ts`; parsed inline in route handlers (`UploadCreate.parse(req.body)`). `ZodError` is mapped to 400 `invalid_request`.

**`Pairing`:**
- Purpose: One-time 8-character code (no look-alike characters), rotates on use, throttled per IP.
- Defined: `server/security.ts`; instance created in `buildApp`; code printed by `server/main.ts`.

**`Sha256` (browser):**
- Purpose: Incremental hash for the phone page; verified against `node:crypto` in `tests/units.test.ts`.
- Defined: `shared/sha256.ts`.

## Entry Points

**Server process:**
- Location: `server/main.ts`
- Triggers: `npm start`, `Start Backup.cmd`, `scripts/start-backup.ps1` (sets `PHOTOSYNC_PORT`, passes `--no-open`).
- Responsibilities: Duplicate-instance check, DB open, `buildApp`, listen, print QR/pairing info, auto-open dashboard on Windows, signal-driven shutdown that closes Fastify then SQLite.

**Verification CLI:**
- Location: `server/verify-cli.ts`
- Triggers: `npm run verify`
- Responsibilities: Opens the existing DB read-write (no server), runs `verifyBackup`, exits 1 on problems.

**Web bundle:**
- Location: `web/index.html` → `web/src/main.tsx`; built output `web/dist/` (gitignored, built by `npm run build`, served by `@fastify/static` in `server/app.ts`).
- Triggers: Browser requests to `/` (phone) and `/dashboard` (PC). Unknown GET paths fall back to `index.html`.

**Sender API:**
- Location: `server/app.ts`, prefix `/api/v1` (`API` constant in `shared/schemas.ts`).
- Routes: `GET /health`, `POST /pair`, `GET /status`, `POST /sessions`, `GET /sessions/:id`, `POST /sessions/:id/complete`, `POST /uploads`, `GET|PATCH|DELETE /uploads/:id`, `POST /uploads/:id/finish`, `POST /files` (one-shot, for Shortcuts), `GET /files/:sha256`, `POST /assets/check`.

**Admin API (loopback only):**
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

**What happens:** `createUpload` in `server/engine.ts` checks `ctx.freeBytes` and quota once at upload start, then does not reserve space. Several large parallel uploads can overshoot.
**Why it's wrong:** Known gap; the code already flags it with a `ponytail:` comment in `server/engine.ts`.
**Do this instead:** If it matters, reserve in-flight sizes in a shared counter on `ctx` before `writeFile(tempPath, …)` in `createUpload`, and release on finish/cancel/failure.

### Logic growing inside `buildApp`

**What happens:** All routes, guards, timers, SSE, stop logic and static serving live in one closure in `server/app.ts` (~470 lines). Helper functions (`requireDevice`, `requireAdmin`, `stopIfDashboardGone`) close over `db`, `settings`, `pairing`.
**Why it's wrong:** New routes must be added inside the closure to reach shared state; testing and reading require scrolling the whole file.
**Do this instead:** Add new sender routes near the `// ---- sender API` block and admin routes near `// ---- admin API`, reusing `requireDevice`/`requireAdmin`. Put new domain logic in `server/engine.ts` or a new module that takes `Ctx`, not in the route handler.

### Bypassing the engine for direct file writes

**What happens:** Any new code that writes into the backup folder directly skips dedupe, hash verification, `files` table commit and `verify` coverage.
**Why it's wrong:** `verifyBackup` reports such files as "untracked" and the database loses the invariant that every stored file is recorded.
**Do this instead:** Route all stores through `createUpload` → `appendChunk` → `finishUpload`, or extend `place()` / `commitStored()` in `server/engine.ts`.

## Error Handling

**Strategy:** Throw `HttpError` (or a Node error with a `code`) from any layer; `classify()` in `server/engine.ts` maps filesystem and stream error codes (`ENOSPC`, `EACCES`, `UPLOAD_TIMEOUT`, `ECONNRESET`, `ERR_STREAM_PREMATURE_CLOSE`) to user-facing HTTP errors and logs a diagnosis once. Fastify's `setErrorHandler` in `server/app.ts` formats the response: `HttpError` → its status; `ZodError` → 400 `invalid_request`; other ≥500 → generic 500 with the stack logged to `app.log`.

**Patterns:**
- Destructive steps are guarded by `hashFile` comparison before `rm`/`rename` (`place()`, `recover()`).
- Recovery is idempotent: `finishUpload` returns the existing result for `verified`/`duplicate` uploads; `recover()` repairs `finalizing` rows.
- Client retries use `retryable()` and offset re-sync (`web/src/uploader.ts`).

## Cross-Cutting Concerns

**Logging:** `ctx.log(level, code, message)` in `server/app.ts` writes a row to the `logs` table (capped at 5000 rows, pruned on startup) and to the Fastify file logger at `logFile` (`%LOCALAPPDATA%\PhotoSync\server.log`). Per-request logging is disabled (`LogController`). Logs must never contain keys, pairing codes or file contents (stated in `server/engine.ts` comment on `Ctx.log`).

**Validation:** Zod schemas in `shared/schemas.ts` parsed per route; filename and extension rules in `server/security.ts` (`safeMediaFilename`, `ALLOWED_EXTENSIONS`); path containment via `resolveInside`.

**Authentication:** Sender routes: `Authorization: Bearer <token>` matched against `devices.token_hash` (`requireDevice` in `server/app.ts`). Pairing: `POST /api/v1/pair` with the dashboard code (`server/security.ts` `Pairing.consume`). Admin routes: no credential; loopback socket plus loopback `Host` header (`requireAdmin`).

**Network policy:** `onRequest` hook in `server/app.ts` rejects non-private source addresses (403) and cross-origin requests whose `Origin` host differs from `Host`. Security headers (`content-security-policy`, `x-content-type-options`) are set there too.

**Time handling:** Capture date and file modification time chosen by `finishUpload` and `place()`; trust checks in `plausibleTime()` (`server/engine.ts`) reject timestamps before 1990 or more than a day in the future.

---

*Architecture analysis: 2026-10-11*
