# Feature Research

**Domain:** Native iPhone client for a self-hosted, one-way, original-bytes photo backup (single user, one iPhone, one Windows PC, LAN only, foreground-only v1)
**Researched:** 2026-10-11
**Confidence:** MEDIUM overall. PhotoKit resource semantics and fetch options are HIGH (Apple docs). Competitor behaviour is MEDIUM (docs, release notes, forum/issue reports). Several PhotoKit edge behaviours (hidden under full access, burst frames, ProRAW resource shape, iCloud stalls) are LOW until proven on the real phone; they are listed as spikes below.

Scope reminder: server features (resumable chunk upload, SHA-256 verify, dedupe, date folders, dashboard) already exist and are not re-researched. Deferred by the user and not proposed here: background/scheduled uploads, Bonjour, HTTPS pinning, library-vs-server reconciliation.

## How comparable clients behave (evidence summary)

| Topic | Immich (iOS) | Mewt Photos | Nextcloud iOS | Synology Photos | Ente | Takeaway for us |
|-------|--------------|-----------|---------------|-----------------|------|-----------------|
| Scope | Per-album selection; iOS asset can sit in many albums, so users exclude albums | Whole library or selection; "new" tracking | "Upload all" vs new-only auto-upload | Per-folder backup tasks | Per-album selection (full access expected) | Album pickers create silent gaps. Whole library is the right model for "nothing missed". |
| Permission | Full access effectively required; stalls reported with odd permission states | n/a in sources | No sources on limited access | No sources | Docs tell user to grant full access | Detect `.limited`, say so loudly, never claim full coverage. |
| Skip already-done | Content checksum vs server | Own unique-id tracking, redone in 4.9.5 because ids were unreliable across iOS upgrades and iCloud restores | Local record; reports of items silently skipped after a check | Name + capture time + hash must all match | n/a | Do not trust a local-only record. Server (assetId + hash) is the authority. Survive id changes via hash. |
| Live Photos | Still + video kept together; manual link/unlink added in 1.115 because pairing broke | Setting: Apple 2 files (default), Motion Photo JPEG, or both | HEIC + MOV, but a compatibility setting can drop the MOV so it stops being a Live Photo | Reports of Live Photos arriving as JPEG | n/a | Two files, same base name, same folder. Do not offer alternative formats. |
| Edited photos | Reports (discussion 4750) that only the edited render is uploaded and the original is lost, including Portrait depth data; no maintainer decision | User setting: Original / Edited / Original+Edited; can re-send photos edited after transfer (4.8) | n/a | A release fixed edited videos being skipped as duplicates | "Modified photos synced" | The #1 trust failure in the field is losing the original of an edited photo. Always take the original; the edited render is a cheap add-on. |
| Bursts | n/a | 3.0 added "all burst photos"; 3.2 fixed autotransfer missing some | n/a | n/a | n/a | Default PhotoKit fetch returns only the key frame; opt in to all frames. |
| RAW+JPEG | n/a | Choose RAW only / JPEG only / both | n/a | n/a | n/a | For a backup there is no reason to choose: take every resource. |
| iCloud-only | Downloads to app cache, hashes, uploads, clears; warns about data and storage use | Auto-downloads before transfer (3.0) | n/a | n/a | Tells user to let iCloud finish syncing / keep originals first | Allow network download, show it as its own state, time it out, report failures as not backed up. |
| Progress/failures | Counts (backed up / remainder / total); a stuck backup that shows "0 tasks" with no reason was reported (issue 22661); one un-uploadable asset (duplicate filename, issue 9129) silently never uploads | Per-transfer log | Many "stops when backgrounded" threads | Task queue view | n/a | Counts must reconcile and every non-success needs a visible reason. Our "truthful result" requirement is already stricter than the field. |
| Background | OS-limited; "open the app more" | OS-limited | Users keep screen on / use Shortcuts to open app | n/a | Videos not uploaded in background on iOS | Confirms foreground-first v1 and the keep-awake feature. |
| Deletion | n/a | n/a | n/a | n/a | Deletes on phone never propagate | Matches our one-way additive rule. |

