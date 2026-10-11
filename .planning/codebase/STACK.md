# Technology Stack

**Analysis Date:** 2026-10-11

## Languages

**Primary:**
- TypeScript 7.0.2 (`typescript` devDependency) - all server code (`server/*.ts`), shared schemas (`shared/*.ts`), web UI (`web/src/*.ts`, `web/src/*.tsx`), and tests (`tests/*.ts`). Strict mode, `noEmit` (see `tsconfig.json`).
- TSX/React - dashboard and phone pages (`web/src/Dashboard.tsx`, `web/src/Phone.tsx`, `web/src/main.tsx`).

**Secondary:**
- CSS - `web/src/styles.css` (single stylesheet, supports light and dark via `color-scheme`).
- HTML - `web/index.html` (Vite entry), `web/dist/index.html` (built output, committed to working tree but git-ignored).
- PowerShell 5.1+ - launcher `scripts/start-backup.ps1`, invoked by `Start Backup.cmd`. Also shells out to `powershell.exe` at runtime to read the Windows Pictures known folder (`server/config.ts`).
- Batch - `Start Backup.cmd` (double-click entry point).

## Runtime

**Environment:**
- Node.js >= 22.18 (declared in `package.json` `engines`). Installed locally: v24.16.0.
- The server runs TypeScript directly with Node's type stripping: `node --disable-warning=ExperimentalWarning server/main.ts` (no build step for the server). The `--disable-warning` flag suppresses the Node warning for experimental type stripping.
- Uses Node built-ins only for persistence and crypto: `node:sqlite` (`DatabaseSync`, `server/db.ts`), `node:crypto`, `node:net` (`BlockList` for LAN address checks, `server/security.ts`), `node:child_process`, `node:fs/promises`, `node:http`.
- Target platform: Windows 11 (launcher, `LOCALAPPDATA`, PowerShell, `cmd /c start`). Code also has non-Windows fallbacks (`os.homedir()`), but the product is Windows-only in practice.
- Browser runtime for the phone: iOS Safari (XHR uploads, `localStorage`). No service worker or PWA manifest is present; `web/index.html` sets `apple-mobile-web-app-capable` meta tags for Add to Home Screen.

**Package Manager:**
- npm (version not pinned; `package-lock.json` present and committed to working tree).
- Lockfile: present (`package-lock.json`, lockfileVersion not verified).
- Installer invoked automatically by `scripts/start-backup.ps1` on first run (`npm install` when `node_modules` is missing).

## Frameworks

**Core (server):**
- Fastify 5.12.5 - HTTP server and routing. Built in `server/app.ts` via `buildApp()`. Versioned API under `/api/v1`.
- `@fastify/static` 10.1.6 - serves `web/dist` for the dashboard and phone pages (`server/app.ts`).
- Zod 4.6.5 - request and response validation; schemas live in `shared/schemas.ts` and are reused by the web client.

**Core (web):**
- React 19.3.0 and react-dom 19.3.0 - UI for `web/src/Dashboard.tsx` and `web/src/Phone.tsx`. Entry `web/src/main.tsx` uses `StrictMode` and `createRoot`.

**Testing:**
- Vitest 5.0.3 - test runner. Config: `vitest.config.ts` (`environment: 'node'`, includes `tests/**/*.test.ts`, `testTimeout: 60_000`).
- Test files: `tests/engine.test.ts`, `tests/units.test.ts`, shared helpers in `tests/helpers.ts`. README reports 49 tests.

**Build/Dev:**
- Vite 8.3.4 - dev server and production bundler for the web UI. Config: `vite.config.ts` (`root: 'web'`, output `web/dist`, dev proxy `/api` to `http://127.0.0.1:8787`).
- `@vitejs/plugin-react` 6.1.2 - React transform for Vite.
- TypeScript 7.0.2 - `tsc --noEmit` type checking only (`npm run typecheck`). Compiler options in `tsconfig.json` include `verbatimModuleSyntax`, `erasableSyntaxOnly` (required for Node type stripping), `allowImportingTsExtensions`, `module: preserve`, `moduleResolution: bundler`, `types: ["node", "vite/client"]`.

## Key Dependencies

**Critical (runtime, `dependencies` in `package.json`):**
- `fastify` 5.12.5 - the whole HTTP surface (`server/app.ts`, `server/main.ts`).
- `exifreader` 4.48.0 - reads EXIF `DateTimeOriginal` / QuickTime creation time to choose the `YYYY\MM` folder. Read-only (`server/metadata.ts`). Only the first 1 MiB of each file is parsed.
- `qrcode` 1.5.4 - renders the pairing QR code in the terminal (`server/main.ts`) and as data for the dashboard (`server/app.ts`).
- `zod` 4.6.5 - input validation at the trust boundary (`shared/schemas.ts`, `server/app.ts`, `server/engine.ts`).
- `react` / `react-dom` 19.3.0 - web UI.
- `@fastify/static` 10.1.6 - static asset serving.

