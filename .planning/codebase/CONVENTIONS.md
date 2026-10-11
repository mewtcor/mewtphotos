# Coding Conventions

**Analysis Date:** 2026-10-11

## Naming Patterns

**Files:**
- Server modules are lowercase single words: `server/app.ts`, `server/engine.ts`, `server/db.ts`, `server/config.ts`, `server/security.ts`, `server/metadata.ts`, `server/verify.ts`.
- Shared contract and utilities: `shared/schemas.ts`, `shared/sha256.ts`.
- Web UI: React components are PascalCase (`web/src/Dashboard.tsx`, `web/src/Phone.tsx`); non-component modules are lowercase (`web/src/api.ts`, `web/src/uploader.ts`, `web/src/main.tsx`, `web/src/styles.css`).
- Tests: `tests/<name>.test.ts` (`tests/engine.test.ts`, `tests/units.test.ts`); shared test utilities live in `tests/helpers.ts` (no `.test` suffix so Vitest does not collect it).
- CLI entry points carry a `-cli` suffix: `server/verify-cli.ts`. The server entry is `server/main.ts`.
- Note: `shared/sha256.ts` header comment refers to `tests/sha256.test.ts`, which does not exist; the SHA-256 tests are in `tests/units.test.ts`. Keep comments pointing at real files.

**Functions:**
- camelCase verbs for actions: `createUpload`, `appendChunk`, `finishUpload`, `cancelUpload`, `sessionSummary`, `validateDestination`, `loadSettings`, `saveSettings`.
- Predicates use `is`/`has`-style or plain nouns: `isLocalNetworkAddress`, `isLoopback`, `plausibleTime`, `fileIntact`, `statOrNull`.
- Module-private helpers are not exported (`function errorCode`, `async function statOrNull`, `function classify` in `server/engine.ts`). Export only what other modules or tests use.
- Factories/builders use `build*` (`buildApp` in `server/app.ts`); starters use `start*` (`startServer` in `tests/helpers.ts`).

**Variables:**
- camelCase for locals and module state (`lanIp`, `lastDeviceActivity`, `verifyRunning` in `server/app.ts`).
- SCREAMING_SNAKE_CASE for module constants: `GB` in `server/config.ts`, `API`, `CHUNK_SIZE`, `UPLOAD_CONTENT_TYPE`, `COVERAGE_NOTICE` in `shared/schemas.ts`, `STALE_UPLOAD_MS`, `MAX_FAILURES`, `CODE_TTL_MS` in `server/security.ts`, `K` in `shared/sha256.ts`.
- Byte and time sizes are written as arithmetic, not magic numbers: `50 * GB`, `1024 ** 3`, `10 * 60 * 1000`, `60_000` (numeric separators are used for ms values).

**Types:**
- Interfaces for object shapes, named with nouns: `Settings`, `Overview`, `SessionSummary`, `UploadResult`, `FileRow`, `UploadRow`, `DeviceRow`, `Ctx`, `AppOptions`, `BuiltApp`, `CaptureDate`.
- Database row types end in `Row` and mirror SQL column names in snake_case (`last_modified`, `final_path`, `e2e_verified` in `server/db.ts`). Application-facing types use camelCase.
- Zod schemas are PascalCase values that double as request contracts: `PairRequest`, `SessionCreate`, `UploadCreate`, `SettingsUpdate` in `shared/schemas.ts`. Derive TypeScript types from them with `z.infer` or `type` imports instead of duplicating.
- Type-only imports are explicit: `import type { ... }` (required by `verbatimModuleSyntax: true` in `tsconfig.json`).
- Avoid `as any`. The codebase has none; casts are localized to the thin helpers in `server/db.ts` (`get`, `all`) and to parsed JSON bodies.

## Code Style

**Formatting:**
- No formatter config is present (no `.prettierrc`, no `biome.json`). Follow the observed style:
  - Single quotes, semicolons, 2-space indentation, trailing commas in multi-line literals.
  - Lines commonly run to about 150-180 characters; long object literals and SQL are kept on one line rather than wrapped. Match the surrounding file.
- Module-level `// comments` open each file with a one- or two-line purpose statement, e.g. `server/engine.ts`: "The transfer engine: resumable receive -> read-back hash -> ...". Follow this for new files.

