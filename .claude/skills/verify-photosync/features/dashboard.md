# PC dashboard

The dashboard at `/dashboard` is what the PC user sees: server state, backup totals, the latest session, failures, history, paired devices, the log, the backup folder setting and a stop button. It is reachable only from the PC itself.

## Sub-features

- `dash-totals` the `Backup totals` tiles match the stored files.
- `dash-session` `Latest backup session` shows selected, submitted, received, verified, duplicates, failed and unavailable, plus a truthful message.
- `dash-failures` `Failed uploads` lists failures, or `None.`
- `dash-devices` `Paired devices` lists devices and `Remove` revokes one.
- `dash-settings` changing `Backup folder (full path)` and choosing `Save` applies to new uploads.
- `dash-local-only` admin endpoints refuse non-loopback callers.
- `dash-stop` `Stop backup app` shuts the server down.

## How to get to it (user POV)

- Open `http://127.0.0.1:<port>/dashboard` in a browser on the PC (the Start Backup launcher opens it automatically).

## Driving it with the built-in browser

Preconditions: healthy instance with at least one verified file (run `vs.mjs upload`).

- **Totals.** Navigate to the dashboard and `get_page_text`. Under `Backup totals`: `Files stored` 1, `Verified end to end` 1, `Failed uploads` 0. These agree with `GET /api/v1/admin/overview` `totals`.
- **Session.** `Latest backup session` shows the device `verify-photosync`, `native`, and the sentence `All selected files transferred successfully. Complete iPhone photo library coverage has not been verified.` `In iPhone library` reads `Unknown`. The page must never claim full library coverage.
- **Failures.** After a `hash_mismatch` upload, reload: `Failed uploads` count rises and the list names the file. With none, it reads `None.`
- **Devices.** Under `Paired devices` click `Remove` next to the device. The row disappears and the old token gets 401.
- **Settings.** Put another absolute folder inside `.verify/run/` (for example `.verify/run/backup2`) in `Backup folder (full path)` and click `Save`. The log gains `Backup folder changed to ...`. A relative path shows the message `Enter a full path such as D:\Photos\iPhone Backup.`
- **Local only.** `curl -H "Host: example.com" http://127.0.0.1:<port>/api/v1/admin/overview` returns 403 `admin_local_only`.
- **Stop.** Click `Stop backup app`. The page shows `The backup app has been stopped.` and `/api/v1/health` stops answering. Run `vs.mjs stop` afterwards to clear state.
- **Proof.** Save each `get_page_text` result into the evidence folder (`dashboard-<sub-feature>.txt`) and take a screenshot with the browser tool.

## Gotchas

- The `Connect the iPhone` card always shows `iPhone cannot connect yet` on the loopback-only instance. That is the harness, not a regression.
- `launch` sets `stopWithDashboard: false`. With the default (`true`) the server stops itself shortly after the last dashboard tab closes, which looks like a crash.
- The dashboard refreshes from a Server-Sent Events stream; after an API call wait a moment or reload before reading the text.
- If `web/src` changed, `npm run build` first or the dashboard shows the old UI.
- The dashboard is rendered by React from `web/dist`; the older phone page (`/`) is separate and not covered here.
