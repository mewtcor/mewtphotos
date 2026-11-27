# Testing Patterns

**Analysis Date:** 2026-10-11

## Test Framework

**Runner:**
- Vitest `^5.0.3` (devDependency in `package.json`)
- Config: `vitest.config.ts`
  - `include: ['tests/**/*.test.ts']`
  - `environment: 'node'`
  - `testTimeout: 60_000` (large-file and interrupted-transfer tests need the headroom)

**Assertion Library:**
- Vitest's built-in `expect` (Jest-compatible matchers): `toBe`, `toEqual`, `toMatchObject`, `toThrow`, `toBeLessThanOrEqual`. Failure messages are supplied as the second argument to `expect(...)` where a loop variable needs identifying, e.g. `expect(isLocalNetworkAddress(ip), ip).toBe(true)` in `tests/units.test.ts`.

**Run Commands:**
```bash
npm test                      # Run all tests (vitest run), currently 48 `it` blocks across 2 files
npx vitest                    # Watch mode (default vitest behavior when not using `run`)
npx vitest run --coverage     # Coverage (requires @vitest/coverage-* provider; not installed)
npx vitest run tests/units.test.ts          # Single file
npx vitest run -t "rejects a corrupted"     # Single test by name
npm run typecheck             # tsc --noEmit; tests are included in tsconfig.json
```

Note: `tests/` is type-checked by `npm run typecheck` (`tsconfig.json` includes `tests`), so test files must type-check too.

## Test File Organization

**Location:**
- All tests live in a top-level `tests/` directory, separate from source. Nothing is co-located with `server/` or `web/src/`.

**Naming:**
- `*.test.ts` for test files (`tests/engine.test.ts`, `tests/units.test.ts`).
- `tests/helpers.ts` holds shared harness code and is not a test file.

**Structure:**
```
tests/
├── helpers.ts          # startServer(), rawRequest(), sha256(), PHONE_IP
├── units.test.ts       # pure-function tests: SHA-256, filenames, network, pairing
└── engine.test.ts      # HTTP + filesystem + SQLite integration tests, grouped by behavior
```

## Test Structure

**Suite Organization:**
Two levels of grouping: a `describe` per behavior area, and an `it` per observable guarantee. Test names are written as behavior sentences, not method names:

```typescript
// tests/engine.test.ts
describe('uploading', () => {
  it('stores a file byte-for-byte and reports it verified end to end', async () => {
    const s = await server();
    const data = randomBytes(300_000);
    const res = await s.upload(await s.newSession(), 'IMG_0001.HEIC', data);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'verified', sha256: sha256(data), endToEndVerified: true });
    expect(await readFile(path.join(s.dest, 'IMG_0001.HEIC'))).toEqual(data);
  });
  ...
});
```

Existing `describe` groups in `tests/engine.test.ts`: `uploading`, `interrupted transfers`, `restarts and recovery`, `verification`, `completeness reporting`, `access control`, `stopping with the dashboard`. Add new behavior tests to the matching group, or create a new group named after the user-visible behavior.

**Patterns:**
- Setup: a per-test server via the `server()` wrapper in `tests/engine.test.ts`, which calls `startServer` and registers the instance in an `open` array.
- Teardown: a single `afterEach` closes every opened server (`s.app.close()`), closes the DB if the test has not already (`try { s.db.close() } catch {}`), and removes the temp directory with `rm(..., { recursive: true, force: true })`. Every test that creates a server must go through the `server()` wrapper so teardown runs.
- Assertion: prefer `toMatchObject` for partial response shapes and exact `toEqual` for file bytes.
- Error assertions check both status code and machine-readable error code, e.g.:
  ```typescript
  expect(res.status).toBe(422);
  expect(res.body.error).toBe('hash_mismatch');
  ```
- Filesystem state is checked by walking the real backup folder with the local `stored(dest)` helper, which skips `.incoming` temp data.

## Test Harness (`tests/helpers.ts`)

