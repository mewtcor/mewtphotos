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

        let items = BackupModel.libraryItems()
        let flags: [Bool]
        do {
            flags = try await connection.client.knownAssets(key: connection.key, assetIds: items.map(\.assetId))
        } catch {
            stopMessage = "Could not check with the PC. Make sure it is reachable, then try again."
            return
        }
        let known = Set(zip(items, flags).filter { $0.1 }.map { $0.0.assetId })
        let plan = BackupPlanner.plan(items, alreadyOnPC: known)
        let opened = RunRecord.open(existing: store.load(), plan: plan, at: Date())
        record = opened
        let store = self.store

        let runner = BackupRunner(
            prepare: { entry in try await BackupModel.prepare(entry, work: await self.workFolder()) },
            send: { item in try await BackupModel.send(item, connection: connection, work: await self.workFolder()) },
            discard: { item in try? FileManager.default.removeItem(at: item.fileURL) },
            stopRequested: { await self.stopFlag() },
            pause: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        let result = await runner.run(opened, now: Date()) { saved in
            try? store.save(saved)
            Task { @MainActor in self.record = saved }
        }
        record = result.record
        stopMessage = result.stopMessage
    }

    private func stopFlag() -> Bool { stopRequested }

    private func workFolder() -> URL { work }

    /// Every item in the library, newest first, with what the planner needs. Hidden items and every burst frame
    /// are included; items outside the library fetch are not.
    static func libraryItems() -> [LibraryItem] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var items: [LibraryItem] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let name = resources.first { $0.type == .photo || $0.type == .fullSizePhoto }?.originalFilename
                ?? resources.first?.originalFilename ?? "item"
            let kind: ItemKind = asset.mediaType == .video ? .video
                : (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
            items.append(LibraryItem(assetId: asset.localIdentifier, fileName: name, kind: kind,
                                     onPhone: true, hidden: asset.isHidden, date: asset.creationDate))
        }
        return items
    }

    /// Exports one original to the work folder. Checks the phone's free space first; an original that cannot be
    /// read without iCloud is reported as not supported, never as backed up.
    static func prepare(_ entry: RunEntry, work: URL) async throws -> PreparedItem {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entry.assetId], options: nil).firstObject else {
            throw ItemError.unavailable("It is no longer in the library.")
        }
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) else {
            throw ItemError.unavailable(BackupPlanner.unsupportedReason)
        }
        let expected = (resource.value(forKey: "fileSize") as? Int64) ?? 0
        guard PhoneSpace.hasRoom(free: freeBytes(), needed: expected) else { throw ItemError.phoneFull }

        let url = work.appendingPathComponent(UUID().uuidString + ".part")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        } catch {
            try? FileManager.default.removeItem(at: url)
            // With network access off, an original that exists only in iCloud cannot be read.
            throw ItemError.unavailable(BackupPlanner.unsupportedReason)
        }
        do {
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let hash = try sha256(of: url)
            return PreparedItem(entry: entry, fileURL: url, bytes: bytes, sha256: hash, hidden: asset.isHidden)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ItemError.failed("Could not read the copy on this iPhone.")
        }
    }

    /// Opens the upload on the PC, sends the bytes in the background, and finishes it. Only `verified` or
    /// `duplicate` from the PC counts as backed up.
    static func send(_ item: PreparedItem, connection: PairedConnection, work: URL) async throws -> SendResult {
        let name = item.entry.fileName
        let begun: BegunUpload
        do {
            begun = try await connection.client.beginUpload(
                key: connection.key, filename: name, mimeType: mimeType(for: name), size: item.bytes,
                sha256: item.sha256, assetId: item.entry.assetId, hidden: item.hidden,
                lastModified: item.entry.date.map { Int64($0.timeIntervalSince1970 * 1000) })
        } catch {
            throw mapped(error)
        }
        if begun.alreadyStored { return .alreadyOnPC }

        if begun.offset < item.bytes {
            let source = begun.offset == 0 ? item.fileURL : try BackgroundUploader.tail(of: item.fileURL, from: begun.offset)
            defer {
                if source != item.fileURL { try? FileManager.default.removeItem(at: source) }
            }
            var request = URLRequest(url: connection.base.appendingPathComponent("api/v1/uploads/\(begun.uploadId)"))
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(connection.key.revealForAuthorization())", forHTTPHeaderField: "Authorization")
            request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(begun.offset), forHTTPHeaderField: "Upload-Offset")
            try await transfer(request, from: source)
        }

        do {
            let finished = try await connection.client.finishUpload(key: connection.key, uploadId: begun.uploadId, sha256: item.sha256)
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

    var body: some View {
        Form {
            Section {
                Text(BackupPlanner.editsNotice)
                    .font(.footnote)
                if model.running {
                    Text("Backing up. Keep this screen open until it finishes.")
                    Button("Stop", role: .destructive) { model.stop() }
                } else {
                    Button("Back up now") {
                        Task { await model.start(pairing: pairing) }
                    }
                }
                if let stopMessage = model.stopMessage {
                    Text(stopMessage).foregroundStyle(.red)
                }
            }
            if let record = model.record {
                Section("Last run") {
                    Text(Self.totalsText(record.totals))
                    Text(record.status == .finished ? "Finished." : "Not finished. Back up now continues it.")
                        .font(.footnote)
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
                                Text(Self.reason(entry.outcome))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Back up photos")
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app pauses the run after the item in progress; the record keeps the rest.
            if phase != .active { model.stop() }
        }
    }

    private static func totalsText(_ totals: RunTotals) -> String {
        "Considered \(totals.considered): already on the PC \(totals.alreadyOnPC), verified \(totals.verified), "
            + "failed \(totals.failed), unavailable \(totals.unavailable)."
    }

    private static func reason(_ outcome: ItemOutcome) -> String {
        switch outcome {
        case .failed(let reason), .unavailable(let reason): return reason
        default: return ""
        }
    }
}
