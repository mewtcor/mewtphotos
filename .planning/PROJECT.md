# Mewt Photos

## What This Is

Mewt Photos backs up an iPhone's photos and videos to a Windows PC over the home Wi-Fi, with no cloud
service and no cost. A Windows server (already built) receives, verifies and files the media; today
the phone side is a Safari page. This project adds a native iPhone app so that one tap backs up
everything new as untouched originals. It is a personal tool for one user, one iPhone and one PC.

## Core Value

Every photo and video on the iPhone reaches the PC as its untouched original — including both halves
of Live Photos — and nothing is ever reported as backed up unless the PC has verified it.

## Requirements

### Validated

<!-- Inferred from the existing codebase (.planning/codebase/). PC side: 49 automated tests pass. -->

- ✓ Windows server receives files over the LAN with a resumable, offset-based chunk protocol — existing
- ✓ Success is reported only after fsync, SHA-256 re-hash, placement and a committed database row — existing
- ✓ Duplicate detection by content hash; known content is skipped before any bytes are sent — existing
- ✓ Files are organised into `YYYY\MM` folders from EXIF / QuickTime capture date — existing
- ✓ Device pairing by one-time code / QR; only a hash of the device key is stored on the PC — existing
- ✓ Sender API limited to private-network addresses; admin API limited to loopback — existing
- ✓ PC dashboard: live progress, settings, paired devices, failures, "Verify now" — existing
- ✓ `npm run verify` re-hashes every stored file and reports missing, corrupt and untracked files — existing
- ✓ Crash recovery at start-up for interrupted uploads — existing
- ✓ Safari phone page: pair, pick items, upload, per-file status, session summary — existing, confirmed on a real iPhone 2026-10-11 for photos (25 photos stored and verified)
- ✓ API already carries what a native client needs: `assetId`, `/assets/check`, `sha256` on create, `/files` one-shot, `method: "native"`, `libraryCount` — existing, unused so far

### Active

<!-- Hypotheses until shipped and validated on the real iPhone. -->

- [ ] A SwiftUI iPhone app can be compiled without a Mac (GitHub Actions macOS runner) and installed with the existing AltStore setup
- [ ] The app pairs with the PC by scanning the existing dashboard QR code and keeps its key in the Keychain
- [ ] "Back up now" sends every photo and video not yet on the PC, without hand-picking
- [ ] Media arrives as the stored original bytes (HEIC, ProRAW/DNG, HEVC `.mov`), never a converted copy
- [ ] Live Photos arrive as both files (still + paired video) with the same base name, kept together on disk
- [ ] Items stored only in iCloud are downloaded and backed up; any that cannot be fetched are reported as not backed up
- [ ] The app skips what the PC already has (by asset id and by content hash), so repeat runs are fast
- [ ] The app shows progress and a truthful result: its "verified" count always equals the server's
- [ ] Failed and unavailable items are listed and can be retried
- [ ] Large videos transfer at a usable speed and resume after interruption instead of restarting

### Out of Scope

- Background / screen-off / scheduled backups — iOS limits these heavily and they add weeks; revisit after the foreground app works (proposal milestone 5)
- Bonjour auto-discovery and HTTPS with certificate pinning — QR pairing over plain LAN HTTP is enough for v1 (proposal milestone 6)
- Library-vs-server reconciliation report and a "coverage verified" status — later (proposal milestone 7)
- Changes to the Safari page (photos-only toggle, slow video pre-check, vanishing failed items) — user chose to keep it as is and put effort into the app
- Paid Apple Developer membership, buying or renting a Mac — project stays free; accepted cost is a 7-day AltStore refresh
- Deleting or modifying anything on the iPhone, or propagating phone deletions to the PC — backup is strictly one-way and additive
- Any cloud storage or internet-facing service — local network only
- Non-Windows PC support — Windows-only by design

## Context

**Existing system.** Single-process Node.js (>= 22.18, TypeScript run directly) Fastify server with
`node:sqlite`, React 19 web pages built by Vite, Zod schemas shared between server, web and tests.
Full map in `.planning/codebase/` (ARCHITECTURE, STACK, STRUCTURE, CONVENTIONS, TESTING, INTEGRATIONS,
CONCERNS). All stores must go through the transfer engine (`server/engine.ts`); nothing writes into the
backup folder directly.