**`startServer(settings?, options?, reuse?)`:**
- Creates a temp root with `mkdtemp(os.tmpdir(), 'mewtphotos-test-')`, a SQLite DB at `<root>/test.db`, and a destination at `<root>/backup`.
- Saves settings with test-friendly defaults (`organizeByDate: false`, `minFreeBytes: 0`, `quotaBytes: 0`, `maxFileBytes: 1 GiB`).
- Builds the real Fastify app via `buildApp({ db, port: 0, lanIp: null, webDir: <nonexistent> })`. No mocking of the HTTP layer.
- Pairs a phone automatically: POSTs the current pairing code from `pairing.current().code` to `/api/v1/pair` with `remoteAddress: PHONE_IP` and stores the returned token.
- Returns a `TestServer` with ready-made helpers:
  - `phone({ method, url, payload?, headers? })`: `app.inject` as the paired phone (adds `authorization` header and LAN `remoteAddress`).
  - `newSession(selectedCount?)`: creates a sender session and returns its id.
  - `upload(sessionId, filename, data, { claimSha?, lastModified? })`: runs the full create -> PATCH -> finish chunked flow.
- The `reuse` parameter reopens an existing root/db/token to simulate a restart (see the "restarts and recovery" tests).

**`rawRequest(port, opts, send)`:**
- Real-socket `http.request` helper for cases that `app.inject` cannot model: streaming bodies, connection cuts mid-chunk, and stalled chunks. Use it only when the behavior depends on the real socket.

**`sha256(data)`:** Reference hash via `node:crypto`. Used to build expected values; the browser-side hash under test is compared against it.

**Constants:** `PHONE_IP = '192.168.1.50'` is the LAN address used to pass `isLocalNetworkAddress` checks. Use `remoteAddress: PHONE_IP` for phone requests; `127.0.0.1` for dashboard (admin) requests.

## Mocking

**Framework:** None. The codebase contains no `vi.mock`, `vi.fn`, `vi.spyOn`, or other Vitest mocking calls.

**Approach:**
- Tests run the real server, real SQLite (`node:sqlite`), and real filesystem in temp directories. This is deliberate and is stated in `README.md` ("Transfer engine, integrity, recovery, security rules: 49 automated tests").
- Failure modes that are hard to produce naturally are injected through real seams, not mocks:
  - `AppOptions.freeBytes` simulates a full disk (`server/app.ts`).
  - `autoStop` exported timers are mutated so the dashboard-stop tests do not wait 20-30 seconds.
  - `timeouts.chunkIdleMs` (exported from `server/engine.ts`) is shortened to test stalled chunks.
  - Corruption is produced by sending a wrong `claimSha` or by editing files on disk, not by stubbing hash functions.
  - Crashes are simulated by writing database rows and files directly (`run(...)`, `writeFile(...)`) and then calling `recover(ctx)`.

**What to Mock:**
- Only external boundaries the test cannot reach: the Windows PowerShell call in `picturesDir` (already guarded by platform check and fallback), disk-space queries (via `freeBytes`), and time-based timers (via exported config objects).
- Prefer adding an injectable option like `freeBytes` over introducing a mocking library.

**What NOT to Mock:**
- The HTTP layer, the database, the filesystem, the hashing code, and the pairing/token logic. These are the behaviors under test.
- Do not add `vi.mock` for the `node:sqlite` module; use a temp database file.

## Fixtures and Factories

**Test Data:**
- Random binary payloads from `node:crypto`'s `randomBytes(n)` for file contents, so hashes are unique and tests do not share state:
  ```typescript
  const data = randomBytes(300_000);
  ```
- Boundary sizes are enumerated in tables inside a single test (`[0, 1, 55, 56, 63, 64, 65, ...]` in `tests/units.test.ts`) rather than separate tests.
- Filenames and hostile inputs are inline literals (`'../../Windows/System32/evil.jpg'`, `'CON.jpg'`).
- Session creation is done through the API (`s.newSession()`), not by inserting rows directly, unless the test is about recovery.

**Location:**
- Inline in each test file. There is no fixtures directory and no factory module beyond `tests/helpers.ts`.
- Temp data is created under `os.tmpdir()` by `startServer` and removed in `afterEach`. Do not write fixtures into the repo. Note `.tmp-tests/` is listed in `.gitignore` but is not used by the current tests.