## Feature Landscape

Groups are written to be used directly as requirement categories. IDs are suggestions (CAT-n).

### Table Stakes (backup is not trustworthy without these)

| ID | Feature | Why Expected | Complexity | Notes |
|----|---------|--------------|------------|-------|
| **Build & Install** | | | | |
| BLD-1 | In-app log with export/share (file or share sheet) | No debugger, no Mac (project constraint). Every real-device failure must be diagnosable from a log | LOW | Include versions, run id, per-asset resource id, error domain/code, durations. Ring buffer on disk. Needed from the first CI build |
| BLD-2 | Build/version and "days until AltStore expiry" visible in app (version at least) | Weekly re-sign means the user must know which build is installed | LOW | Version string from the build; expiry countdown is optional nicety |
| **Pairing** | | | | |
| PAIR-1 | Scan the dashboard QR to pair; store key in Keychain | Stated requirement; same as competitors' server-URL + login but simpler | LOW-MED | Camera permission prompt. Use VisionKit scanner or AVFoundation; no third-party package |
| PAIR-2 | Manual fallback: type address + code | Camera denied, QR damaged, dashboard on another screen | LOW | Cheap insurance; also the debug path |
| PAIR-3 | Plain-English connection check with specific causes: wrong network, PC off, firewall, **Local Network permission denied** | iOS 14+ asks for Local Network permission on first LAN connection; denial or an unanswered prompt looks like a silent timeout. This is the most likely "it just doesn't work" on day one | MED | Preflight request to the server before scanning the library; map URLError codes to causes; deep link to Settings |
| PAIR-4 | Show paired server and last result; "forget server / re-pair"; editable address | Home DHCP changes the PC's IP and Bonjour is deferred, so the stored address will go stale | LOW | Advise a DHCP reservation in the README. Re-pair must not duplicate the device record |
| **Library access & scan** | | | | |
| LIB-1 | Request Read/Write photo access with explanation; handle denied, restricted, limited, authorized | Nothing works without it. Competitors lean on "grant full access" | LOW | `.readWrite` is needed for full library enumeration; the app never writes |
| LIB-2 | Limited access: detect, show persistent banner, refuse to present results as full backup, button to Settings | A limited grant silently shows only the selected items (PhotoKit filters fetches to the selection). A backup that says "all done" on 40 of 30,000 photos is the worst failure possible | LOW | Recommended: disable "Back up now" until Full is granted (YAGNI an override). `libraryCount` sent as unknown if ever shown |
| LIB-3 | Handle permission revoked mid-run and after app update | Users toggle it in Settings; fetches then return nothing | LOW | Re-check status at run start and on `scenePhase` active |
| LIB-4 | Full enumeration of the user library on every run, newest first | Simple and truthful; 50k asset metadata fetch is fast. Newest-first protects recent photos if the run is interrupted | LOW | Sort by `creationDate` descending. Process sequentially |
| LIB-5 | Include hidden assets | Hidden photos are still in the library and the user expects a backup to include them; PhotoKit excludes them by default (`includeHiddenAssets` false) | LOW | **Spike**: confirm fetch works under full access with the Hidden album locked (iOS 16+ Face ID lock). Privacy note: they land in normal date folders on the PC |
| LIB-6 | Include every burst frame | Default fetch returns only the representative frame; the other frames are library photos the user can still pick later (`includeAllBurstAssets`) | LOW | One flag, but doubles-or-more file count for burst-heavy libraries. Group by `burstIdentifier` only for display, never to skip |
| LIB-7 | Restrict to the user's own library source type; do not back up Recently Deleted | Shared-album and iTunes-synced assets are not the user's originals; trashed items are not "in the library" | LOW | **Spike**: confirm default `includeAssetSourceTypes` behaviour and set it explicitly |
| LIB-8 | Pre-run count: "N items not on the PC yet" before tapping Back up now | `/assets/check` in batches answers this before any export; MewtPhotos/Immich show remaining counts | LOW-MED | Depends on LIB-4 + server check. Makes "nothing to do" a fast, reassuring path |
| **Originals** | | | | |
| ORIG-1 | Export via `PHAssetResourceManager.writeData(for:toFile:)` only; never `requestImage`/export sessions/`requestAVAsset` | Only route that returns stored bytes. Anything else re-renders or transcodes (HDR, Dolby Vision, ProRes, Cinematic data) | MED | Hash while writing or after (see UP-1). Byte-for-byte check: phone-side SHA-256 must equal server-side |
| ORIG-2 | Back up every original-side resource of the asset: `.photo`, `.video`, `.pairedVideo`, `.alternatePhoto`, `.audio` | RAW+JPEG/RAW+HEIC pairs are one asset with an alternate resource; competitors make the user choose RAW/JPEG/both, a backup should take both. ProRAW is a DNG `.photo` | MED | **Spike**: dump resource types/filenames/UTIs for a ProRAW, RAW+JPEG, Live, edited, burst and slo-mo sample on the phone before designing naming |
| ORIG-3 | Never convert: HEIC stays HEIC, DNG stays DNG, HEVC `.mov` stays | Core value; Synology/Nextcloud threads show conversion bugs are the common complaint | LOW | Do not offer a JPEG+HEIC option |
| ORIG-4 | Stable file naming from `originalFilename`; collisions (IMG_0001 after counter rollover, or same name different content) must never be treated as "already backed up" | Immich issue 9129: duplicate filenames caused photos that never uploaded. Synology matches name+time+hash | LOW | Server already dedupes on content hash; ensure the client sends the hash and never decides by name |
| ORIG-5 | Slow-motion, HDR/Dolby Vision, Cinematic, ProRes, spatial video: take the `.video` resource as-is | Falls out of ORIG-1; original `.mov` keeps 240 fps and all tracks. Only the user's slow/fast speed-ramp points (in adjustment data) are not in the file | LOW (given ORIG-1) | State this honestly in docs: bytes preserved, edit metadata not (see differentiators) |
| ORIG-6 | Free-space preflight and temp-file hygiene: export one resource at a time, delete temp after verified, purge orphans at launch | ProRes can be gigabytes per minute; iCloud downloads land in the phone's storage too. Immich explicitly warns about cache use | MED | Pause with a clear message when free space is below the next resource size plus margin. Delete temp on every path including failure |
| **Live Photos** | | | | |
| LIVE-1 | Upload `.photo` + `.pairedVideo` as two files with the same base name in the same folder | Stated requirement; Immich needed manual relinking tools after pairing broke; Nextcloud's compatibility toggle drops the MOV | MED | Server side: both must land in the same `YYYY\MM`. Pair counts as one item in UI but two resources in the ledger; one half failing means the item is failed, not half-backed-up |
| LIVE-2 | Show a Live Photo as backed up only when both resources are verified | Truthfulness. Partial pair = not backed up | LOW | Per-resource states roll up to per-asset state |
| **iCloud-only originals** | | | | |
| CLOUD-1 | `isNetworkAccessAllowed = true`; show "downloading from iCloud" state with progress | Mewt Photos 3.0 and Immich both auto-download; stated requirement | MED | Use `progressHandler`. Keep a distinct state so the user understands slow items |
| CLOUD-2 | Per-asset stall/timeout watchdog on download; failure becomes "unavailable" with reason, run continues | Forum reports of downloads stalling at ~50% with network access on; one stuck asset must not freeze the run (Immich 22661 symptom) | MED | There is no API to ask "is this resource local" (Apple engineer); try, and treat failure as the signal. Do not promise an up-front list of iCloud-only items |
| CLOUD-3 | Never count unavailable items as backed up; list them separately with reason | Core value | LOW | Reasons: not downloadable, iCloud offline, timed out, no space |
| **Upload & skip logic** | | | | |
| UP-1 | Skip via server: `/assets/check` by assetId in batches, then `sha256` on create so server answers `duplicate` before any bytes move | Roadmap design; Immich/Synology skip by hash; Mewt Photos had to rework id tracking because ids are unreliable | MED | Per-resource ids `<localIdentifier>/<resourceType>` so a later-added resource (edit render) is not masked by the asset being "known". Handle: `localIdentifier` changes after restore/new device, hash covers it |
| UP-2 | Server is the source of truth; local state is a cache only | AltStore reinstall or app delete wipes local data; a local "done" flag can be wrong | LOW | A fresh install should cheaply rediscover everything via UP-1 (hash cost is the price; acceptable) |
| UP-3 | Resume large videos from the server's offset (`GET /uploads/:id`, `PATCH` with `Upload-Offset`) | Stated requirement; Safari failed here | MED-HIGH | Persist upload id with the resource id; on relaunch/foreground return, query offset then continue. Stream from file, never load into memory |
| UP-4 | Foreground interruption handling: app suspended, screen locked, Wi-Fi lost, server restarted | Foreground apps are suspended seconds after leaving the screen; Nextcloud users' most common complaint | MED | Show "Paused: app was in background", auto-resume on foreground. Treat as normal, not an error |
| UP-5 | Keep the screen awake during a run (`UIApplication.isIdleTimerDisabled = true`), restore when idle; banner "keep this app open" | Nextcloud users' workaround; the app dies on auto-lock otherwise. Side-button lock still suspends, so the banner is required | LOW | Warn if Low Power Mode is on (it throttles transfers and can dim/lock sooner). Optional charger advice |
| UP-6 | One bad item never stops the run: continue past failures; short automatic retry with backoff for transient network errors | Immich 22661 / 9129 show one asset blocking others is a top complaint | LOW-MED | e.g. 3 attempts then mark failed |
| UP-7 | Stop/cancel button that ends cleanly (in-flight upload resumable later) | Users will interrupt a 3-hour first run | LOW | Cancel must not leave a "receiving" row the dashboard shows forever; rely on resume rather than delete |
| UP-8 | Sequential uploads (one at a time) | Simplest and kindest to home Wi-Fi/PC disk; keeps progress honest | LOW | Pipelining is a differentiator |
| **Reporting & retry** | | | | |
| REP-1 | Live progress: current item name, bytes, item N of M, overall bytes if cheap, phase label (checking / downloading from iCloud / exporting / uploading / verifying) | Immich shows counts; Mewt Photos per-transfer progress. Phases matter because export/hash/iCloud time looks like a hang | MED | Spec: UI state derives from the same per-resource states used for results |
| REP-2 | Truthful end summary that reconciles: considered = already on PC + newly verified + failed + unavailable (+ skipped by rule, e.g. none). "Verified" equals server-reported | Core value; roadmap truthfulness test. Competitors' counts can drift (remainder stuck) | MED | Show the server session summary next to local numbers; any mismatch is displayed, not hidden |
| REP-3 | "Needs attention" list: every failed/unavailable item with thumbnail, filename, date, reason | Stated requirement; closest competitor equivalent is a bare remainder number | MED | Thumbnails via PHImageManager are fine for display only (never for backup). Persist across launches |
| REP-4 | "Retry failed" (all) and per-item retry | Stated requirement | LOW-MED | Retry = re-run the same pipeline for those resource ids; success clears the entry |
| REP-5 | Plain error vocabulary mapped from server codes and URLError/PHPhotosError | Debuggability and trust | LOW | Always include the code in the log |
| REP-6 | Last run result persisted and shown on launch; run history optional | User opens app to see "did it work" | LOW | One record is enough |

