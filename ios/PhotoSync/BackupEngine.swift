// The backup run on the phone (Phase 5, plan 05-03): exports one original at a time, checks free space, sends
// it, and keeps the run record up to date. Read-only with respect to the library: nothing is changed or deleted.
// Photos is imported here, in the same allowed set as DiagnosticsView and LibraryView (see ci.yml).
import SwiftUI
import UIKit
import Photos
import CryptoKit
import PhotoSyncCore

@MainActor
@Observable
final class BackupModel {
    private(set) var record: RunRecord?
    private(set) var stopMessage: String?
    /// What Photos returns for the run's fetch, and how many of those are hidden. Shown to diagnose hidden photos.
    private(set) var libraryCounts: (total: Int, hidden: Int)?
    /// How many of this iPhone's photos the PC holds; nil until it has been asked.
    private(set) var pcCount: Int?
    private(set) var pcCountFailed = false
    private(set) var running = false
    private var stopRequested = false
    private let store: RunStore
    private let work: URL

    init(supportDirectory: URL) {
        store = RunStore(directory: supportDirectory)
        work = supportDirectory.appendingPathComponent("backup-work", isDirectory: true)
        record = store.load()
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Anything left from an earlier run is removed; the run record decides what is sent again.
        if let files = try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Asks the run to stop after the item in progress. The record keeps what is done.
    func stop() {
        stopRequested = true
    }

    /// Starts a run, or continues the unfinished one. Items the PC already has are skipped by identity.
    func start(pairing: AppModel) async {
        guard !running else { return }
        guard let connection = await pairing.connection() else {
            stopMessage = "Pair with your PC first."
            return
        }
        running = true
        stopRequested = false
        stopMessage = nil
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let (items, paired) = BackupModel.libraryItems()
        let flags: [Bool]
        do {
            flags = try await connection.client.knownAssets(key: connection.key, assetIds: items.map(\.assetId))
        } catch {
            stopMessage = "Could not check with the PC. Make sure it is reachable, then try again."
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
            prepare: { entry in try await BackupModel.prepare(entry, work: await self.workFolder()) },
            send: { item in try await BackupModel.send(item, connection: connection, work: await self.workFolder()) },
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
    static func libraryItems() -> (items: [PhotoSyncCore.LibraryItem], paired: Set<String>) {
        var items: [PhotoSyncCore.LibraryItem] = []
        var paired = Set<String>()
        for asset in libraryAssets() {
            let resources = PHAssetResource.assetResources(for: asset)
            let name = resources.first { $0.type == .photo || $0.type == .fullSizePhoto }?.originalFilename
                ?? resources.first?.originalFilename ?? "item"
            let kind: ItemKind = asset.mediaType == .video ? .video
                : (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
            if resources.contains(where: { $0.type == .alternatePhoto || $0.type == .pairedVideo }) { paired.insert(asset.localIdentifier) }
            items.append(PhotoSyncCore.LibraryItem(assetId: asset.localIdentifier, fileName: name, kind: kind,
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
    static func send(_ item: PreparedItem, connection: PairedConnection, work: URL) async throws -> SendResult {
        let pairId: String? = item.companions.isEmpty ? nil : item.entry.assetId
        var results: [SendResult] = []
        for companion in item.companions {
            results.append(try await sendPart(companion, item: item, assetId: nil, pairId: pairId,
                                              pairName: item.entry.fileName, connection: connection))
        }
        let main = PreparedPart(fileName: item.entry.fileName, fileURL: item.fileURL, bytes: item.bytes, sha256: item.sha256)
        results.append(try await sendPart(main, item: item, assetId: item.entry.assetId, pairId: pairId,
                                          pairName: item.companions.first?.fileName, connection: connection))
        return PhotoParts.combine(results)
    }

    /// Opens the upload for one file, sends the bytes in the background, and finishes it.
    private static func sendPart(_ part: PreparedPart, item: PreparedItem, assetId: String?, pairId: String?,
                                 pairName: String?, connection: PairedConnection) async throws -> SendResult {
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
        if begun.alreadyStored { return .alreadyOnPC }

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
            try await transfer(request, from: source)
        }

        do {
            let finished = try await connection.client.finishUpload(key: connection.key, uploadId: begun.uploadId, sha256: part.sha256)
            switch finished.status {
            case "verified": return .verified
            case "duplicate": return .alreadyOnPC
            default: throw ItemError.failed("The PC did not confirm this photo.")
            }
        } catch let error as ItemError {
            throw error
        } catch {
            throw ItemError.transient("The PC has not confirmed this photo yet. It will be tried again.")
        }
    }

    /// The background transfer, as an async call. A full PC disk is reported as `pcFull` so the run stops.
    private static func transfer(_ request: URLRequest, from file: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            BackgroundUploader.shared.send(request, fromFile: file) { status, error in
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
        Form {
            Section {
                Text(BackupPlanner.editsNotice)
                    .font(.footnote)
                if model.running {
                    Text("Keep this screen open. The phone stays awake while the backup runs.")
                    if let current = Self.currentText(model.record) {
                        Text(current)
                    }
                    Button("Stop", role: .destructive) { model.stop() }
                } else {
                    Button("Back up now") {
                        Task { await model.start(pairing: pairing) }
                    }
                    if let failed = model.record?.totals.failed, failed > 0 {
                        Button("Retry \(failed) failed") {
                            Task { await model.retryFailed(pairing: pairing) }
                        }
                    }
                }
                if let stopMessage = model.stopMessage {
                    Text(stopMessage).foregroundStyle(.red)
                }
                if let counts = model.libraryCounts {
                    Text("The app's list of photos has \(counts.total) items, \(counts.hidden) of them hidden.")
                        .font(.footnote)
                }
            }
            if let record = model.record {
                Section("Last run") {
                    Text(Self.totalsText(record.totals))
                    Text(record.status == .finished ? "Finished." : "Not finished. Back up now continues it.")
                        .font(.footnote)
                    if let pcCount = model.pcCount {
                        Text("The PC holds \(pcCount) of this iPhone's photos.")
                        // The PC should hold at least everything this run counted as backed up.
                        if pcCount < record.totals.verified + record.totals.alreadyOnPC {
                            Text("The PC has fewer of these photos than this run counted. Check the PC's backup folder, then run again.")
                                .foregroundStyle(.red)
                        }
                    }
                    if model.pcCountFailed {
                        Text("Could not check the PC's count. Make sure the PC is on and reachable, then reopen this screen.")
                            .foregroundStyle(.red)
                    }
                }
                if !search.isEmpty {
                    // Searches every item in this run, not only the failed ones, so a missing photo can be told apart.
                    let matches = record.entries.filter { $0.fileName.localizedCaseInsensitiveContains(search) }
                    Section("Search this run") {
                        if matches.isEmpty {
                            Text("No item named \"\(search)\" is in this run. The phone's list of photos did not include it.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(matches.prefix(50).enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.fileName)
                                if let date = entry.date {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Text(Self.statusText(entry.outcome))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
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
                    Section("Not backed up") {
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.fileName)
                                if let date = entry.date {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Text(Self.reason(entry.outcome))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if Self.isFailed(entry.outcome) {
                                    Button("Retry") {
                                        Task { await model.retry(assetId: entry.assetId, pairing: pairing) }
                                    }
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
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app pauses the run after the item in progress; the record keeps the rest.
            if phase != .active { model.stop() }
        }
    }

    private static func totalsText(_ totals: RunTotals) -> String {
        "Considered \(totals.considered): already on the PC \(totals.alreadyOnPC), verified \(totals.verified), "
            + "failed \(totals.failed), unavailable \(totals.unavailable)."
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
