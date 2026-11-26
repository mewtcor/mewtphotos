// The backup run on the phone (Phase 5, plan 05-03): exports one original at a time, checks free space, sends
// it, and keeps the run record up to date. Read-only with respect to the library: nothing is changed or deleted.
// Photos is imported here, in the same allowed set as DiagnosticsView and LibraryView (see ci.yml).
import SwiftUI
import UIKit
import Photos
import CryptoKit
import MewtPhotosCore

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
    /// Live transfer telemetry for the active file.
    private(set) var activeFileName = ""
    private(set) var activeFileProgress: Double = 0
    private(set) var transferSpeedMBps: Double = 0
    private(set) var speedSamples: [Double] = [0, 0, 0, 0, 0, 0, 0, 0]
    /// Lazily inspected PHAssetResource descriptions keyed by asset localIdentifier.
    private(set) var inspectedParts: [String: [String]] = [:]
    private var stopRequested = false
    private let store: RunStore
    private let work: URL

    init(supportDirectory: URL) {
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

        let (items, _) = Self.libraryItems()
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

    /// Asks the run to stop after the item in progress. The record keeps what is done.
    func stop() {
        stopRequested = true
    }

    /// Starts a run, or continues the unfinished one. Items the PC already has are skipped by identity.
    func start(pairing: AppModel) async {
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
        stopRequested = false
        stopMessage = nil
        activeFileName = ""
        activeFileProgress = 0
        transferSpeedMBps = 0
        speedSamples = [0, 0, 0, 0, 0, 0, 0, 0]
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            running = false
            activeFileName = ""
            activeFileProgress = 0
            transferSpeedMBps = 0
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let (items, paired) = BackupModel.libraryItems()
        librarySnapshot = items
        libraryCounts = (items.count, items.filter(\.hidden).count)
        let flags: [Bool]
        do {
            flags = try await connection.client.knownAssets(key: connection.key, assetIds: items.map(\.assetId))
        } catch {
            stopMessage = "Could not check with the server. Make sure it is reachable, then try again."
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

        let runner = BackupRunner(
            prepare: { entry in
                await MainActor.run {
                    self.activeFileName = entry.fileName
                    self.activeFileProgress = 0
                }
                return try await BackupModel.prepare(entry, work: await self.workFolder())
            },
            send: { item in
                try await BackupModel.send(item, connection: connection, work: await self.workFolder()) { fileName, fraction, mbps in
                    Task { @MainActor in
                        self.recordTransferSample(fileName: fileName, fraction: fraction, mbps: mbps)
                    }
                }
            },
            discard: { item in
                try? FileManager.default.removeItem(at: item.fileURL)
                for part in item.companions { try? FileManager.default.removeItem(at: part.fileURL) }
            },
            stopRequested: { await self.stopFlag() },
            pause: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        let result = await runner.run(opened, now: Date()) { saved in
            try? store.save(saved)
            Task { @MainActor in self.record = saved }
        }
        record = result.record
        stopMessage = result.stopMessage
        await refreshPCCount(pairing: pairing)
        await refreshCoverage(pairing: pairing)
        await pairing.refreshServerStatus()
    }

    private func recordTransferSample(fileName: String, fraction: Double, mbps: Double) {
        activeFileName = fileName
        activeFileProgress = min(max(fraction, 0), 1)
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
        let (items, _) = Self.libraryItems()
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
    static func libraryAssets() -> [PHAsset] {
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
    static func countLibrary() -> (total: Int, hidden: Int) {
        let assets = libraryAssets()
        return (assets.count, assets.filter(\.isHidden).count)
    }

    /// Every item in the library, newest first, with what the planner needs. Hidden items and every burst frame
    /// are included.
    /// The items, plus the identifiers of photos that have a second original (a RAW's JPEG or HEIC). Those are never
    /// skipped as "already on the PC" from the first part alone, so the second part is always checked and sent.
    static func libraryItems() -> (items: [MewtPhotosCore.LibraryItem], paired: Set<String>) {
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
    static func prepare(_ entry: RunEntry, work: URL) async throws -> PreparedItem {
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

    /// Writes one original to the work folder and hashes it. Photos refuses to overwrite a file, so the name is
    /// always new. Network access is off: an original that exists only in iCloud cannot be read.
    private static func export(_ resource: PHAssetResource, work: URL) async throws -> PreparedPart {
        let url = work.appendingPathComponent(UUID().uuidString + ".part")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ItemError.unavailable(BackupPlanner.unsupportedReason)
        }
        do {
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let hash = try sha256(of: url)
            return PreparedPart(fileName: resource.originalFilename, fileURL: url, bytes: bytes, sha256: hash)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ItemError.failed("Could not read the copy on this iPhone.")
        }
    }

    /// Opens the upload on the PC, sends the bytes in the background, and finishes it. Only `verified` or
    /// `duplicate` from the PC counts as backed up.
    /// Sends every part of the photo. Companions go first, without the asset identifier, and the main file last with it,
    /// so the PC counts the photo as held only after every part is verified.
    static func send(
        _ item: PreparedItem,
        connection: PairedConnection,
        work: URL,
        onProgress: (@Sendable (String, Double, Double) -> Void)? = nil
    ) async throws -> SendResult {
        let pairId: String? = item.companions.isEmpty ? nil : item.entry.assetId
        var results: [SendResult] = []
        for companion in item.companions {
            results.append(try await sendPart(companion, item: item, assetId: nil, pairId: pairId,
                                              pairName: item.entry.fileName, connection: connection,
                                              onProgress: onProgress))
        }
        let main = PreparedPart(fileName: item.entry.fileName, fileURL: item.fileURL, bytes: item.bytes, sha256: item.sha256)
        results.append(try await sendPart(main, item: item, assetId: item.entry.assetId, pairId: pairId,
                                          pairName: item.companions.first?.fileName, connection: connection,
                                          onProgress: onProgress))
        return PhotoParts.combine(results)
    }

    /// Opens the upload for one file, sends the bytes in the background, and finishes it.
    private static func sendPart(
        _ part: PreparedPart,
        item: PreparedItem,
        assetId: String?,
        pairId: String?,
        pairName: String?,
        connection: PairedConnection,
        onProgress: (@Sendable (String, Double, Double) -> Void)? = nil
    ) async throws -> SendResult {
        let name = part.fileName
        let begun: BegunUpload
        do {
            begun = try await connection.client.beginUpload(
                key: connection.key, filename: name, mimeType: mimeType(for: name), size: part.bytes,
                sha256: part.sha256, assetId: assetId, hidden: item.hidden,
                lastModified: item.entry.date.map { Int64($0.timeIntervalSince1970 * 1000) },
                pairId: pairId, pairName: pairName)
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
            var request = URLRequest(url: connection.base.appendingPathComponent("api/v1/uploads/\(begun.uploadId)"))
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(connection.key.revealForAuthorization())", forHTTPHeaderField: "Authorization")
            request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(begun.offset), forHTTPHeaderField: "Upload-Offset")
            let started = ContinuousClock.now
            let baseOffset = begun.offset
            let totalSize = part.bytes
            try await transfer(request, from: source) { sentBytes, _ in
                let elapsedParts = started.duration(to: .now).components
                let elapsed = Double(elapsedParts.seconds) + Double(elapsedParts.attoseconds) / 1e18
                let mbps = elapsed > 0.05 ? (Double(sentBytes) / 1_000_000.0) / elapsed : 0
                let fraction = totalSize > 0 ? Double(baseOffset + sentBytes) / Double(totalSize) : 1.0
                onProgress?(name, fraction, mbps)
            }
        }

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
        } catch {
            throw ItemError.transient("The PC has not confirmed this photo yet. It will be tried again.")
        }
    }

    /// The background transfer, as an async call. A full PC disk is reported as `pcFull` so the run stops.
    private static func transfer(
        _ request: URLRequest,
        from file: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            BackgroundUploader.shared.send(request, fromFile: file, progress: progress) { status, error in
                if let status, (200..<300).contains(status) {
                    continuation.resume()
                } else if status == 507 {
                    continuation.resume(throwing: ItemError.pcFull)
                } else if status == 401 {
                    continuation.resume(throwing: ItemError.failed("The PC no longer accepts this iPhone. Pair again."))
                } else if let nsError = error as NSError?, NetworkErrors.isTransient(domain: nsError.domain, code: nsError.code) {
                    continuation.resume(throwing: ItemError.transient("The connection dropped while sending. It will be tried again."))
                } else {
                    continuation.resume(throwing: ItemError.transient("The PC did not take this photo. It will be tried again."))
                }
            }
        }
    }

    private static func mapped(_ error: Error) -> ItemError {
        switch error as? ServerClientError {
        case .server(let status, _, let message)?:
            if status == 507 { return .pcFull }
            if status == 401 { return .failed("The PC no longer accepts this iPhone. Pair again.") }
            return .failed(message)
        case .network(let failure)?:
            return NetworkErrors.isTransient(domain: failure.domain, code: failure.code)
                ? .transient("Could not reach the PC. It will be tried again.")
                : .failed("Could not reach the PC.")
        default:
            return .failed("Something went wrong while sending this photo.")
        }
    }

    private static func mimeType(for name: String) -> String {
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
    private static func freeBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attributes?[.systemFreeSize] as? Int64) ?? Int64.max
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