**Linting:**
- No ESLint or other linter is configured. Correctness is enforced by the TypeScript compiler (`npm run typecheck`).
- Strictness flags in `tsconfig.json` that code must satisfy: `strict`, `noImplicitOverride`, `noFallthroughCasesInSwitch`, `erasableSyntaxOnly` (no `enum`, no parameter properties, no namespaces; use `const` objects and union types), `verbatimModuleSyntax` (explicit `import type`), `allowImportingTsExtensions` (imports use `.ts` extensions, e.g. `import { get } from './db.ts'`).
- Never use `// @ts-ignore` or `eslint-disable`; none exist. Fix the type instead.

## Import Organization

**Order (observed in `server/app.ts`, `server/engine.ts`, `tests/engine.test.ts`):**
1. Node built-ins with the `node:` prefix (`node:crypto`, `node:fs/promises`, `node:path`), alphabetized by module.
2. Third-party packages (`fastify`, `zod`, `qrcode`, `vitest`, `exifreader`).
3. Shared contract (`../shared/schemas.ts`).
4. Local modules (`./config.ts`, `./db.ts`, `./engine.ts`, `./security.ts`).

**Path Aliases:**
- None. Use relative paths with explicit `.ts` extensions. `tsconfig.json` uses `moduleResolution: "bundler"`.
- Server code always imports the shared contract by relative path (`../shared/schemas.ts`); the web app does the same from `web/src/` (`../../shared/schemas.ts`). Do not duplicate API types on either side.

**Barrel Files:**
- None. Import from the defining module directly.

## Error Handling

**Patterns:**
- Expected, user-facing failures throw `HttpError` from `server/security.ts`: `new HttpError(status, code, message, extra?)`. The `code` is a stable snake_case machine identifier (`bad_destination`, `hash_mismatch`, `unsupported_type`, `unknown_session`, `too_many_attempts`). The `message` is written for the person reading the dashboard or phone, and usually says what to do next.
- A single Fastify error handler in `server/app.ts` (`app.setErrorHandler`) converts errors to JSON `{ error, message, ...extra }`:
  - `HttpError` keeps its status and code.
  - `z.ZodError` becomes 400 `invalid_request` with `z.prettifyError`.
  - Any status >= 500 is logged with `app.log.error` and returned as a generic `internal_error`. Do not leak internal messages to clients.
- Routes do not wrap handlers in try/catch just to format errors; throw and let the handler respond. Validate input at the route boundary with Zod: `const body = PairRequest.parse(req.body);`.
- Filesystem and stream errors go through `classify(ctx, filename, err)` in `server/engine.ts`, which maps Node error codes (`ENOSPC`, `EACCES`, `EPERM`) to user-facing `HttpError`s and logs a plain-language diagnosis once.
- Swallow errors only where absence is the expected answer, and say so in a comment. Examples: `statOrNull` (returns null on `ENOENT`, rethrows otherwise), `picturesDir` falling back to `~/Pictures` in `server/config.ts`, `.catch(() => [])` on `readdir` in tests.
- Background work reports failures through the structured log rather than throwing into the void: `.catch((err: unknown) => ctx.log('error', 'verify_failed', ...))` in `server/app.ts`.
- Type-narrow unknown errors with `instanceof` or a helper: `err instanceof Error ? err.message : String(err)`. Use `errorCode(err)` in `server/engine.ts` to read `code` from Node errors.
- Web client: `server`-style errors are mapped to `ApiError` (carries `status`, `code`, `extra`) and network failures to `NetworkError` in `web/src/api.ts`. Retry decisions key on these classes (`retryable` in `web/src/uploader.ts`), not on message text.

**Transactions and durability:**
- Multi-statement database writes use `tx(db, () => ...)` from `server/db.ts` (`BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK`).
- Nothing reports success before the database commit. Keep this ordering when adding upload states.

## Logging

**Framework:** Fastify logger (`app.log`) plus a custom `ctx.log(level, code, message)` in `server/app.ts`.

**Patterns:**
- Use `ctx.log` for events a user should see on the dashboard. It writes to the `logs` table and the log file, and emits a live `change` event. Pass a stable snake_case `code` (`paired`, `verify_failed`, `insufficient_space`).
- Never log secrets: tokens, pairing codes, or the raw `Authorization` header. The `Ctx.log` doc comment states this rule.
- Request logging is disabled (`logController: new LogController({ disableRequestLogging: true })`) to avoid one line per chunk. Do not re-enable it.
- `console.log` is used only in the entry points `server/main.ts` and `server/verify-cli.ts` for operator-facing output. Library and route code must not call `console`.