### Differentiators (valuable, defer past first working v1 unless noted)

| ID | Feature | Value Proposition | Complexity | Notes |
|----|---------|-------------------|------------|-------|
| DIFF-1 | Back up the edited render too (`.fullSizePhoto`, `.fullSizeVideo`, `.fullSizePairedVideo`) as a sibling file with an Apple-style suffix (e.g. `IMG_E1234`) | If the phone dies, the user loses their crops/filters; the original alone is the "untouched" promise but not what they remember. Mewt Photos offers it; Immich users ask for it (discussion 4750) | MED | Strongly recommended as the first post-core addition. Original is always table stakes; the render is additive. Needs per-resource ids (UP-1) and server naming/placement rule so pair+render stay in one folder |
| DIFF-2 | Preserve adjustment data (`.adjustmentData`, `.adjustmentBase*`) as sidecar | Lets Photos-on-Mac recreate edits, preserves slo-mo ranges/Portrait depth edits per the Immich thread | MED-HIGH | Opaque Apple plist blob, no use on Windows; server allow-list needs a sidecar type. Defer; the original already contains the pixels |
| DIFF-3 | Re-back-up assets edited after first backup (modification-date change) | Mewt Photos 4.8 does this; otherwise edits made after backup are never captured | MED | Depends on DIFF-1 and per-resource ids. Without DIFF-1 there is nothing new to send |
| DIFF-4 | Pipelining: export/hash next item while current uploads | Biggest cheap speed-up on many small photos | MED | Adds concurrency bugs; do after sequential is trusted |
| DIFF-5 | `PHPersistentChangeToken` incremental scan | Avoids re-enumerating 50k assets | MED-HIGH | Only worth it if full scan + `/assets/check` proves slow. Token expiry needs a full-scan fallback anyway, so the fallback must exist first |
| DIFF-6 | Resume an interrupted run after app kill, with state restored | Nice after crashes; otherwise just tap Back up now again (UP-1 skips finished work) | LOW-MED | Largely free if UP-3 persists upload ids |
| DIFF-7 | Estimated bytes / time remaining | Reassurance on first multi-hour run | MED | Resource size is not public API (a KVC key is commonly used; unofficial, LOW confidence). Count-based progress is enough for v1 |
| DIFF-8 | Wi-Fi-only guard / "PC reachable" indicator on home screen | Prevents confusing cellular failures | LOW | Part of PAIR-3 preflight already |
| DIFF-9 | Live Photo edited-state handling (render + fullSizePairedVideo) | Completes DIFF-1 | MED | Mewt Photos fixed bugs here; test explicitly |
| DIFF-10 | Library-vs-server reconciliation / "coverage verified" | The true "what is not backed up" view | HIGH | Explicitly deferred by the user |