**Critical (dev, `devDependencies`):**
- `vite` 8.3.4, `vitest` 5.0.3, `typescript` 7.0.2, `@vitejs/plugin-react` 6.1.2.
- `@types/node` ^26.6.5, `@types/react` / `@types/react-dom` ^19.3.0, `@types/qrcode` ^1.5.6.

**Infrastructure (no dependency, built in):**
- SQLite via `node:sqlite` (`server/db.ts`). Chosen over `better-sqlite3` to avoid native compilation on Windows. Runs in WAL mode with `synchronous=FULL`, `foreign_keys=ON`, `busy_timeout=5000`. Experimental in Node, hence the 22.18 minimum.
- SHA-256 - `node:crypto` on the server (`server/engine.ts`, `server/security.ts`). A hand-written JavaScript implementation is used on the phone page (`shared/sha256.ts`) because Safari disables `crypto.subtle` on plain `http://` origins.
- Network address selection and private-range checks - `node:os` and `node:net` (`server/security.ts`). No third-party network libraries.

**Notable absences (verified):**
- No ORM or query builder; raw SQL in `server/db.ts` and `server/engine.ts`.
- No logging library; logging is a custom function writing to the `logs` table and `server.log` (`server/app.ts`, `server/config.ts`).
- No cloud SDKs, no HTTP client library (server-side), no auth library, no state-management library on the web side.
- No Electron or Tauri. README records a possible future Tauri sidecar only.
- No CSS framework or component library.

## Configuration

**Environment variables (all optional):**
- `PHOTOSYNC_PORT` - HTTP port, default `8787` (`server/main.ts`). Set by `scripts/start-backup.ps1 -Port` for that process only.
- `PHOTOSYNC_HOST` - forces the LAN address shown to the iPhone; overrides auto-detection (`server/main.ts`).
- `PHOTOSYNC_DATA_DIR` - location of `photosync.db` and `server.log`; default `%LOCALAPPDATA%\PhotoSync` (`server/config.ts`).
- `LOCALAPPDATA` / `os.homedir()` - used only to derive the default data directory.

No `.env` loading library is used. No `.env*` files were detected in the repository root.

**Runtime settings (stored in SQLite, not env):**
- Backup destination, organize-by-date toggle, per-file size limit (default 50 GB), optional storage quota (default 0 = unlimited), minimum free space (default 1 GB), concurrency (default 2), and stop-with-dashboard behavior. Defaults in `server/config.ts` (`loadSettings`). Destination default: `<Pictures>\iPhone Backup`.

**Build:**
- `vite.config.ts` - Vite root `web`, React plugin, output `web/dist`, `emptyOutDir: true`, dev proxy for `/api`.
- `vitest.config.ts` - Vitest node environment and test glob.
- `tsconfig.json` - strict type checking across `server`, `shared`, `web/src`, `tests`, and root `*.ts`.
- `.gitignore` - ignores `node_modules/`, `web/dist/`, `*.log`, `.tmp-tests/`.

**Scripts (`package.json`):**
- `npm start` - `node --disable-warning=ExperimentalWarning server/main.ts`
- `npm run build` - `vite build`
- `npm run dev:web` - `vite` dev server for the web UI
- `npm run typecheck` - `tsc --noEmit`
- `npm test` - `vitest run`
- `npm run verify` - `node --disable-warning=ExperimentalWarning server/verify-cli.ts` (re-hash stored files, `server/verify.ts`)

## Platform Requirements

**Development:**
- Windows 11 (documented in `docs/setup-windows.md`; the author's machine runs Node 24.16).
- Node.js 22.18 or newer. No Python, no native build toolchain (`node:sqlite` avoids compilation).
- npm for installing dependencies.

**Production (actual deployment):**
- Runs as a local foreground process on the Windows PC, started by `Start Backup.cmd`. No server hosting, no container, no service install.
- Listens on `127.0.0.1` (dashboard) and the PC's private-range LAN address (iPhone), plain HTTP only.
- Data stored under `%LOCALAPPDATA%\PhotoSync` (SQLite database and log); photos stored under the configured backup folder (default `Pictures\iPhone Backup\YYYY\MM\...`).
- Client: iOS Safari page reached via QR code; optional Apple Shortcut (`docs/ios-shortcut.md`). No native iOS code exists in the repository (`docs/ROADMAP_IOS_COMPANION.md` is a proposal only).

---

*Stack analysis: 2026-10-11*
