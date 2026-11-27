# iOS build log

One row per iOS build. The build number is the `ios-build` workflow run number, and the install file is the `MewtPhotos-ipa`
artifact of that run (also copied to iCloud Drive as `MewtPhotos\MewtPhotos-b<build>.ipa`). The phase gates in `.planning/phases/`
record what passed on the phone; this log only says which build contains which change.

| Build | Commit | Date | What it contains | Device result |
|------:|--------|------|------------------|---------------|
| 21 | `ee1936a` | 2026-10-12 | Earlier Phase 5 work | Not recorded here |
| 22 | `554e383` | 2026-10-12 | Earlier Phase 5 work | Not recorded here |
| 23 | `b49912e` | 2026-10-12 | Earlier Phase 5 work | Not recorded here |
| 24 | `8ee8573` | 2026-10-12 | Burst photo fix | **Failed to compile** (a name clash). Fixed in 25 |
| 25 | `7662c95` | 2026-10-12 | Burst photo fix, compiling | Pass: all 6 burst frames arrived (IMG_8100 to IMG_8105) |
| 26 | `ab799d2` | 2026-10-12 | RAW companion: `PhotoParts` name (06-01) | Not tested on device |
| 27 | `32cedfa` | 2026-10-12 | RAW not skipped as held from its first part; its JPEG or HEIC is sent (06-01 fix) | Not tested on device |
| 28 | `83eeaad` | 2026-10-12 | Live Photo video sent beside its still (06-02) | Live Photo arrives as both files (IMG_8068, IMG_7869) |
| 29 | `71bf953` | 2026-10-12 | Videos sent as originals; resume from the PC's offset (06-03) | Videos verified (IMG_7545, IMG_2280, IMG_5378) |
| 30 | `4130bee` | 2026-10-12 | Speed-test upload sends the photo's date, so a resume can match | Resume still failed (IMG_8114 sent in full). Fixed in 31 |
| 31 | `8d15787` | 2026-10-12 | Re-sent video waits for the stalled attempt, then resumes | Pass: IMG_8116 resumed from the PC's offset (313 MB already on the PC) |
| 32 | `a4405a4` | 2026-10-12 | Retry failed items: **Retry N failed** and single **Retry** (06-04) | Pass (2026-10-26): after forced failures, Retry worked and the phone totals matched the PC |
| 33 | `9b5adac` | 2026-10-13 | A run stops only in the background, not for Control Center | Pass: Control Center no longer stops the run |
| 34 | `728ffb1` | 2026-10-13 | Coverage section: what the PC is missing (Phase 7) | Pass: "Coverage verified" on 4,083 of 4,083 |
| 35 | `c272a40` | 2026-10-13 | Continuing an unfinished run picks up photos taken since it started | Pass (2026-10-26): continuing the unfinished run picked up the new photo; all four expected conditions met |
| 38 | `1b10899` | 2026-10-26 | Interface redesign (Phase 8): shared theme, dark card layout on every screen, new app icon (`ios/art/icon.svg`), name shown as Mewt Photos, everything renamed to MewtPhotos; no logic changes. Builds 1 and 2 of this change failed (icon PNG corrupted by git; `Panel` init label) | Pass (2026-10-26): installed and used on the phone; the owner confirmed the new UI works |
| 39 | `8c0a192` | 2026-11-26 | Obsidian Glass Bento 3-tab redesign (`Backup`, `Library`, `Server` + floating glass dock, Cyan/Amber accent, live speed sparkline, lazy `PHAssetResource` inspection, `LazyVStack`, server archive stats + authenticated `/verify`, disabled `24/7 Auto-Backup` preview, `mewtMini` `:8788` defaults) | Installed on phone; confirmed working |
| 40 | `96c8ad9` | 2026-11-27 | Live **24/7 Auto-Backup** via `BGProcessingTask` (`BackgroundSyncScheduler`, `MewtAppDelegate` launch registration, `UIBackgroundModes: processing` + `BGTaskSchedulerPermittedIdentifiers`, interactive Server-tab toggle with Armed / last overnight run status, RunLog instrumentation) | Built & downloaded to iCloud Drive (`MewtPhotos\MewtPhotos.ipa`); awaiting device check |
| 41 | `8ea5e0a` | 2026-11-27 | Fix uploader stalls & maximize sync speed: in-process `StreamUploader` (45s send / 180s verify watchdog, instant Stop cancel), single-pass PhotoKit `requestData` + SHA-256 export (60s watchdog), 2-stage bounded pipeline (`maxConcurrency: 3` for `< 16 MB`, solo for large videos), 1 shared session per run + `POST /api/v1/files` one-shot fast path (`oneShotMetadata`), `nonisolated` off-Main-Thread pipeline/enumeration, throttled UI rebuilds & `run-record.json` writes, true aggregate Wi-Fi `MB/s` + live Coverage ring, server verify yielding + batched SQLite logs, automatic legacy `nsurlsessiond` cleanup | Built & downloaded to iCloud Drive (`MewtPhotos\MewtPhotos-b41.ipa`); awaiting device check |