### Anti-Features (deliberately NOT building)

| Anti-Feature | Why Requested | Why Problematic | Alternative |
|--------------|---------------|-----------------|-------------|
| Delete from phone after backup / "free up space" | Obvious Apple-storage pain | Backup is the only second copy; one bug destroys originals; needs destructive permission; out of scope in PROJECT.md | Never write to the library. User deletes manually after seeing a verified summary |
| Propagate phone deletions to PC | "Keep PC in sync" | Turns backup into sync; deleting by mistake loses the backup. Ente and Immich both refuse | One-way additive only |
| Album picker / per-album backup / album mirroring (Immich-style) | Control and organisation | Assets can sit in many albums; exclusions create silent gaps; contradicts "nothing missed" | Whole library, date folders on PC |
| Format options: HEIC to JPEG, JPEG+HEIC, Motion-Photo JPEG, "most compatible" | Windows viewers and sharing | Converts or duplicates; this is what broke the Safari path | Install HEIC extension on Windows or convert on the PC later |
| Compression / "optimise upload size" | Faster Wi-Fi | Violates untouched originals | None |
| Choose RAW vs JPEG vs both | Mewt Photos exposes it | A backup should never drop a resource | Take all resources |
| Backing up shared-album items or Recently Deleted | "Everything" | Not the user's own library originals; trash is deliberately deleted | User-library source type only |
| In-app gallery/timeline/search/face grouping | Immich-like experience | Whole separate product; no value to a backup | Windows File Explorer, existing dashboard |
| Photo picker / manual selection in the app | Safari page has it | Hand-picking is what "Back up now" replaces; selection hides gaps | Keep Safari page for ad hoc sends |
| Limited-library "Select more photos" flow | Looks like a fix for limited access | Gives a partial backup that looks complete | Gate on Full Access |
| Parallel uploads / configurable concurrency | Speed | Harder truthful progress, more server and disk contention, hard to debug without a debugger | Sequential, then pipelining (DIFF-4) |
| Local notifications, widgets, Live Activities | Status when away | Only meaningful with background runs (deferred); extra permissions and CI complexity | Foreground progress screen |
| Local-only "already backed up" flags trusted without server | Offline speed | Wrong after reinstall/restore; violates truthfulness | UP-1/UP-2 |
| Auto "Back up now" on launch | Convenience | Surprises with a multi-GB first run on cellular/low battery; entangles with permission prompts | Explicit tap; show LIB-8 count on launch |
| Multi-server, multi-user, accounts, cloud | Generality | Single user, one PC, LAN only | None |

