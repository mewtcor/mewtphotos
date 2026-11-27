# Mewt Photos verification map

This directory is the maintained source for verifying the user-facing behavior of MewtPhotos. Read this index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch with `node .claude/skills/verify-mewtphotos/scripts/vs.mjs launch` (loopback only, scratch data dir, scratch backup folder under `.verify/run/`).
- Run `... vs.mjs doctor` and require `ok: true` before driving.
- Base URL is `http://127.0.0.1:<port>` with the port from `launch` (default 8899). API base is `/api/v1`.
- The database starts empty: no devices, no sessions, no files. Pair a device before any sender call (see `pairing`).
- Never drive the user's real backup app (port 8787) or its data in `%LOCALAPPDATA%\MewtPhotos`.

## Driving conventions

- Prefer the phone API on loopback for sender behavior and the dashboard in the built-in browser for what the PC user sees.
- Find dashboard elements by visible heading or button text; there are no test IDs.
- Quote file names, headers and bodies exactly as in `docs/api.md`.
- Use a fresh random file per run: identical content is a duplicate on the second run only if the same database is reused, and `launch` resets the database.
- Stop the instance when done (`vs.mjs stop`); evidence is kept.

## Proof and skip reporting

- Capture the request, the response and a second view of the state (file on disk, overview totals, dashboard text).
- A mutation counts as proved only when the stored bytes re-hash to the sender's SHA-256.
- Report an unreachable path with the attempted call and the unmet precondition. Do not report a skipped entry point as verified through a different path.
- Things this harness cannot cover (LAN, firewall, the iOS app, the Safari phone page's JavaScript) are reported as not covered, never as passed.

## Features

- [Pairing](./pairing.md) covers the code, the token, wrong codes and removing a device.
- [Upload and verify](./upload-and-verify.md) covers the chunked flow, the hash check, resume and failures.
- [Duplicates and incremental check](./duplicates.md) covers re-announced content, `GET /files/:sha256` and `POST /assets/check`.
- [PC dashboard](./dashboard.md) covers the totals, session view, settings and stop button.
- [Verify stored files](./verify-stored.md) covers the dashboard button and `npm run verify`.
