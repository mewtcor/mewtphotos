---
name: verify-mewtphotos
description: Launch an isolated Mewt Photos backup server, drive it the way the iPhone and the PC dashboard do (pair, upload, verify, duplicates, dashboard), and capture proof. Use when a server, shared/schemas.ts or web/src change needs evidence that it works in the real app, not just in Vitest. The native iOS app cannot be driven from here (it builds only on GitHub Actions).
---

# Verify Mewt Photos

Mewt Photos is a Node server (Fastify, `node:sqlite`) plus a React dashboard (`/dashboard`) and an older phone page (`/`). The real phone client is a native iOS app that cannot run on this Windows PC, so verification drives the **same `/api/v1` calls the app makes**, from loopback, and reads the dashboard in a browser. Proof of the iOS app itself is a device test, listed in `.planning/` and `docs/ios-builds.md`, not something this skill can do.

Run everything from the repo root. Shell is Git Bash or PowerShell; the helper is plain Node.

```
node .claude/skills/verify-mewtphotos/scripts/vs.mjs <launch|doctor|upload|stop>
```

## Launch

```
node .claude/skills/verify-mewtphotos/scripts/vs.mjs launch [--port 8899]
```

- Starts `server/main.ts --no-open` as a detached child with its own `MEWTPHOTOS_DATA_DIR`, so the user's real database and `Pictures\iPhone Backup` are never touched. Scratch lives in `.verify/run/` (`data/`, `backup/`).
- `MEWTPHOTOS_HOST=''` makes the server bind **loopback only**: no LAN exposure, no Windows firewall prompt. Consequence: the dashboard's "Connect the iPhone" card shows "iPhone cannot connect yet". That is expected here, not a bug.
- Picks the first free port from 8899 (the user's real app uses 8787; the launcher never goes near it).
- Ready means usable: it waits for `/api/v1/health`, then `PUT /api/v1/admin/settings` points the backup folder into `.verify/run/backup` and sets `stopWithDashboard: false` (otherwise closing a dashboard tab stops the server).
- Prints JSON with `pid`, `port`, `dashboard` URL and the evidence folder. State is kept in `.verify/state.json`. Only one instance at a time; `launch` refuses if one is alive.
- First time in a checkout: `npm install` must have been run, and `npm run build` if the dashboard (`web/dist`) is missing or `web/src` changed.

## Doctor

```
node .claude/skills/verify-mewtphotos/scripts/vs.mjs doctor
```

Read-only. Passes only if the recorded pid is alive, the port answers `/health` as `mewtphotos`, the admin overview reports our scratch backup folder (so it is *our* instance, not the user's real one on 8787), and the server is not bound to the LAN. Run it first whenever anything looks off.

## Drive

Three ways, in order of preference. Real handles only; no coordinates.

1. **Phone API (what the iOS app does)**: `vs.mjs upload` runs the whole path: read the pairing code from `GET /api/v1/admin/pairing`, `POST /pair`, `POST /sessions`, `POST /uploads`, `PATCH /uploads/:id` (`Upload-Offset: 0`, `Content-Type: application/offset+octet-stream`), `POST /uploads/:id/finish` with the sender's SHA-256, then a repeat in a second session, session complete, and the admin overview. For anything else (resume, wrong hash, revoked device, unsupported type) call the endpoints directly with `curl` or `fetch` against `http://127.0.0.1:<port>/api/v1`; the contract is `docs/api.md` and `shared/schemas.ts`. Sender endpoints need `Authorization: Bearer <token>`; admin endpoints work from loopback with no key.
2. **Dashboard**: open `http://127.0.0.1:<port>/dashboard` in the built-in browser (`mcp__Claude_Browser__navigate`), then `get_page_text` or `read_page`. The page is plain headings and buttons, so find elements by their text: `Backup totals`, `Latest backup session`, `Verify now`, `Backup folder (full path)` (textbox), `Save`, `Failed uploads`, `Paired devices` and its `Remove` buttons, `Stop backup app`. The tiles are `Files stored`, `Verified end to end`, `Duplicates skipped`, `Failed uploads`.
3. **CLI**: `npm run verify` re-hashes every stored file against the real data dir; for the scratch instance run it with `MEWTPHOTOS_DATA_DIR=<state.data>` (see the feature file).

The feature map in [features/README.md](features/README.md) lists what to cover, with recipes. A proof that drives one convenient entry point is incomplete when the map lists others.

## Evidence

Lives in `.verify/evidence/<timestamp>/` and **survives `stop`**:

- `server.out.log`: the server's stdout/stderr for the run.
- `upload.json`: every step of the upload drive with its result, the stored path, the SHA-256, the session summary and the overview totals.
- Anything you add (dashboard text, screenshots): save it in the same folder and name the feature ID.

Proof standards for this project:

- Exercise the real route, never an internal setter or a test-only endpoint. Tests may use `app.inject`; this skill uses a real socket.
- Capture the action **and** the resulting state. For an upload that means the `finish` response, the file on disk inside the backup folder re-hashed to the same SHA-256, and the dashboard or overview totals.
- The project rule is "nothing is reported backed up unless the PC verified it". Assert that a failed or truncated upload yields no `verified` row, no file under the backup folder, and a `Failed` count, not only that the happy path passes.
- `duplicates` only counts across sessions: re-announcing a hash inside the same session is an idempotent replay and is not counted. Use a second session to prove duplicate detection.
- Never touch `%LOCALAPPDATA%\MewtPhotos` or the user's real backup folder.

## Cleanup

```
node .claude/skills/verify-mewtphotos/scripts/vs.mjs stop
```

Asks the instance to shut down (`POST /admin/shutdown`), waits for **that pid** to exit, force-ends only that pid if needed, then deletes `.verify/run/` (scratch database and backup folder) and `state.json`. It never kills by process name: the user's real backup app is also `node`. Evidence is kept and its path printed. If `launch` or a drive failed halfway, run `stop` anyway before retrying. If the browser pane is still on the dashboard, navigate it away (`about:blank`).

## Gotchas

- `.verify/` is scratch plus evidence; it is gitignored. Do not commit it.
- Settings are cached inside the running server. Changing the scratch database from another process is invisible until restart; change settings through `PUT /admin/settings`.
- Windows only: the helper uses `process.kill(pid)`, and the real server pops the dashboard in a browser unless `--no-open` is given (the launcher always passes it).
- To verify a server code change the instance must be relaunched: Node runs the `.ts` files directly with no build step, but only reads them at startup. `web/src` changes also need `npm run build`.
- Everything here is HTTP on loopback. It does not prove LAN reachability, Windows firewall behaviour, or anything on the iPhone (ATS, background URLSession, PhotoKit). Report those as not covered.
