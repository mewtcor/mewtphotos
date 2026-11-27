// The backup run on the phone (Phase 5, plan 05-03): exports one original at a time, checks free space, sends
// it, and keeps the run record up to date. Read-only with respect to the library: nothing is changed or deleted.
// Photos is imported here, in the same allowed set as DiagnosticsView and LibraryView (see ci.yml).
import SwiftUI
import UIKit
import Photos
import CryptoKit
import MewtPhotosCore

/// Tracks the active PhotoKit data export request so `BackupModel.stop()` can cancel it immediately.
private final class ActiveExportTracker: @unchecked Sendable {
    static let shared = ActiveExportTracker()

    private let lock = NSLock()
    private var requestId: PHAssetResourceDataRequestID?
    private var cancelHandler: (() -> Void)?

    func register(id: PHAssetResourceDataRequestID, onCancel: @escaping () -> Void) {
        lock.lock()
        requestId = id
        cancelHandler = onCancel
        lock.unlock()
    }

    func clear(id: PHAssetResourceDataRequestID) {
        lock.lock()
        if requestId == id {
            requestId = nil
            cancelHandler = nil
        }
        lock.unlock()
    }

    func cancelActive() {
        lock.lock()
        let id = requestId
        let handler = cancelHandler
        requestId = nil
        cancelHandler = nil
        lock.unlock()
        if let id {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
        handler?()
    }
}

private final class ExportState: @unchecked Sendable {
    let lock = NSLock()
    var resumed = false
    var lastActivity = Date()
    var bytes: Int64 = 0
    var hasher = SHA256()
    var writeError: Error?
    var requestId: PHAssetResourceDataRequestID?
    var watchdog: DispatchSourceTimer?
    var fileHandle: FileHandle?

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }
}

private final class ThroughputMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(at: ContinuousClock.Instant, bytes: Int64)] = []
    private let windowSeconds: Double = 1.5

    func record(bytes: Int64) -> Double {
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        if bytes > 0 {
            samples.append((now, bytes))
        }
        samples.removeAll { sample in
            let parts = sample.at.duration(to: now).components
            let age = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return age > windowSeconds
        }
        guard let first = samples.first else { return 0 }
        let totalBytes = samples.reduce(Int64(0)) { $0 + $1.bytes }
        guard totalBytes > 0 else { return 0 }
        let parts = first.at.duration(to: now).components
        let span = max(Double(parts.seconds) + Double(parts.attoseconds) / 1e18, 0.15)
        return (Double(totalBytes) / 1_000_000.0) / span
    }
}

private final class RecordSaveThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSavedCompleted = 0
    private var lastSavedProblems = 0
    private var lastSaveAt = Date.distantPast

    func shouldSave(_ record: RunRecord) -> Bool {
        let totals = record.totals
        let completed = totals.verified + totals.alreadyOnPC + totals.failed + totals.unavailable
        let problems = totals.failed + totals.unavailable
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        let due = record.status != .running
            || problems != lastSavedProblems
            || (completed - lastSavedCompleted) >= 15
            || now.timeIntervalSince(lastSaveAt) >= 3.0
        if due {
            lastSavedCompleted = completed
            lastSavedProblems = problems
            lastSaveAt = now
        }
        return due
    }
}

@MainActor
@Observable
final class BackupModel {
    private(set) var record: RunRecord?
    private(set) var stopMessage: String?
    /// Current Photos library authorization mapped to Core's rule set.
    private(set) var photoAccess: LibraryAccess = .notDetermined
    /// Latest lightweight snapshot of the library (newest first), used by the Library and Backup feeds.
    private(set) var librarySnapshot: [MewtPhotosCore.LibraryItem] = []
    /// What Photos returns for the run's fetch, and how many of those are hidden. Shown to diagnose hidden photos.
    private(set) var libraryCounts: (total: Int, hidden: Int)?
    /// How many of this iPhone's photos the PC holds; nil until it has been asked.
    private(set) var pcCount: Int?
    private(set) var pcCountFailed = false
    /// Which library items the PC holds, and what it is missing; nil until it has been checked (milestone 7).
    private(set) var coverage: Coverage?
    private(set) var coverageFailed = false
    private(set) var recounting = false
    private(set) var running = false
    private(set) var isBackgroundRun = false
    /// Live transfer telemetry for the active file.
    private(set) var activeFileName = ""
    private(set) var activePhaseText = "Resumable stream"
    private(set) var activeFileProgress: Double = 0
    private(set) var transferSpeedMBps: Double = 0
    private(set) var speedSamples: [Double] = [0, 0, 0, 0, 0, 0, 0, 0]
    /// Lazily inspected PHAssetResource descriptions keyed by asset localIdentifier.
    private(set) var inspectedParts: [String: [String]] = [:]
    private var stopRequested = false
    private var activeSendTasks: [UUID: Task<SendResult, Error>] = [:]
    private var pauseTasks: [UUID: Task<Void, Never>] = [:]
    private var lastTelemetryAt: ContinuousClock.Instant?
    private let store: RunStore
    private let work: URL
    private let log: RunLog?