## Feature Dependencies

```
PAIR-1/2 (pair, Keychain) ──requires──> PAIR-3 (reachability + Local Network permission)
LIB-1 (authorization) ──requires──> LIB-2 (limited gate) ──requires──> LIB-4 (full scan)
LIB-4 ──enhanced by──> LIB-5 hidden, LIB-6 bursts, LIB-7 source types
LIB-4 + PAIR-3 ──requires──> UP-1 (/assets/check + sha256 skip) ──requires──> LIB-8 (pre-run "N new")
ORIG-1 (writeData) ──requires──> ORIG-6 (temp space/cleanup) ──feeds──> UP-1 (hash), UP-3 (resume)
ORIG-2 (all resources, per-resource ids) ──requires──> LIVE-1 ──requires──> LIVE-2 (roll-up)
CLOUD-1 ──requires──> CLOUD-2 (watchdog) ──requires──> CLOUD-3 (unavailable state)
UP-3 (resume) ──requires──> UP-4 (interruption) ──requires──> UP-5 (keep awake)
REP-1 ──requires──> single per-resource state model ──requires──> REP-2 (reconciling summary) ──requires──> REP-3 list ──requires──> REP-4 retry
BLD-1 (logs) ──underpins──> everything (no debugger)
DIFF-1 (edited render) ──requires──> ORIG-2 + UP-1 per-resource ids ──enables──> DIFF-3 (re-backup edits) and DIFF-2 (sidecar)
DIFF-5 (change token) ──requires──> LIB-4 full scan fallback
Limited access (LIB-2) ──conflicts──> any "all backed up" claim
Delete-after-backup ──conflicts──> read-only safety constraint
```