## Comments

**When to Comment:**
- Explain *why* a constraint exists, especially for security, durability, or platform quirks. Examples in the codebase:
  - `// synchronous=FULL: a committed "verified" record must survive power loss.` (`server/db.ts`)
  - `// XMLHttpRequest rather than fetch: it is the only way to get upload progress in Safari.` (`web/src/uploader.ts`)
  - `// Our own events are logged via ctx.log; per-request logs would bury them` (`server/app.ts`)
- Use section banners to split long files: `// ---- network ----`, `// ---- filenames ----`, `// ---- sender API ----`.
- Do not narrate obvious code.

**JSDoc/TSDoc:**
- Use `/** ... */` on exported functions, interfaces, and fields whose behavior is not obvious from the name (`hashToken`, `resolveInside`, `Ctx.emit`, `timeouts`). One or two sentences; state guarantees and failure modes.
- Interface fields carry short `/** */` docs when the meaning is domain-specific (`AppOptions.lanIp`, `SessionCreate.libraryCount`).

## Function Design

**Size:** Most helpers are under 20 lines. Long functions are route-building or orchestration code (`buildApp` in `server/app.ts` is ~470 lines of route registration with a shared closure). Do not split route registration into many files; follow the existing single-closure pattern unless the file becomes unmanageable.

**Parameters:**
- Prefer positional params for two or three simple values. Use an options object for optional or many params: `startServer(settings, options, reuse?)`, `verifyBackup(db, destination, onProgress?)`, `uploadFile(file, opts)`.
- Dependency injection goes through an options object with optional test seams, documented as such: `AppOptions.freeBytes` ("Test seam for disk-full behaviour"), `autoStop` timers in `server/app.ts`. Do not add seams that no test uses.
- Pass the database handle `db: Db` explicitly; there is no global connection.
- Use `Ctx` (`server/engine.ts`) to pass shared runtime state into engine functions rather than module globals.

**Return Values:**
- Return plain objects matching a shared interface (`UploadResult`, `VerifyReport`, `CaptureDate`). Return `null` for "not found" in lookup helpers (`readCaptureDate` path, `statOrNull`); use `undefined` from `get<T>` for absent DB rows.
- Async functions return `Promise<T>`; never mix callbacks with promises in new code.

## Module Design

**Exports:**
- Named exports only. No default exports in the codebase.
- Export types alongside their producers (`export interface Settings` in `shared/schemas.ts`, `export interface Ctx` in `server/engine.ts`).
- Shared contract values (routes, limits, notices) live in `shared/schemas.ts` so the server, the web UI, and the planned native iOS client agree. Add new API constants and request schemas there first.

**Barrel Files:** Not used.

## Data and Validation Conventions

- All request bodies are validated with Zod schemas from `shared/schemas.ts`. Keep bounds explicit (`.max(200)`, `.int().min(0)`, `z.uuid()`).
- Hashes are lowercase hex SHA-256 validated by the shared `sha256Hex` regex. Compare hashes with `===` only after both are normalized; token and pairing-code comparison uses `timingSafeEqual` (`server/security.ts`).
- Filenames from clients pass through `sanitizeFilename` / `safeMediaFilename` and paths through `resolveInside`. Any new code that writes under the backup folder must use `resolveInside`.
- Timestamps are stored as epoch milliseconds (`INTEGER`) in SQLite; capture dates are local wall-clock ISO strings (`captured_at TEXT`).
- Database schema is a single `SCHEMA` string applied idempotently with `CREATE ... IF NOT EXISTS` in `server/db.ts`. Add new tables/indexes there; there is no migration framework.

## Adding New Code: Checklist

1. New API route or field: add the Zod schema and constants to `shared/schemas.ts`, validate in the route, and use `HttpError` for expected failures.
2. New server module: lowercase filename, `// ` purpose header, named exports, `.ts` import extensions, `import type` for types.
3. New DB access: go through `get`/`all`/`run`/`tx` in `server/db.ts`.
4. New filesystem write under the backup folder: use `resolveInside` and `safeMediaFilename`.
5. Run `npm run typecheck` and `npm test` before finishing.

---

*Convention analysis: 2026-10-11*
