# Phase 4 gate: pair and see what's missing

Build 14 (commit `3be0796`, run `38248942719`), tested on the iPhone.

| Check | Result |
|-------|--------|
| Forget this PC, then pair again by scanning the dashboard QR code | Pass |
| Save a wrong address | Error shown; old pairing kept |
| Save the correct address | Saved, no error |
| Photo access message with full access | Pass: "PhotoSync can read your whole library." |
| Count of items not on the PC | Pass: 4063 of 4063 (nothing sent yet, so all are not on the PC) |

Not tested on the device: the "Open Settings" button, the limited and denied access states, and the change being noticed when the app returns to the front. These need Photos access changed in Settings.

Known gap: a successful address save shows no confirmation. Add a short "Address saved" line in a later build.

Decision: pending the user's go.
