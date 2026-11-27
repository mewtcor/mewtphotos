# External Integrations

**Analysis Date:** 2026-10-11

The app is intentionally self-contained: no cloud service, no account, no third-party API. All integrations are local-network, local-filesystem, or OS-level.

## APIs & External Services

**Third-party APIs:**
- None. No outbound HTTP calls to external hosts were found in `server/` or `web/src/`. The only `fetch` calls target the app's own API (`web/src/api.ts`, and `fetch('http://127.0.0.1:8787/...')` in `server/main.ts` for the already-running check).

**Local OS integrations (invoked by the server):**
- Windows PowerShell - `powershell.exe -NoProfile -NonInteractive -Command "[Environment]::GetFolderPath('MyPictures')"` to find the real Pictures folder, which may be redirected to OneDrive (`server/config.ts`, `picturesDir()`). Timeout 15 s; falls back to `os.homedir()/Pictures`.
- Windows `cmd /c start` - opens the dashboard URL in the default browser after startup (`server/main.ts`, `openDashboard()`). Skipped with `--no-open` or `-NoBrowser`.
- `node:os` `networkInterfaces()` - selects the LAN IPv4 address shown to the iPhone; virtual adapters (WSL, Hyper-V, Docker, VPN, Tailscale, ZeroTier, Bluetooth) are deprioritized (`server/security.ts`, `pickLanAddress()`).

**Client-side browser APIs used by the phone page (`web/src/`):**
- `XMLHttpRequest` - chunk uploads with progress (`web/src/uploader.ts`). Chosen because it is the only way to get upload progress in Safari.
- `fetch` - JSON API calls (`web/src/api.ts`).
- `localStorage` - stores the device credential under key `mewtphotos.deviceToken` (`web/src/api.ts`).
- `EventSource` (Server-Sent Events) - live dashboard updates from `GET /api/v1/admin/events` (`server/app.ts`, line ~427).
- Browser file picker (`<input type="file">`) - source of photos and videos on the iPhone (`web/src/Phone.tsx`).

## Data Storage

**Databases:**
- SQLite, embedded, via Node's built-in `node:sqlite` (`DatabaseSync`).
  - File: `mewtphotos.db` inside the data directory (`%LOCALAPPDATA%\MewtPhotos` by default, override with `MEWTPHOTOS_DATA_DIR`). Path built in `server/main.ts`, opened in `server/db.ts` (`openDb`).
  - Client: none; raw SQL in `server/db.ts` (schema) and `server/engine.ts`, `server/app.ts`.
  - Journal: WAL, `synchronous=FULL`, `foreign_keys=ON`, `busy_timeout=5000`.
  - Tables: `settings`, `devices`, `sessions`, `files` (one row per distinct SHA-256), `uploads` (one row per transfer attempt), `logs`.
  - Schema is created with `CREATE TABLE IF NOT EXISTS` on each start (no migration tool).

**File Storage:**
- Local filesystem only. Photos and videos are written to the configured backup folder (default `<Pictures>\iPhone Backup`), organized as `YYYY\MM\` (`server/engine.ts`, `server/metadata.ts`).
- Partial uploads are staged in `<backup folder>\.incoming` before an atomic rename into place (`server/engine.ts`).
- Probe file `.mewtphotos-write-test-<pid>` is written and removed to validate a destination (`server/config.ts`, `validateDestination()`).
- Free space is checked with `statfs` (`server/app.ts`); quota enforced against SQLite totals (`server/engine.ts`).
- No cloud storage, no object store, no network share adapters (a UNC or mapped drive works only because it is a normal path to Node's `fs`).

**Caching:**
- None. The only in-memory state is the pairing code, failure counters, and SSE subscribers in process memory (`server/security.ts`, `server/app.ts`).

## Authentication & Identity

**Auth Provider:**
- Custom. No external identity provider.
  - Dashboard (PC): no login. Admin routes under `/api/v1/admin/...` accept only loopback requests (loopback socket and `127.0.0.1`/`::1` `Host` header), per README.
  - Phone (sender): one-time 8-character pairing code shown on the dashboard, valid 10 minutes, rotated on each successful use, with per-IP throttling after 8 wrong attempts in a 5-minute window (`Pairing` class, `server/security.ts`).
  - Device credential: 256-bit random token generated with `randomBytes(32)` (`newToken()`), base64url-encoded. The phone holds it in `localStorage`; the PC stores only its SHA-256 hex digest in `devices.token_hash` (`hashToken()`). Compared with `timingSafeEqual` for the pairing code.
  - Sent as `Authorization: Bearer <token>` (`web/src/api.ts`, `authHeader()`).
  - Revocation: device row gets `revoked_at` from the dashboard (`DELETE /api/v1/admin/devices/:id`, `server/app.ts`).
- Access control on the network: requests must come from loopback, RFC 1918 (10/8, 172.16/12, 192.168/16), link-local (169.254/16), or IPv6 ULA/link-local (`isLocalNetworkAddress()`, `server/security.ts`).
- Cross-origin protection: browser requests with a foreign `Origin` are rejected (README, `server/app.ts`).

## Monitoring & Observability

**Error Tracking:**
- None. No Sentry, Rollbar, or similar SDK.

**Logs:**
- Application log written to `server.log` in the data directory (`server/main.ts`, `logFile`). Also mirrored to console.
- Structured events stored in the `logs` SQLite table (`level`, `code`, `message`) via `ctx.log()` (`server/app.ts`, `server/engine.ts`).
- Logs deliberately exclude keys, pairing codes, and file content (README). Log file is not rotated (README "Known gaps").
- Live events pushed to the dashboard over SSE (`GET /api/v1/admin/events`).

## CI/CD & Deployment

**Hosting:**
- Not hosted. Runs on the user's Windows PC.

**CI Pipeline:**
- None detected. No `.github/workflows`, no CI config files found in the repository root.

**Launcher / distribution:**
- `Start Backup.cmd` -> `scripts/start-backup.ps1`. Checks Node >= 22.18, runs `npm install` if `node_modules` is missing, runs `npm run build` if `web/dist/index.html` is missing, then runs `node server/main.ts`.
- The launcher does not install system software, change firewall rules, or set persistent environment variables (per script header).

## Environment Configuration

**Required env vars:**
- None. The app runs with defaults.

**Optional env vars:**
- `MEWTPHOTOS_PORT` - listening port (default `8787`).
- `MEWTPHOTOS_HOST` - LAN address override for the iPhone URL and QR code.
- `MEWTPHOTOS_DATA_DIR` - database and log directory.

**Secrets location:**
- No application secrets are configured by the operator. The device tokens are generated at pairing time; the PC keeps only hashes in `mewtphotos.db` (inside the data directory, outside the repo). The phone keeps its token in Safari `localStorage`.
- No `.env` files detected in the project root.

## Webhooks & Callbacks

**Incoming:**
- None. The server accepts only the app's own versioned API (`/api/v1/...`, defined in `server/app.ts`). Key sender-facing endpoints: `POST /api/v1/pair`, `GET /api/v1/status`, `POST /api/v1/sessions`, `POST /api/v1/uploads`, `PATCH`/`GET`/`DELETE /api/v1/uploads/:id`, `POST /api/v1/uploads/:id/finish`, `POST /api/v1/files`, `GET /api/v1/files/:sha256`, `POST /api/v1/assets/check`. Full contract in `docs/api.md`.
- Optional Apple Shortcut sends files to the same API (`docs/ios-shortcut.md`). Not a webhook; it is a client.

**Outgoing:**
- None. The server never initiates outbound requests to other hosts.

---

*Integration audit: 2026-10-11*