## Coverage

**Requirements:** None enforced. No coverage thresholds are configured in `vitest.config.ts`, and no coverage provider is installed.

**View Coverage:**
```bash
npx vitest run --coverage   # requires installing @vitest/coverage-v8 first
```

## Test Types

**Unit Tests (`tests/units.test.ts`, 9 `it` blocks):**
- Pure functions with no I/O: `Sha256` (browser-side hasher from `shared/sha256.ts`), `sanitizeFilename`, `safeMediaFilename`, `resolveInside`, `isLocalNetworkAddress`, and `Pairing` (code acceptance, rotation, throttling).
- Include the published SHA-256 test vector (`'abc'`) alongside property-style size/chunking loops.

**Integration Tests (`tests/engine.test.ts`, 39 `it` blocks):**
- Full Fastify app built with `buildApp`, driven with `app.inject` or real sockets via `rawRequest`.
- Real SQLite and real filesystem in temp dirs.
- Covers upload dedupe, chunk resume, offset validation, hash mismatch rejection, crash recovery (`recover(ctx)`), verification (`verifyBackup`), access control (local-network-only, paired-device token, cross-origin refusal), and the dashboard auto-stop timers.

**E2E Tests:**
- Not used. Real iPhone behavior is explicitly untested and is covered by the manual checklist in `docs/iphone-test-checklist.md`. Do not claim phone-side behavior is verified by automated tests.

**Web UI tests:**
- None. `web/src/` has no test files, and the Vitest `include` pattern excludes it. The browser SHA-256 is covered only through `tests/units.test.ts`.

## Common Patterns

**Async Testing:**
```typescript
it('stores the file again if the earlier copy was deleted from disk', async () => {
  const s = await server();
  // ... await s.upload(...) then await rm(...) then await s.upload(...) again
});
```
Every test that touches the server is `async` and awaits each `phone`/`upload` call. Do not leave promises floating; `afterEach` closes the server and the next test starts clean.

**Error Testing:**
```typescript
// Synchronous throw (units)
expect(() => safeMediaFilename('setup.exe', '')).toThrow(HttpError);

// Error object fields (units): read the status off the caught error
let last: unknown;
for (let i = 0; i < 9; i++) {
  try { pairing.consume('AAAAAAAA', '10.0.0.3'); } catch (err) { last = err; }
}
expect((last as HttpError).status).toBe(429);

// HTTP error (integration): assert the response body
expect(early.statusCode).toBe(409);
expect(early.json()).toMatchObject({ error: 'incomplete', offset: 40_000 });
```

**Restart / Recovery Testing:**
- Reuse the same temp root, DB, and token via `startServer(undefined, undefined, { root, db, token })` after closing the previous app, then call `recover(ctx)` or start a new app to observe persisted state.
- Simulate a crash by writing the intermediate DB state directly and then running recovery (see "restarts and recovery" in `tests/engine.test.ts`).

**Timing-sensitive Testing:**
- Override exported timers rather than sleeping:
  ```typescript
  autoStop.graceMs = ...; // restored in test cleanup
  timeouts.chunkIdleMs = ...;
  ```
  Restore any mutated exported config in the test or its `finally` so later tests are unaffected.

## Writing New Tests: Guidelines

1. Put pure-logic tests in `tests/units.test.ts`; put anything that needs the HTTP app, DB, or disk in `tests/engine.test.ts` under the matching `describe`.
2. Use the `server()` wrapper so teardown is automatic. Do not construct `buildApp` directly in a test.
3. Assert the stable error `code` and status, not just that something threw.
4. Use `randomBytes` for payloads and `sha256()` from `tests/helpers.ts` for expected hashes.
5. Do not add mocks for the database, filesystem, or HTTP layer; use the existing seams (`freeBytes`, `autoStop`, `timeouts`).
6. Keep the test name a behavior sentence that a user of the app would recognize.
7. Run `npm test` and `npm run typecheck` before finishing.

---

*Testing analysis: 2026-10-11*
