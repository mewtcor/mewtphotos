# Pairing

Pairing turns the 8-character code shown on the PC dashboard into a device key that the phone uses for every later request. A wrong code is refused and throttled; a removed device must pair again.

## Sub-features

- `pair-ok` a correct code returns a token and registers the device.
- `pair-wrong` a wrong code is refused with `bad_pairing_code`.
- `pair-throttle` repeated wrong codes are refused with `too_many_attempts`.
- `pair-rotate` the code changes after a successful pairing.
- `pair-revoke` a removed device gets `unauthorized` on its next call.

## How to get to it (user POV)

- The phone enters (or scans) the code from the dashboard's "Connect the iPhone" card; the app sends `POST /api/v1/pair`.
- The PC user removes a device with `Remove` under `Paired devices` on the dashboard.

## Driving it with the phone API on loopback

Preconditions: a healthy instance from `vs.mjs launch`, no devices paired.

- **Read the code.** `GET /api/v1/admin/pairing`. Response has `code` (8 characters) and `expiresAt`. `url` and `qrSvg` are `null` on the loopback-only instance; that is expected.
- **Wrong code.** `POST /api/v1/pair` with `{"code":"AAAAAAAA","deviceName":"bad"}`. Status 403, error `bad_pairing_code`. `GET /admin/overview` still shows no devices.
- **Correct code.** `POST /api/v1/pair` with the real code and `{"deviceName":"verify"}`. Status 200 with `token` and `deviceId`. `GET /admin/overview` lists one device named `verify`; `GET /api/v1/status` with `Authorization: Bearer <token>` returns `deviceName: "verify"`.
- **Code rotates.** `GET /admin/pairing` again. `code` differs from the one just used, and pairing a second time with the old code returns 403.
- **Revoke.** Dashboard: choose `Remove` next to the device (or `DELETE /api/v1/admin/devices/<deviceId>`). `GET /api/v1/status` with the old token returns 401 `unauthorized`.
- **Throttle.** Send wrong codes repeatedly from the same address until the response becomes 429 `too_many_attempts`. Do this last: the lockout lasts minutes and blocks later pairing from loopback. Relaunch (`stop`, `launch`) to reset it.

## Gotchas

- The throttle is per source address; on loopback it locks out your own later pairing. Run `pair-throttle` last or on a throwaway instance.
- A correct pairing consumes the code. Fetch it fresh before every pair call.
- Codes are case-insensitive and punctuation is ignored, so do not use a case change as the "wrong" code.
- Pairing over the real LAN, scanning the QR and the iOS pairing screen are not covered here.
