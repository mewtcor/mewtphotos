# Mewt Photos

The iOS app is "Mewt Photos": bundle ID `com.mewtcor.mewtphotos`, product and `.ipa` name `MewtPhotos`, icon source in `ios/art/` (`python ios/art/render.py` rebuilds the asset-catalog PNG).

Backs up an iPhone's photos and videos to a Windows PC over home Wi-Fi: no cloud, no cost. A Node server on the PC receives, verifies and files the media; the phone side is a native iOS app (`ios/`), with the older Safari page (`web/`) still served. Personal tool: one user, one iPhone, one PC.

**Core value:** every photo and video reaches the PC as its untouched original (both halves of Live Photos), and nothing is reported backed up unless the PC has verified it.

Docs: `README.md`, `docs/` (`api.md`, `ios-install.md`, `ios-builds.md`, `troubleshooting.md`). Planning: `.planning/` (GSD).

## Constraints

- **Free:** no paid Apple membership, no Mac. iOS builds run only on GitHub Actions macOS runners; the free allowance is roughly 20–40 builds a month, so builds must be few and deliberate.
- **Install:** unsigned `.ipa` via AltStore with a free Apple ID (7-day expiry). When copying an `.ipa` into iCloud Drive (`MewtPhotos\`), always include the build number in the filename: `MewtPhotos-b<build>.ipa` (e.g. `MewtPhotos-b41.ipa`).
- **No on-device debugger:** the app needs good in-app logging and log export.
- **Server compatibility:** reuse `/api/v1`; server changes must be small, additive and covered by tests.
- **Platform:** iOS 18+, Windows 11. Plain HTTP on the LAN (ATS local-networking exception).
- **Safety:** never delete or modify photo library assets.
- **Truthfulness:** never show an item as backed up unless the server returned `verified` or `duplicate`.
- **Deps:** Swift/SwiftUI/PhotoKit/URLSession; as few third-party packages as possible on either side.

## Commands

```bash
npm start            # server (Node runs TS directly, no build step); also Start Backup.cmd
npm test             # Vitest, tests/*.test.ts
npm run typecheck    # tsc --noEmit (the only lint)
npm run build        # Vite -> web/dist; required after any web/src change
npm run dev:web      # Vite dev server, proxies /api to 127.0.0.1:8787
npm run verify       # re-hash every stored file
python ios/scripts/check_info_plist.py ios/MewtPhotos/Info.plist
gh workflow run ios-build.yml   # macOS build, manual only; costs build budget
```

`ci.yml` runs free on every push (Windows + Ubuntu): npm test, typecheck, Info.plist check, `swiftc -parse` of the app, and MewtPhotosCore checks against a real server. Let it pass before spending a macOS build. Record each iOS build in `docs/ios-builds.md`.

## Layout

- `server/`: `main.ts` (entry), `app.ts` (all routes in `buildApp`), `engine.ts` (upload/verify/place, decides "safely stored"), `db.ts` (`node:sqlite`, schema string, `tx`), `config.ts`, `security.ts` (pairing, tokens, `HttpError`, `resolveInside`), `metadata.ts`, `verify.ts`.
- `shared/schemas.ts`: the API contract (paths, `CHUNK_SIZE`, Zod schemas) for server, web and tests. Add API constants here first.
- `web/src/`: React dashboard (`/dashboard`) and phone page (`/`).
- `ios/`: XcodeGen project (`project.yml`), app in `ios/MewtPhotos/`, logic in the `ios/Packages/MewtPhotosCore` Swift package.

## Rules and gotchas

- Nothing reports success before the DB commit: file fsynced, re-read and hashed, renamed, then row committed.
- Throw `HttpError(status, code, message)` with a stable snake_case code; don't format errors in routes. Validate bodies with Zod at the route.
- Any write under the backup folder goes through `resolveInside`; client filenames through `sanitizeFilename`/`safeMediaFilename`.
- Multi-statement DB writes use `tx()`. No migration framework: change the `SCHEMA` string in `server/db.ts` idempotently.
- Never log tokens, pairing codes or the `Authorization` header. No `console` outside `server/main.ts` and `server/verify-cli.ts`; use `ctx.log`.
- `tsconfig` has `erasableSyntaxOnly` and `verbatimModuleSyntax`: no `enum`, namespaces or parameter properties; use `import type`; imports use `.ts` extensions. Named exports only.
- Safari disables `crypto.subtle` on plain http, so the phone page uses `shared/sha256.ts`.
- iOS: `import Photos`/`PhotosUI` only in `DiagnosticsView.swift`, `LibraryView.swift`, `BackupEngine.swift` (CI enforces this).
- Settings are cached in `buildApp`; another process writing them isn't seen until restart.

## Workflow

Prefer GSD (`/gsd-quick`, `/gsd-debug`, `/gsd-execute-phase`) for non-trivial changes so `.planning/` stays in sync; trivial edits may go direct.