**Why a native app (findings from real-iPhone testing, 2026-10-11).**
- Photos through the Safari picker arrived as `.jpeg` (converted copies or "Most Compatible" camera
  setting — not determined), not HEIC originals.
- A web page is only handed the still of a Live Photo; the paired video is lost.
- Videos were unusable: three attempts (108–304 MB), none completed. The phone-side pure-JS SHA-256
  pre-check ran at about 4 MB/s (27–80 s wait before the first byte), then transfer ran at roughly
  0.5 MB/s versus about 3.5 MB/s for photos. Cause of the slow transfer not established; a photo batch
  also showed 16 s and 41 s stalls, suggesting Wi-Fi or iOS pausing Safari.
- One video upload (`IMG_2609.mov`) is still recorded as `receiving` with 16 MiB on disk.

**Prior design.** `docs/ROADMAP_IOS_COMPANION.md` is an unprototyped proposal covering architecture
(SwiftUI, PhotoKit, `PHAssetResourceManager`, URLSession), incremental backup, original preservation,
background limits, pairing and an 8-milestone plan. Items marked *(verify)* there are assumptions.
Its milestone 1 (feasibility spikes) decides whether the rest is worth doing.

**Development constraints.**
- Development machine is Windows 11; no Mac. Swift can be written here but not compiled or run.
  Every test round is: push → CI build → install `.ipa` via AltStore → try on the phone. No debugger.
- The user already runs AltStore / AltServer, iTunes and Apple Devices; these must keep working unchanged.
- Target device: the user's iPhone on iOS 18 or newer.
- At project start only the codebase map is committed; all source files are untracked and there is
  no GitHub remote yet.

**Known server issues the app may hit** (from `.planning/codebase/CONCERNS.md`): uploads can stick in
`finalizing` until restart when the final rename fails; `/assets/check` answers "known" from the
database without checking the file on disk; the server's extension allow-list may need sidecar types
(`.aae`) for adjustment data; Live Photo pairs need to land in the same folder.

## Constraints

- **Cost**: Free — no paid developer membership, no Mac purchase or rental. Why: stated project goal.
- **Build**: iOS builds run on GitHub Actions macOS runners from a private repository. Why: no Mac; free allowance for private repos is limited (roughly 20–40 builds a month, to be checked), so builds must be few and deliberate.
- **Install**: Unsigned `.ipa` installed and refreshed by AltStore with a free Apple ID (7-day expiry, limited app count). Why: only free install route from Windows.
- **Debugging**: No on-device debugger. Why: no Mac. The app needs good in-app logging and a way to export logs from day one.
- **Compatibility**: Reuse `/api/v1` as it stands; server changes must be small, additive and covered by the existing test suite. Why: the PC side is working and tested.
- **Platform**: iOS 18+ on the phone, Windows 11 on the PC. Why: the user's actual devices.
- **Network**: Plain HTTP on the local network (ATS local-networking exception). Why: HTTPS pinning is deferred.
- **Safety**: Read-only access to the photo library in effect — never delete or modify assets. Why: this is a backup tool; the phone holds the only other copy.
- **Truthfulness**: Never show an item as backed up unless the server returned `verified` or `duplicate`. Why: core value.
- **Tech stack**: Swift / SwiftUI / PhotoKit / URLSession with as few third-party packages as possible. Why: every dependency lengthens CI builds and cannot be debugged locally.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Build a native iPhone app instead of improving the Safari page | Only a native app can read originals and Live Photo pairs, and real-device testing showed videos unusable via Safari | — Pending |
| Build on GitHub Actions, install with AltStore | Free, and uses the user's existing AltStore setup; accepted trade-offs are weekly refresh and no debugger | — Pending |
| Private GitHub repository | User preference; accepts a limited monthly build allowance | — Pending |
| v1 is foreground only: open the app, tap "Back up now" | Background execution is heavily limited by iOS and adds weeks | — Pending |
| Back up all media, no photos-only default in v1 | User chose "back up everything new" over photos-first | — Pending |
| Download iCloud-only originals and report failures | User wants complete backups; unavailable items must never count as stored | — Pending |
| Safari page stays as is, as the no-install fallback | Effort goes into the app | — Pending |
| Prove feasibility first (toolchain, original bytes, local HTTP) before building features | The proposal is unprototyped and the build route is unusual; failing early is cheap | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-10-11 after initialization*