### Dependency Notes

- **Single state model first:** a per-resource state machine (pending, checking, downloading, exporting, uploading, verified, duplicate, failed, unavailable) drives progress, results, the attention list and retry. Building REP-1..4 on separate ad hoc counters is how counts drift. Build it in the first real backup phase.
- **Per-resource ids are cheap now, expensive later:** adopting `<localIdentifier>/<resourceType>` in the first upload path is what makes Live Photos, alternates and later edited renders work without a migration. Verify the server's `assetId` field accepts that form.
- **Server gaps the client features rely on (flag for the roadmap, not re-researched):** Live Photo halves landing in one folder; extension allow-list for `.dng`, `.mov`, `.heic`, later `.aae`/plist; `/assets/check` answering "known" without checking the file on disk (CONCERNS.md), which makes UP-1 over-trust the server.
- **Hash cost:** UP-1 requires hashing before create. Use CryptoKit streaming SHA-256 (hardware accelerated), not the pure-JS hashing that ran at about 4 MB/s on Safari.

## MVP Definition

### Launch With (v1, foreground)

- [ ] BLD-1 logs and export; build version shown
- [ ] PAIR-1, PAIR-2, PAIR-3, PAIR-4
- [ ] LIB-1 to LIB-8 (full access gate, hidden, all bursts, user-library only, newest first, pre-run count)
- [ ] ORIG-1 to ORIG-6 (writeData only, all resources, no conversion, space guard)
- [ ] LIVE-1, LIVE-2
- [ ] CLOUD-1, CLOUD-2, CLOUD-3
- [ ] UP-1 to UP-8
- [ ] REP-1 to REP-6

Suggested build order inside v1: toolchain + logging + pairing + PAIR-3 preflight, then one-resource backup end to end with the state model (photos, HEIC original, skip logic, truthful summary), then videos with resume and keep-awake, then Live Photos/alternates/bursts/hidden, then iCloud handling, then attention list and retry.

### Add After Validation (v1.x)