    init(supportDirectory: URL, log: RunLog? = nil) {
        self.log = log
        store = RunStore(directory: supportDirectory)
        work = supportDirectory.appendingPathComponent("backup-work", isDirectory: true)
        record = store.load()
        photoAccess = Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Anything left from an earlier run is removed; the run record decides what is sent again.
        if let files = try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    func refreshPhotoAccess() {
        photoAccess = Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestPhotoAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccess = Self.mapAuthorization(status)
    }

    /// Reads photo access, refreshes the library snapshot, and compares coverage with the paired server.
    func recount(pairing: AppModel) async {
        refreshPhotoAccess()
        guard photoAccess.canRun else {
            librarySnapshot = []
            libraryCounts = nil
            coverage = nil
            return
        }
        guard !recounting else { return }
        recounting = true
        defer { recounting = false }

        let (items, _) = await Task.detached(priority: .userInitiated) { BackupModel.libraryItems() }.value
        librarySnapshot = items
        libraryCounts = (items.count, items.filter(\.hidden).count)

        guard let connection = await pairing.connection() else {
            coverage = nil
            pcCount = nil
            return
        }
        do {
            let held = try await connection.client.heldAssetIds(key: connection.key)
            coverage = Coverage.compare(library: items, held: held)
            coverageFailed = false
        } catch {
            coverageFailed = true
        }
        await refreshPCCount(pairing: pairing)
        await pairing.refreshServerStatus()
    }

    /// Lazily reads PHAssetResource metadata for one item when expanded in the UI (zero file export).
    func inspectResourceParts(assetId: String) {
        guard inspectedParts[assetId] == nil else { return }
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = true
        fetchOptions.includeAllBurstAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: fetchOptions).firstObject else {
            inspectedParts[assetId] = ["Asset no longer in library"]
            return
        }
        let resources = PHAssetResource.assetResources(for: asset)
        if resources.isEmpty {
            inspectedParts[assetId] = ["No stored resources found"]
            return
        }
        inspectedParts[assetId] = resources.map { resource in
            let kind = Self.resourceKindLabel(resource.type)
            let size = (resource.value(forKey: "fileSize") as? Int64).map { " · " + ItemParts.formatBytes($0) } ?? ""
            return "\(resource.originalFilename) (\(kind))\(size)"
        }
    }

    private static func mapAuthorization(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func resourceKindLabel(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "Original photo"
        case .video: return "Original video"
        case .audio: return "Audio"
        case .alternatePhoto: return "RAW companion"
        case .fullSizePhoto: return "Edited · skipped"
        case .fullSizeVideo: return "Edited video · skipped"
        case .adjustmentData: return "Edit data · skipped"
        case .adjustmentBasePhoto: return "Adjustment base"
        case .pairedVideo: return "Live Photo paired"
        case .fullSizePairedVideo: return "Edited Live video · skipped"
        case .adjustmentBasePairedVideo: return "Live base video"
        case .adjustmentBaseVideo: return "Adjustment base video"
        @unknown default: return "Resource"
        }
    }

    /// Stops the run immediately, cancelling any in-flight export, upload, or retry wait.
    /// The interrupted item stays pending in the run record so the next run resumes cleanly.
    func stop() {
        stopRequested = true
        activePhaseText = "Stopping…"
        for task in activeSendTasks.values { task.cancel() }
        for task in pauseTasks.values { task.cancel() }
        StreamUploader.shared.cancelActive()
        ActiveExportTracker.shared.cancelActive()
    }

