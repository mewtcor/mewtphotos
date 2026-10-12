# Phase 4: Pair and see what's missing

Requirements: PAIR-01, PAIR-04, PAIR-05, LIB-01 to LIB-08. Nothing is sent to the PC in this phase; it only
pairs, checks access, and counts what the PC does not have yet.

## Plan 04-01: pairing by QR, plain-English failures, paired-PC management (PAIR-01, PAIR-04, PAIR-05)

- The QR code's text (`http://HOST:PORT/#pair=CODE`) is passed straight to `PairingFlow.pair`, which already reads the
  code from the link. The app adds the camera scanner that feeds it (PAIR-01).
- The "could not reach" message names the likely causes: Wi-Fi, PC app not running, Windows Firewall, Local Network
  access. The Settings link appears in the app (PAIR-04).
- `PairingFlow.changeAddress` keeps the same key and only changes where the record points, after the PC confirms it
  still accepts this iPhone. `PairingFlow.forget` removes the key and the record (PAIR-05).

## Plan 04-02: library access (LIB-01, LIB-02, LIB-03)

- `LibraryAccess` maps the Photos authorization states to what the app may do: full access runs; limited access
  shows a persistent warning and runs nothing; denied and restricted show guidance (LIB-01, LIB-02).
- The state is read at the start of each count and when the app becomes active, so a change in Settings is noticed
  (LIB-03).

## Plan 04-03: the count of items the PC does not have (LIB-04 to LIB-08)

- The app lists the whole library newest first, including hidden items and every burst frame, and leaves out
  shared-album and Recently Deleted items (LIB-04 to LIB-07). Shared-album and Recently Deleted items are not in the
  default library fetch; the app asks for the library fetch only.
- `ServerClient.knownAssets` asks the PC, in batches of 5,000 (the server cap), which asset identifiers it already
  holds (`/api/v1/assets/check`). The count shown is the number not known (LIB-08).
- Known limit: the PC only knows assets sent with an identifier. Until Phase 5 sends photos, every item counts as not
  on the PC. That is the true answer, not a fault.

## Acceptance

- Core logic is tested on Linux (`swift test`): pairing changes, library access rules, the known-assets batching.
- One Mac build carries all three plans. Device test: scan the QR code, see the paired PC, change its address, forget
  it, deny and then allow photo access, and see the count.
