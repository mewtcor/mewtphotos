# iPhone device test: Phase 1

This test decides whether Phase 2 may start. Run it in one sitting, with the PC and the iPhone both on the same Wi-Fi.

Record the iOS version: ____   iPhone model: ____   AltStore version: ____

Note: iOS 18.0 to 18.5 can mis-handle the Local Network prompt. Write the iOS version above so a failure can be read against it.

## Before you start

- The PC app is running (`Start Backup.cmd`), and the dashboard shows the PC address and a current pairing code.
- AltServer is running on the PC, and the iPhone is on the same Wi-Fi.
- **Do not keep pressing Pair with a wrong code.** The PC allows 8 wrong tries per 5 minutes. After that it refuses every try until the window passes.

## 0. Get the two builds onto the phone

Build A is run 5 and build B is run 6, both from commit `80b543d`. On the PC, run:

- `gh run download 38184634926 -n MewtPhotos-ipa -D MewtPhotos-build-A`
- `gh run download 38184683733 -n MewtPhotos-ipa -D MewtPhotos-build-B`

Copy `MewtPhotos.ipa` from each folder to iCloud Drive as `MewtPhotos-build-A.ipa` and `MewtPhotos-build-B.ipa`.

- [ ] Both files are in Files on the iPhone.

Outcome: ____

## 1. Install build A

- [ ] In AltStore on the iPhone, go to My Apps, tap +, and pick `MewtPhotos-build-A.ipa`.
- [ ] One Mewt Photos icon is on the Home Screen, and one entry is in My Apps.

Outcome, and any AltStore error number: ____

## 2. First launch

- [ ] Open MewtPhotos.
- [ ] Note whether the Local Network question appears, and before or after tapping Pair.
- [ ] The About section reads "Version 0.1.0 (build N)". N is 5 for build A.

Outcome: ____

## 3. Pair

- [ ] Type the PC address (with the port) and the code, then tap Pair.
- [ ] Expect "Paired with" and then "Connected to" the PC name.
- [ ] The dashboard lists the iPhone as a paired device.

Outcome, including the first attempt: ____

## 4. Relaunch

- [ ] Swipe the app away and reopen it.
- [ ] Expect "Connected to" with nothing typed.

Outcome: ____

## 5. AltStore refresh

- [ ] In AltStore, go to My Apps and tap Refresh All. AltServer must be running and the phone on the same Wi-Fi.
- [ ] Open MewtPhotos.
- [ ] Expect "Connected to" still shown.
- [ ] Note whether the Local Network question came back.

Outcome: ____

## 6. Install build B over build A

- [ ] In AltStore, tap + and pick `MewtPhotos-build-B.ipa`.
- [ ] One icon only. About now reads build 6.
- [ ] Pairing is still present.

Outcome: ____

## 7. Export the log

- [ ] Open Mewt Photos, tap Export log, then Save to Files.
- [ ] Copy the file to the PC and open it.
- [ ] Find the `launch` lines. Check that each has `version`, `build`, `sha`, `bundle`, `alt_bundle`, `keychain` and `pairing`.
- [ ] After pairing, `keychain=found` and `pairing=present`.
- [ ] `bundle` is the same before and after the refresh.
- [ ] Search the file for `Bearer`. It must find nothing.

Paste only the `launch` lines into the Results table. Do not paste anything else from the log.

Known gap: the app does not write the connection result or pairing error codes to the log. For a failed connection, write the exact message shown on screen.

Outcome: ____

## 8. Optional: unreachable PC

- [ ] Stop the PC app, then relaunch Mewt Photos on the phone.
- [ ] Expect "Cannot reach your PC right now." followed by a next step.
- [ ] Start the PC app again.

Outcome: ____

## 9. Mac minutes

- [ ] On GitHub: Settings, Billing and licensing, Usage. Filter to Actions and this month.
- [ ] Note the macOS minutes used, and compare with the baseline in `01-GATE.md`.

Outcome: ____

## Results

| Step | Result | Note |
|------|--------|------|
| 1 Install A | | |
| 2 First launch | | |
| 3 Pair | | |
| 4 Relaunch | | |
| 5 Refresh | | |
| 6 Install B | | |
| 7 Log lines | | |

## Gate conditions

- [ ] The unsigned build installs with AltStore. (yes / no)
- [ ] It reaches the PC over plain HTTP. (yes / no)
- [ ] The device key survives a relaunch and an AltStore refresh. (yes / no)

Decision: go / no-go. If no-go, the failing step: ____