    /// Starts a run, or continues the unfinished one. Items the PC already has are skipped by identity.
    func start(pairing: AppModel, isBackgroundTask: Bool = false) async {
        guard !running else { return }
        refreshPhotoAccess()
        guard photoAccess.canRun else {
            stopMessage = photoAccess.message
            return
        }
        guard let connection = await pairing.connection() else {
            stopMessage = "Pair with your server first."
            return
        }
        running = true
        isBackgroundRun = isBackgroundTask
        stopRequested = false
        stopMessage = nil
        activeFileName = ""
        activePhaseText = "Checking library…"
        activeFileProgress = 0
        transferSpeedMBps = 0
        speedSamples = [0, 0, 0, 0, 0, 0, 0, 0]
        lastTelemetryAt = nil
        if !isBackgroundTask {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        defer {
            running = false
            isBackgroundRun = false
            activeFileName = ""
            activePhaseText = "Resumable stream"
            activeFileProgress = 0
            transferSpeedMBps = 0
            activeSendTasks.removeAll()
            pauseTasks.removeAll()
            lastTelemetryAt = nil
            if !isBackgroundTask {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }

        // Clear any leftover tasks in the legacy background URLSession (e.g. stalled tasks from older builds).
        BackgroundUploader.shared.cancelAllTasks()

        // Always refresh server status so capability flags (like oneShotMetadata) take effect immediately.
        await pairing.refreshServerStatus()
        let useOneShot = pairing.serverStatus?.oneShotMetadata == true

        let (items, paired) = await Task.detached(priority: .userInitiated) { BackupModel.libraryItems() }.value
        librarySnapshot = items
        libraryCounts = (items.count, items.filter(\.hidden).count)
        let flags: [Bool]
        do {
            flags = try await connection.client.knownAssets(key: connection.key, assetIds: items.map(\.assetId))
        } catch {
            stopMessage = "Could not check with the server. Make sure it is reachable, then try again."
            await log?.append(.error, code: "backup_check_failed", "knownAssets check failed: \(error.localizedDescription)")
            return
        }
        var known = Set<String>()
        // A photo with a second original is not skipped on the strength of its first part. The export re-checks each
        // part (the PC answers "already backed up" per file), so a missing companion is still sent.
        for (item, held) in zip(items, flags) where held && !paired.contains(item.assetId) { known.insert(item.assetId) }
        let plan = BackupPlanner.plan(items, alreadyOnPC: known)
        let opened = RunRecord.open(existing: store.load(), plan: plan, at: Date())
        record = opened
        let store = self.store
        let runLog = self.log
        let pendingCount = opened.entries.filter { $0.outcome == .pending }.count
        let sharedSessionId: String? = pendingCount > 0
            ? (try? await connection.client.createSession(key: connection.key, selectedCount: pendingCount, libraryCount: items.count))
            : nil
        await runLog?.append(
            .info,
            code: "backup_start",
            "items=\(opened.entries.count) pending=\(pendingCount) bg=\(isBackgroundTask) oneShot=\(useOneShot) sharedSession=\(sharedSessionId != nil)"
        )

        let saveThrottle = RecordSaveThrottle()
        let throughput = ThroughputMeter()
        let runner = BackupRunner(
            prepare: { entry in
                await MainActor.run {
                    if self.activeFileName.isEmpty {
                        self.activeFileName = entry.fileName
                        self.activePhaseText = "Preparing original…"
                        self.activeFileProgress = 0
                    }
                }
                do {
                    return try await BackupModel.prepare(entry, work: await self.workFolder())
                } catch {
                    if !(error is CancellationError) {
                        await runLog?.append(.warn, code: "backup_prepare_error", "\(entry.fileName): \(error)")
                    }
                    throw error
                }
            },
            send: { item in
                let taskId = UUID()
                let task = Task<SendResult, Error> {
                    try await BackupModel.send(
                        item,
                        connection: connection,
                        work: await self.workFolder(),
                        sessionId: sharedSessionId,
                        useOneShot: useOneShot,
                        onPhase: { phase in
                            Task { @MainActor in
                                if !self.stopRequested {
                                    self.activeFileName = item.entry.fileName
                                    self.activePhaseText = phase
                                }
                            }
                        },
                        onProgress: { fileName, fraction, bytesDelta in
                            let aggregateMbps = throughput.record(bytes: bytesDelta)
                            Task { @MainActor in
                                self.recordTransferSample(fileName: fileName, fraction: fraction, mbps: aggregateMbps)
                            }
                        }
                    )
                }
                await MainActor.run {
                    self.activeSendTasks[taskId] = task
                    if self.stopRequested { task.cancel() }
                }
                defer {
                    Task { @MainActor in self.activeSendTasks.removeValue(forKey: taskId) }
                }
                do {
                    let outcome = try await task.value
                    await MainActor.run {
                        if let currentCoverage = self.coverage {
                            self.coverage = currentCoverage.markingHeld(item.entry.assetId)
                        }
                    }
                    return outcome
                } catch {
                    if !(error is CancellationError) {
                        await runLog?.append(.warn, code: "backup_send_error", "\(item.entry.fileName): \(error)")
                    }
                    throw error
                }
            },
            discard: { item in
                try? FileManager.default.removeItem(at: item.fileURL)
                for part in item.companions { try? FileManager.default.removeItem(at: part.fileURL) }
            },
            stopRequested: { await self.stopFlag() },
            pause: { seconds in
                await self.cancellablePause(seconds: seconds)
            },
            maxConcurrency: 3)
        let result = await runner.run(opened, now: Date()) { saved in
            if saveThrottle.shouldSave(saved) {
                try? store.save(saved)
            }
            Task { @MainActor in self.record = saved }
        }
        try? store.save(result.record)
        record = result.record
        stopMessage = result.stopMessage
        let totals = result.record.totals
        await runLog?.append(
            .info,
            code: "backup_end",
            "status=\(result.record.status.rawValue) verified=\(totals.verified) onServer=\(totals.alreadyOnPC) failed=\(totals.failed) unavail=\(totals.unavailable) pending=\(totals.pending)"
        )
        await refreshPCCount(pairing: pairing)
        await refreshCoverage(pairing: pairing)
        await pairing.refreshServerStatus()
    }

    private func cancellablePause(seconds: Double) async {
        guard !stopRequested else { return }
        activePhaseText = "Retrying in \(max(1, Int(seconds.rounded())))s…"
        let id = UUID()
        let sleepTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        pauseTasks[id] = sleepTask
        await sleepTask.value
        pauseTasks.removeValue(forKey: id)
    }

    private func recordTransferSample(fileName: String, fraction: Double, mbps: Double) {
        let clamped = min(max(fraction, 0), 1)
        let now = ContinuousClock.now
        if clamped < 1.0, let last = lastTelemetryAt {
            let parts = last.duration(to: now).components
            let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            if elapsed < 0.1 { return }
        }
        lastTelemetryAt = now
        activeFileName = fileName
        activeFileProgress = clamped
        if mbps > 0 {
            transferSpeedMBps = mbps
            speedSamples.append(mbps)
            if speedSamples.count > 12 {
                speedSamples.removeFirst(speedSamples.count - 12)
            }
        }
    }

    func refreshLibraryCounts() {
        libraryCounts = Self.countLibrary()
    }

    /// Sends every failed item of the last run again. Unavailable items stay as they are.
    func retryFailed(pairing: AppModel) async {
        guard !running, var saved = store.load(), saved.retryFailed() > 0 else { return }
        try? store.save(saved)
        await start(pairing: pairing)
    }

    /// Sends one failed item again. The run continues from it, like a Back up now.
    func retry(assetId: String, pairing: AppModel) async {
        guard !running, var saved = store.load(),
              let index = saved.entries.firstIndex(where: { $0.assetId == assetId }), saved.retry(at: index) else { return }
        try? store.save(saved)
        await start(pairing: pairing)
    }

    /// Asks the PC how many of this iPhone's photos it holds. A failed check keeps the last answer and sets
    /// `pcCountFailed`, so the screen can say the check did not work instead of showing nothing.
    func refreshPCCount(pairing: AppModel) async {
        guard let connection = await pairing.connection() else { return }
        do {
            pcCount = try await connection.client.storedAssetCount(key: connection.key)
            pcCountFailed = false
        } catch {
            pcCountFailed = true
        }
    }

    /// Compares the library with the PC's list of held photos. A failed check keeps the last answer and sets
    /// `coverageFailed`. Photos the PC has that the library no longer has are kept on purpose and only counted.
    func refreshCoverage(pairing: AppModel) async {
        guard let connection = await pairing.connection() else { return }
        let (items, _) = await Task.detached(priority: .userInitiated) { BackupModel.libraryItems() }.value
        do {
            coverage = Coverage.compare(library: items, held: try await connection.client.heldAssetIds(key: connection.key))
            coverageFailed = false
        } catch {
            coverageFailed = true
        }
    }

    private func stopFlag() -> Bool { stopRequested }

    private func workFolder() -> URL { work }

    /// Every asset in the library: the main fetch, plus the Hidden album. The main fetch alone returned no
    /// hidden items on the phone, so the Hidden album is read directly and anything new from it is added.
    nonisolated static func libraryAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        var assets: [PHAsset] = []
        var seen = Set<String>()
        func add(_ result: PHFetchResult<PHAsset>) {
            result.enumerateObjects { asset, _, _ in
                if seen.insert(asset.localIdentifier).inserted { assets.append(asset) }
            }
        }
        add(PHAsset.fetchAssets(with: options))
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumAllHidden, options: nil)
            .enumerateObjects { album, _, _ in
                add(PHAsset.fetchAssets(in: album, options: options))
            }
        return assets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    /// Counts the items the run sees and how many are hidden. Reads no files.
    nonisolated static func countLibrary() -> (total: Int, hidden: Int) {
        let assets = libraryAssets()
        return (assets.count, assets.filter(\.isHidden).count)
    }

    /// Every item in the library, newest first, with what the planner needs. Hidden items and every burst frame
    /// are included.
    /// The items, plus the identifiers of photos that have a second original (a RAW's JPEG or HEIC). Those are never
    /// skipped as "already on the PC" from the first part alone, so the second part is always checked and sent.
    nonisolated static func libraryItems() -> (items: [MewtPhotosCore.LibraryItem], paired: Set<String>) {
        var items: [MewtPhotosCore.LibraryItem] = []
        var paired = Set<String>()
        for asset in libraryAssets() {
            let resources = PHAssetResource.assetResources(for: asset)
            let name = resources.first { $0.type == .photo || $0.type == .fullSizePhoto }?.originalFilename
                ?? resources.first?.originalFilename ?? "item"
            let kind: ItemKind = asset.mediaType == .video ? .video
                : (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
            if resources.contains(where: { $0.type == .alternatePhoto || $0.type == .pairedVideo }) { paired.insert(asset.localIdentifier) }
            items.append(MewtPhotosCore.LibraryItem(assetId: asset.localIdentifier, fileName: name, kind: kind,
                                     onPhone: true, hidden: asset.isHidden, date: asset.creationDate))
        }
        return (items, paired)
    }

    /// Exports one original to the work folder. Checks the phone's free space first; an original that cannot be
    /// read without iCloud is reported as not supported, never as backed up.
    nonisolated static func prepare(_ entry: RunEntry, work: URL) async throws -> PreparedItem {
        // Without these options Photos leaves out burst frames other than the key photo, and hidden photos, so the
        // item looks deleted. The same options as the library list keep the two in step.
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = true
        fetchOptions.includeAllBurstAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entry.assetId], options: fetchOptions).firstObject else {
            throw ItemError.unavailable("It is no longer in the library.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        // A video's original is its .video resource; a photo's is .photo, or .fullSizePhoto when that is all there is.
        let mainTypes: [PHAssetResourceType] = asset.mediaType == .video ? [.video] : [.photo, .fullSizePhoto]
        guard let resource = resources.first(where: { mainTypes.contains($0.type) }) else {
            throw ItemError.unavailable(BackupPlanner.unsupportedReason)
        }
        // The other original of the same photo: a RAW's JPEG or HEIC (alternatePhoto), or a Live Photo's video
        // (pairedVideo). Only one is supported; a photo with both is not complete, so it is not sent.
        let candidates = resources.filter {
            ($0.type == .alternatePhoto || $0.type == .pairedVideo) && $0.originalFilename != resource.originalFilename
        }
        guard candidates.count <= 1 else { throw ItemError.unavailable(BackupPlanner.unsupportedReason) }
        let companionResource = candidates.first
        let expected = [resource, companionResource].compactMap { $0 }.reduce(Int64(0)) {
            $0 + (($1.value(forKey: "fileSize") as? Int64) ?? 0)
        }
        guard PhoneSpace.hasRoom(free: freeBytes(), needed: expected) else { throw ItemError.phoneFull }

        let main = try await export(resource, work: work)
        var companions: [PreparedPart] = []
        if let companionResource {
            do {
                companions.append(try await export(companionResource, work: work))
            } catch {
                // Without the companion the photo is not complete, so the main copy is not kept either.
                try? FileManager.default.removeItem(at: main.fileURL)
                throw error
            }
        }
        return PreparedItem(entry: entry, fileURL: main.fileURL, bytes: main.bytes, sha256: main.sha256,
                            hidden: asset.isHidden, companions: companions)
    }

    /// Streams one original to the work folder while computing its SHA-256 in a single pass.
    /// Network access is off so iCloud-only originals fail immediately as unavailable; a 60s inactivity
    /// watchdog and `ActiveExportTracker` guarantee PhotoKit can never stall the backup forever.
    private nonisolated static func export(_ resource: PHAssetResource, work: URL) async throws -> PreparedPart {
        try Task.checkCancellation()
        let url = work.appendingPathComponent(UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ItemError.failed("Could not create a temporary copy on this iPhone.")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ItemError.failed("Could not open a temporary copy on this iPhone.")
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        let state = ExportState(fileHandle: handle)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PreparedPart, Error>) in
            func finish(_ result: Result<PreparedPart, Error>) {
                state.lock.lock()
                guard !state.resumed else {
                    state.lock.unlock()
                    return
                }
                state.resumed = true
                let timer = state.watchdog
                state.watchdog = nil
                let fh = state.fileHandle
                state.fileHandle = nil
                let reqId = state.requestId
                state.lock.unlock()

                timer?.cancel()
                if let reqId { ActiveExportTracker.shared.clear(id: reqId) }
                try? fh?.close()
                if case .failure = result {
                    try? FileManager.default.removeItem(at: url)
                }
                continuation.resume(with: result)
            }

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler {
                state.lock.lock()
                let inactive = Date().timeIntervalSince(state.lastActivity)
                let reqId = state.requestId
                let alreadyResumed = state.resumed
                state.lock.unlock()
                if !alreadyResumed && inactive >= 60 {
                    if let reqId {
                        PHAssetResourceManager.default().cancelDataRequest(reqId)
                    }
                    finish(.failure(ItemError.transient("Reading this original from Photos timed out. It will be tried again.")))
                }
            }
            state.lock.lock()
            state.watchdog = timer
            state.lock.unlock()
            timer.resume()

            let reqId = PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    state.lock.lock()
                    guard !state.resumed, state.writeError == nil, let fh = state.fileHandle else {
                        state.lock.unlock()
                        return
                    }
                    state.lastActivity = Date()
                    do {
                        try fh.write(contentsOf: chunk)
                        state.hasher.update(data: chunk)
                        state.bytes += Int64(chunk.count)
                        state.lock.unlock()
                    } catch {
                        state.writeError = error
                        let id = state.requestId
                        state.lock.unlock()
                        if let id {
                            PHAssetResourceManager.default().cancelDataRequest(id)
                        }
                    }
                },
                completionHandler: { error in
                    state.lock.lock()
                    let writeErr = state.writeError
                    let bytes = state.bytes
                    let hash = state.hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    state.lock.unlock()

                    if writeErr != nil {
                        finish(.failure(ItemError.failed("Could not save a temporary copy on this iPhone.")))
                    } else if error != nil {
                        finish(.failure(ItemError.unavailable(BackupPlanner.unsupportedReason)))
                    } else {
                        finish(.success(PreparedPart(fileName: resource.originalFilename, fileURL: url, bytes: bytes, sha256: hash)))
                    }
                }
            )

            state.lock.lock()
            state.requestId = reqId
            let alreadyResumed = state.resumed
            state.lock.unlock()

            if !alreadyResumed {
                ActiveExportTracker.shared.register(id: reqId) {
                    finish(.failure(CancellationError()))
                }
            }
        }
    }

    /// Opens the upload on the PC, streams the bytes over Wi-Fi, and finishes it. Only `verified` or
    /// `duplicate` from the PC counts as backed up.
    /// Sends every part of the photo. Companions go first, without the asset identifier, and the main file last with it,
    /// so the PC counts the photo as held only after every part is verified.
    /// Files smaller than this use the single-request `POST /api/v1/files` endpoint (when supported by
    /// the server) to avoid 3 round-trips per photo; larger files use resumable `PATCH`.
    private nonisolated static let oneShotThresholdBytes: Int64 = 16 * 1024 * 1024

    nonisolated static func send(
        _ item: PreparedItem,
        connection: PairedConnection,
        work: URL,
        sessionId: String? = nil,
        useOneShot: Bool = false,
        onPhase: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (String, Double, Int64) -> Void)? = nil
    ) async throws -> SendResult {
        let pairId: String? = item.companions.isEmpty ? nil : item.entry.assetId
        var results: [SendResult] = []
        for companion in item.companions {
            results.append(try await sendPart(companion, item: item, assetId: nil, pairId: pairId,
                                              pairName: item.entry.fileName, connection: connection,
                                              sessionId: sessionId, useOneShot: useOneShot,
                                              onPhase: onPhase, onProgress: onProgress))
        }
        let main = PreparedPart(fileName: item.entry.fileName, fileURL: item.fileURL, bytes: item.bytes, sha256: item.sha256)
        results.append(try await sendPart(main, item: item, assetId: item.entry.assetId, pairId: pairId,
                                          pairName: item.companions.first?.fileName, connection: connection,
                                          sessionId: sessionId, useOneShot: useOneShot,
                                          onPhase: onPhase, onProgress: onProgress))
        return PhotoParts.combine(results)
    }

    /// Sends one file: single-request `POST /api/v1/files` for smaller files on servers that support
    /// native metadata, or the 3-step resumable `beginUpload` -> `PATCH` -> `finishUpload` flow for large files.
    private nonisolated static func sendPart(
        _ part: PreparedPart,
        item: PreparedItem,
        assetId: String?,
        pairId: String?,
        pairName: String?,
        connection: PairedConnection,
        sessionId: String?,
        useOneShot: Bool,
        onPhase: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (String, Double, Int64) -> Void)? = nil
    ) async throws -> SendResult {
        try Task.checkCancellation()
        let name = part.fileName
        let lastModified = item.entry.date.map { Int64($0.timeIntervalSince1970 * 1000) }

        if useOneShot && part.bytes > 0 && part.bytes < oneShotThresholdBytes,
           let url = ServerClient.oneShotUploadURL(
               base: connection.base,
               filename: name,
               sessionId: sessionId,
               sha256: part.sha256,
               assetId: assetId,
               hidden: item.hidden,
               lastModified: lastModified,
               pairId: pairId,
               pairName: pairName
           ) {
            return try await sendPartOneShot(
                part, url: url, connection: connection, onPhase: onPhase, onProgress: onProgress
            )
        }

        onPhase?("Opening upload…")
        let begun: BegunUpload
        do {
            begun = try await connection.client.beginUpload(
                key: connection.key, filename: name, mimeType: mimeType(for: name), size: part.bytes,
                sha256: part.sha256, assetId: assetId, hidden: item.hidden,
                lastModified: lastModified, pairId: pairId, pairName: pairName, sessionId: sessionId)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapped(error)
        }
        if begun.alreadyStored {
            onProgress?(name, 1.0, 0)
            return .alreadyOnPC
        }

        if begun.offset < part.bytes {
            let source = begun.offset == 0 ? part.fileURL : try BackgroundUploader.tail(of: part.fileURL, from: begun.offset)
            defer {
                if source != part.fileURL { try? FileManager.default.removeItem(at: source) }
            }
            onPhase?("Uploading…")
            var request = URLRequest(url: connection.base.appendingPathComponent("api/v1/uploads/\(begun.uploadId)"))
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(connection.key.revealForAuthorization())", forHTTPHeaderField: "Authorization")
            request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(begun.offset), forHTTPHeaderField: "Upload-Offset")
            let baseOffset = begun.offset
            let totalSize = part.bytes
            _ = try await transfer(request, from: source) { deltaBytes, sentBytes, _ in
                let fraction = totalSize > 0 ? Double(baseOffset + sentBytes) / Double(totalSize) : 1.0
                onProgress?(name, fraction, deltaBytes)
            }
            onProgress?(name, 1.0, 0)
        }

        onPhase?("Verifying on server…")
        do {
            let finished = try await connection.client.finishUpload(key: connection.key, uploadId: begun.uploadId, sha256: part.sha256)
            switch finished.status {
            case "verified":
                onProgress?(name, 1.0, 0)
                return .verified
            case "duplicate":
                onProgress?(name, 1.0, 0)
                return .alreadyOnPC
            default: throw ItemError.failed("The PC did not confirm this photo.")
            }
        } catch let error as ItemError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ServerClientError {
            throw mappedFinish(error)
        } catch {
            throw ItemError.transient("The PC has not confirmed this photo yet. It will be tried again.")
        }
    }

    /// Single-request upload + server SHA-256 verification for smaller files (`< 16 MB`).
    private nonisolated static func sendPartOneShot(
        _ part: PreparedPart,
        url: URL,
        connection: PairedConnection,
        onPhase: (@Sendable (String) -> Void)?,
        onProgress: (@Sendable (String, Double, Int64) -> Void)?
    ) async throws -> SendResult {
        let name = part.fileName
        onPhase?("Uploading…")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(connection.key.revealForAuthorization())", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType(for: name), forHTTPHeaderField: "Content-Type")
        let totalSize = part.bytes
        let body = try await transfer(request, from: part.fileURL) { deltaBytes, sentBytes, _ in
            let fraction = totalSize > 0 ? Double(sentBytes) / Double(totalSize) : 1.0
            onProgress?(name, fraction, deltaBytes)
        }
        let reply: (status: String, endToEndVerified: Bool)
        do {
            reply = try ServerClient.decodeUploadResult(from: body)
        } catch {
            throw ItemError.transient("The PC has not confirmed this photo yet. It will be tried again.")
        }
        switch reply.status {
        case "verified":
            onProgress?(name, 1.0, 0)
            return .verified
        case "duplicate":
            onProgress?(name, 1.0, 0)
            return .alreadyOnPC
        default:
            throw ItemError.failed("The PC did not confirm this photo.")
        }
    }

    /// Streams the file over an in-process URLSession with stall detection and immediate cancellation.
    /// Returns the response body on 2xx. A full PC disk is reported as `pcFull` so the run stops.
    private nonisolated static func transfer(
        _ request: URLRequest,
        from file: URL,
        progress: ((Int64, Int64, Int64) -> Void)? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            StreamUploader.shared.send(request, fromFile: file, progress: progress) { status, data, error in
                if let status, (200..<300).contains(status) {
                    continuation.resume(returning: data)
                } else if status == 507 {
                    continuation.resume(throwing: ItemError.pcFull)
                } else if status == 401 {
                    continuation.resume(throwing: ItemError.failed("The PC no longer accepts this iPhone. Pair again."))
                } else if let nsError = error as NSError?,
                          nsError.domain == NSURLErrorDomain,
                          nsError.code == NSURLErrorCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let nsError = error as NSError?,
                          nsError.domain == NSURLErrorDomain,
                          nsError.code == NSURLErrorTimedOut {
                    continuation.resume(throwing: ItemError.transient("The transfer stalled. It will be tried again."))
                } else if let nsError = error as NSError?, NetworkErrors.isTransient(domain: nsError.domain, code: nsError.code) {
                    continuation.resume(throwing: ItemError.transient("The connection dropped while sending. It will be tried again."))
                } else if let status {
                    let parsed = ServerClient.decodeErrorBody(from: data, status: status)
                    let retryable = status >= 500 || status == 408 || status == 422
                        || (status == 409 && parsed.code == "upload_busy")
                        || parsed.code == "client_disconnected" || parsed.code == "upload_timeout"
                    continuation.resume(throwing: retryable ? ItemError.transient(parsed.message) : ItemError.failed(parsed.message))
                } else {
                    continuation.resume(throwing: ItemError.transient("The PC did not take this photo. It will be tried again."))
                }
            }
        }
    }

    private nonisolated static func mapped(_ error: Error) -> ItemError {
        switch error as? ServerClientError {
        case .server(let status, let code, let message)?:
            if status == 507 { return .pcFull }
            if status == 401 { return .failed("The PC no longer accepts this iPhone. Pair again.") }
            if status >= 500 || status == 408 || (status == 409 && code == "upload_busy") {
                return .transient(message)
            }
            return .failed(message)
        case .network(let failure)?:
            return NetworkErrors.isTransient(domain: failure.domain, code: failure.code)
                ? .transient("Could not reach the PC. It will be tried again.")
                : .failed("Could not reach the PC.")
        default:
            return .failed("Something went wrong while sending this photo.")
        }
    }

    private nonisolated static func mappedFinish(_ error: ServerClientError) -> ItemError {
        switch error {
        case .server(let status, let code, let message):
            if status == 507 { return .pcFull }
            if status == 401 { return .failed("The PC no longer accepts this iPhone. Pair again.") }
            if status >= 500 || status == 408 || (status == 409 && code == "upload_busy") {
                return .transient(message)
            }
            return .failed(message)
        case .network:
            return .transient("The PC has not confirmed this photo yet. It will be tried again.")
        default:
            return .failed("The PC did not confirm this photo.")
        }
    }

    private nonisolated static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "dng": return "image/x-adobe-dng"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    /// Free bytes on the phone. If iOS does not say, assume enough: the reserve check is a safety margin only.
    private nonisolated static func freeBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attributes?[.systemFreeSize] as? Int64) ?? Int64.max
    }
}

