# Phase 4 gate: pair and see what's missing

Build 14 (commit `3be0796`, run `38248942719`) and build 15 (commit `c14c3bd`, run `38250446045`), tested on the iPhone.

| Check | Build | Result |
|-------|-------|--------|
| Forget this PC, then pair again by scanning the dashboard QR code | 14 | Pass |
| Save a wrong address | 14 | Error shown; old pairing kept |
| Save the correct address | 14 | Saved, no error |
| Save the correct address shows "Address saved." | 15 | Pass |
| Photo access message with full access | 14 | Pass: "PhotoSync can read your whole library." |
| Count of items not on the PC | 14 | Pass: 4063 of 4063 (nothing sent yet, so all are not on the PC) |
| Limited access: warning shown, no count | 15 | Pass |
| Denied access: guidance and Open Settings | 15 | Pass |
| Return from Settings: state updates without a restart | 15 | Pass |

Decision: go. Phase 4 requirements PAIR-01, PAIR-04, PAIR-05 and LIB-01 to LIB-08 are covered by the device results above.

Notes for later:
- Restricted access (Screen Time) was not tested. The message is in place.
- The count shows every item as not on the PC until Phase 5 sends photos.