- [ ] DIFF-1 edited renders (and DIFF-9 for Live) once originals are proven on the phone
- [ ] DIFF-6 resume after kill; DIFF-4 pipelining if speed disappoints
- [ ] DIFF-3 re-back-up edited assets

### Future Consideration (v2+)

- [ ] DIFF-2 adjustment-data sidecars
- [ ] DIFF-5 change tokens (only if scan time is a measured problem)
- [ ] DIFF-10 reconciliation (already deferred), background/scheduled, Bonjour, HTTPS pinning (already deferred)

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Original bytes via writeData, all resources (ORIG-1/2/3) | HIGH | MEDIUM | P1 |
| Full-access gate (LIB-2) | HIGH | LOW | P1 |
| Server-authoritative skip + hash (UP-1/2) | HIGH | MEDIUM | P1 |
| Truthful reconciling summary (REP-2) | HIGH | MEDIUM | P1 |
| Live Photo pair (LIVE-1/2) | HIGH | MEDIUM | P1 |
| iCloud download + watchdog + unavailable (CLOUD-1..3) | HIGH | MEDIUM | P1 |
| Video resume (UP-3) | HIGH | MED-HIGH | P1 |
| Keep awake + interruption handling (UP-4/5) | HIGH | LOW-MED | P1 |
| Attention list + retry (REP-3/4) | HIGH | MEDIUM | P1 |
| Logs export (BLD-1) | HIGH | LOW | P1 |
| Local Network preflight (PAIR-3) | HIGH | MEDIUM | P1 |
| Hidden + all bursts (LIB-5/6) | MEDIUM | LOW | P1 |
| Space guard (ORIG-6) | MEDIUM | MEDIUM | P1 |
| Pre-run "N new" (LIB-8) | MEDIUM | LOW-MED | P1 |
| Edited renders (DIFF-1) | MEDIUM-HIGH | MEDIUM | P2 |
| Re-back-up after edit (DIFF-3) | MEDIUM | MEDIUM | P2 |
| Pipelining (DIFF-4) | MEDIUM | MEDIUM | P2 |
| Resume after kill (DIFF-6) | MEDIUM | LOW-MED | P2 |
| Adjustment sidecars (DIFF-2) | LOW | MED-HIGH | P3 |
| Change tokens (DIFF-5) | LOW | MED-HIGH | P3 |
| Size/time estimates (DIFF-7) | LOW | MEDIUM | P3 |

## Competitor Feature Analysis

| Feature | Immich | Mewt Photos | Our Approach |
|---------|--------|-----------|--------------|
| Scope | Selected albums | Library/selection | Whole library, no album choice |
| Original vs edited | Reports of edited only | User choice, default offers both | Original always; render added in v1.x |
| RAW+JPEG | Not documented in sources | User choice | Always both |
| Live Photos | Pair kept; manual relink tool | 2 files default, optional Motion Photo | Two files, same base name |
| Dedupe | Checksum | Own id, hash not documented | assetId then hash, server authoritative |
| iCloud | Download to cache | Auto-download | Download, watchdog, report unavailable |
| Progress | Counts | Per-transfer log | Phased progress + reconciling summary |
| Failures | Remainder count; stalls reported | Log | Persistent attention list with reasons and retry |
| Background | Best effort | Best effort | None in v1; keep screen awake |

## Spikes to run on the real iPhone (LOW confidence until done)

1. Resource inventory dump (types, original filenames, UTIs, sizes) for: HEIC, ProRAW, RAW+JPEG, Live Photo, edited photo, edited Live Photo, burst, slo-mo, HDR/Dolby Vision video, Cinematic, ProRes, an iCloud-only item.
2. Hidden-album assets fetched with `includeHiddenAssets` under Full Access; default `includeAssetSourceTypes` behaviour; burst frames with `includeAllBurstAssets`.
3. `writeData` for an iCloud-only large video: does it complete, stall, or error, and how fast is the failure signalled.
4. Local Network permission: behaviour of a first LAN request before and after the prompt, and after denial.
5. Foreground suspend: how long a `PATCH` survives after screen lock, and resume via offset.

## Sources