struct BackupView: View {
    let pairing: AppModel
    let model: BackupModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""

    var body: some View {
        Screen {
            Panel {
                Text(BackupPlanner.editsNotice)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                if model.running {
                    if let record = model.record {
                        let done = record.entries.filter { $0.outcome != .pending }.count
                        ProgressView(value: Double(done), total: Double(max(record.entries.count, 1)))
                            .tint(Theme.accent)
                    }
                    Text("Keep this screen open. The phone stays awake while the backup runs.")
                        .foregroundStyle(Theme.text)
                    if let current = Self.currentText(model.record) {
                        Text(current)
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                    Button("Stop", role: .destructive) { model.stop() }
                        .buttonStyle(.danger)
                } else {
                    Button {
                        Task { await model.start(pairing: pairing) }
                    } label: {
                        Label("Back up now", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.primary)
                    if let failed = model.record?.totals.failed, failed > 0 {
                        Button("Retry \(failed) failed") {
                            Task { await model.retryFailed(pairing: pairing) }
                        }
                        .buttonStyle(.secondary)
                    }
                }
                if let stopMessage = model.stopMessage {
                    Callout(text: stopMessage)
                }
                if let counts = model.libraryCounts {
                    Text("The app's list of photos has \(counts.total) items, \(counts.hidden) of them hidden.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            if let coverage = model.coverage {
                Panel("Coverage") {
                    if coverage.isVerified {
                        Callout(text: "Coverage verified: every photo in the library is on the PC.",
                                systemName: "checkmark.seal.fill", tint: Theme.good)
                    } else {
                        Callout(text: "\(coverage.missing.count) photos in the library are not on the PC.",
                                tint: Theme.warn)
                        ForEach(Array(coverage.missing.prefix(20).enumerated()), id: \.offset) { _, item in
                            Text(item.fileName).font(.footnote).foregroundStyle(Theme.text)
                        }
                        if coverage.missing.count > 20 {
                            Text("…and \(coverage.missing.count - 20) more. Back up now sends what it can.")
                                .font(.footnote)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Text("The PC holds \(coverage.held) library photos. On the PC but no longer on this iPhone: \(coverage.onPCOnly). Kept on purpose.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    if model.coverageFailed {
                        Callout(text: "Could not check coverage. Make sure the PC is on and reachable, then reopen this screen.")
                    }
                }
            }
            if let record = model.record {
                Panel("Last run") {
                    Text("Considered \(record.totals.considered)")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            StatTile(value: record.totals.alreadyOnPC, label: "Already on PC")
                            StatTile(value: record.totals.verified, label: "Verified", tint: Theme.good)
                        }
                        GridRow {
                            StatTile(value: record.totals.failed, label: "Failed",
                                     tint: record.totals.failed > 0 ? Theme.bad : Theme.text)
                            StatTile(value: record.totals.unavailable, label: "Unavailable",
                                     tint: record.totals.unavailable > 0 ? Theme.warn : Theme.text)
                        }
                    }
                    Text(record.status == .finished ? "Finished." : "Not finished. Back up now continues it.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    if let pcCount = model.pcCount {
                        Text("The PC holds \(pcCount) of this iPhone's photos.")
                            .foregroundStyle(Theme.text)
                        // The PC should hold at least everything this run counted as backed up.
                        if pcCount < record.totals.verified + record.totals.alreadyOnPC {
                            Callout(text: "The PC has fewer of these photos than this run counted. Check the PC's backup folder, then run again.")
                        }
                    }
                    if model.pcCountFailed {
                        Callout(text: "Could not check the PC's count. Make sure the PC is on and reachable, then reopen this screen.")
                    }
                }
                if !search.isEmpty {
                    // Searches every item in this run, not only the failed ones, so a missing photo can be told apart.
                    let matches = record.entries.filter { $0.fileName.localizedCaseInsensitiveContains(search) }
                    Panel("Search this run") {
                        if matches.isEmpty {
                            Text("No item named \"\(search)\" is in this run. The phone's list of photos did not include it.")
                                .foregroundStyle(Theme.muted)
                        }
                        ForEach(Array(matches.prefix(50).enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.fileName)
                                    .foregroundStyle(Theme.text)
                                if let date = entry.date {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.footnote)
                                        .foregroundStyle(Theme.muted)
                                }
                                Text(Self.statusText(entry.outcome))
                                    .font(.footnote)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                let problems = record.entries.filter {
                    if case .failed = $0.outcome { return true }
                    if case .unavailable = $0.outcome { return true }
                    return false
                }
                if !problems.isEmpty {
                    Panel("Not backed up") {
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.fileName)
                                    .foregroundStyle(Theme.text)
                                if let date = entry.date {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.footnote)
                                        .foregroundStyle(Theme.muted)
                                }
                                Text(Self.reason(entry.outcome))
                                    .font(.footnote)
                                    .foregroundStyle(Theme.muted)
                                if Self.isFailed(entry.outcome) {
                                    Button("Retry") {
                                        Task { await model.retry(assetId: entry.assetId, pairing: pairing) }
                                    }
                                    .buttonStyle(.secondary)
                                    .disabled(model.running)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Back up photos")
        .searchable(text: $search, prompt: "File name, e.g. IMG_4303")
        .task {
            model.refreshLibraryCounts()
            await model.refreshPCCount(pairing: pairing)
            await model.refreshCoverage(pairing: pairing)
        }
        .onChange(of: scenePhase) { _, phase in
            // Going to the background pauses the run after the item in progress; the record keeps the rest.
            // Not .inactive: pulling down Control Center or the notification shade also reports inactive,
            // and that stopped the run when the Wi-Fi was toggled from there.
            if phase == .background { model.stop() }
        }
    }

    /// "Item N of M: name" for the item being worked on, from the saved record.
    private static func currentText(_ record: RunRecord?) -> String? {
        guard let record, let index = record.nextPending else { return nil }
        let done = record.entries.filter { $0.outcome != .pending }.count
        return "Item \(done + 1) of \(record.entries.count): \(record.entries[index].fileName)"
    }

    private static func isFailed(_ outcome: ItemOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    private static func statusText(_ outcome: ItemOutcome) -> String {
        switch outcome {
        case .pending: return "Not reached yet in this run"
        case .alreadyOnPC: return "Already on the PC"
        case .verified: return "Verified on the PC"
        case .failed(let reason), .unavailable(let reason): return reason
        }
    }

    private static func reason(_ outcome: ItemOutcome) -> String {
        switch outcome {
        case .failed(let reason), .unavailable(let reason): return reason
        default: return ""
        }
    }
}