- [Immich mobile backup docs](https://docs.immich.app/features/mobile-backup) (album selection, iCloud cache, checksum dedupe, Background App Refresh). MEDIUM
- [Immich discussion 4750: edited photos on iPhone](https://github.com/immich-app/immich/discussions/4750) (edited-only upload, lost Portrait/slo-mo data, no maintainer decision). MEDIUM (user reports)
- [Immich issue 22661](https://github.com/immich-app/immich/issues/22661) and [issue 9129](https://github.com/immich-app/immich/issues/9129) (stalled backup, filename-collision skips). LOW-MEDIUM (user reports)
- [Linuxiac on Immich 1.115](https://linuxiac.com/immich-1-115-released/) (manual Live Photo linking on iOS). MEDIUM
- [Mewt Photos 4.9.5 release notes](https://www.mewtphotos-app.com/support/release-notes/mewtphotos-4-9-5-for-ios-released) (Live Photo format options, new unique-id tracking). HIGH for vendor behaviour
- [Mewt Photos 4.8 release notes](https://www.mewtphotos-app.com/support/release-notes/mewtphotos-4-8-for-ios-released) (re-transfer edited items, original/edited/both, RAW/JPEG choice, HEIC+JPEG). HIGH for vendor behaviour
- [Mewt Photos 3.0 release notes](https://www.mewtphotos-app.com/support/release-notes/mewtphotos-3-0-for-ios-released) and [3.2.3](https://www.mewtphotos-app.com/support/release-notes/mewtphotos-3-2-3-for-ios-released) (bursts, iCloud auto-download, edited Live Photo video fix). HIGH for vendor behaviour
- [Apple PHAssetResourceType](https://developer.apple.com/documentation/photos/phassetresourcetype.md) (full resource list incl. adjustmentBase*, alternatePhoto, pairedVideo, fullSize*). HIGH
- [Apple PHFetchOptions](https://developer.apple.com/documentation/photos/phfetchoptions.md) (includeHiddenAssets, includeAllBurstAssets, includeAssetSourceTypes, burstIdentifier). HIGH
- [Apple PHAssetResourceRequestOptions](https://developer.apple.com/documentation/photos/phassetresourcerequestoptions.md), [forum: local PHAssetResource availability](https://developer.apple.com/forums/thread/833066), [forum thread 66477](https://developer.apple.com/forums/thread/66477) (network flag, progress handler, no local-availability API, download stalls). MEDIUM
- [WWDC21 notes: improve access to photos](https://wwdcnotes.com/notes/wwdc21/10046) and [Apple forum 662053](https://developer.apple.com/forums/thread/662053) (limited library acts as a filter on fetches). MEDIUM
- [Nextcloud forum threads](https://help.nextcloud.com/t/photos-videos-not-uploading-automatically-mobile-client/246825) and [Live HEIC thread](https://help.nextcloud.com/t/live-heic-photos-and-iphone-app/85955) (foreground-only reality, HEIC/MOV compatibility quirk). LOW-MEDIUM (user reports)
- [Synology KB](https://kb.synology.com/en-us/DSM/tutorial/How_do_I_continue_my_mobile_backup_tasks_after_upgrading_to_Synology_Photos) and [App Store listing](https://apps.apple.com/nz/app/synology-photos/id1484764501) (name+time+hash dedupe, task queue). MEDIUM
- [Ente community FAQ](https://community.ente.io/faq/features/background) and [Apple Photos import guide](https://ente.com/help/photos/migration/from-apple-photos/) (full access, no deletion propagation, iOS video background limits, iCloud-originals advice). MEDIUM
- Not found / not covered by sources: Syncthing-style and PhotoPrism iOS clients (no meaningful PhotoKit-aware iOS behaviour located; Synctrain mentioned only in a forum title). Statements about iOS Local Network permission prompt and `isIdleTimerDisabled` come from general platform knowledge, not fetched this session. LOW-MEDIUM, verify in spikes.

Provider note: the research-plan/gsd_run seam was not invoked; findings come from direct WebSearch and WebFetch (provider "websearch"/"webfetch").

---
*Feature research for: native iPhone photo backup client (foreground, LAN, originals)*
*Researched: 2026-10-11*
