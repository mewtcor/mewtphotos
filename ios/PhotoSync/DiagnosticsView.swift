// Diagnostics: lists every stored part of one picked library item, and exports the parts for the USB
// comparison. Read-only: nothing is written to the library or deleted. Exports go to Documents, which
// Files and the PC's Apple Devices app can see, and iCloud-only parts are not downloaded.
import SwiftUI
import Photos
import PhotosUI
import CryptoKit
import PhotoSyncCore

@MainActor
@Observable
final class DiagnosticsModel {
    var selection: PhotosPickerItem? {
        didSet { Task { await load() } }
    }
    private(set) var parts: [PartRecord] = []
    private(set) var statusText = "Pick an item to see its stored parts."
    private(set) var exportText: String?
    private var asset: PHAsset?
    private(set) var uploadText: String?
    private(set) var uploading = false

    /// Writes the picked item's video to a temp file, hashes it, and uploads it to the paired PC. The timer
    /// covers the network only: the bytes are read back from disk in 8 MiB chunks.
    func uploadVideo(pairing: AppModel) async {
        guard let asset, !uploading else { return }
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .video || $0.type == .fullSizeVideo }) else {
            uploadText = "Pick an item with a video to test the upload."
            return
        }
        uploading = true
        uploadText = "Uploading. Keep the screen on until this message changes."
        defer { uploading = false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
            let hash = try sha256(of: url)
            switch await pairing.uploadTest(file: url, filename: resource.originalFilename,
                                            mimeType: "video/quicktime", size: size, sha256: hash) {
            case .success(let outcome):
                let speed = outcome.mibPerSecond.map { String(format: "%.2f MiB/s", $0) } ?? "no speed (zero time)"
                uploadText = "Server status: \(outcome.status). \(ItemParts.formatBytes(size)) in "
                    + "\(String(format: "%.1f", outcome.seconds)) s, \(speed), 8 MiB chunks. "
                    + "Verified end to end: \(outcome.endToEndVerified ? "yes" : "no")."
            case .failure(let failure):
                uploadText = "Upload failed. " + failure.message
            }
        } catch {
            uploadText = "Could not read the video from the phone: \(error.localizedDescription)"
        }
    }

    func load() async {
        guard let identifier = selection?.itemIdentifier else {
            statusText = "PhotoSync could not identify that item. Pick it again."
            return
        }
        guard await photoAccess() else {
            statusText = "Photo access is off. Turn it on in Settings, then try again."
            return
        }
        guard let found = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            statusText = "That item is not in the library any more."
            return
        }
        asset = found
        exportText = nil
        var records: [PartRecord] = []
        for resource in PHAssetResource.assetResources(for: found) {
            records.append(await measure(resource))
        }
        parts = records
        statusText = ItemParts.summary(records)
    }

    /// Writes every part of the picked item to Documents/PhotoSyncExport/<item>, hashes each file, and writes
    /// manifest.txt beside them. A part that cannot be read without iCloud is listed as failed, not skipped.
    func export() async {
        guard let asset else { return }
        let folderName = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        guard let folder = documents?.appendingPathComponent("PhotoSyncExport").appendingPathComponent(folderName) else {
            exportText = "PhotoSync could not open Documents."
            return
        }
        // A second export finds the first one's files here, and writeData fails on an existing file. This
        // folder is only ever our own export copy, never the library, so clearing it is safe.
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        var failed: [String] = []
        for resource in PHAssetResource.assetResources(for: asset) {
            let url = folder.appendingPathComponent(resource.originalFilename)
            do {
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = false
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
                hashes[resource.originalFilename] = try sha256(of: url)
            } catch {
                failed.append(resource.originalFilename)
            }
        }
        // Read the manifest back so the screen shows what landed on disk, not what was meant to.
        let manifestURL = folder.appendingPathComponent("manifest.txt")
        var manifestNote: String
        do {
            try ExportManifest.text(hashes).write(to: manifestURL, atomically: true, encoding: .utf8)
            let size = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.size] as? Int64 ?? -1
            manifestNote = " Manifest is \(size) bytes."
        } catch {
            manifestNote = " Manifest write failed: \(error.localizedDescription)."
        }
        let saved = "Exported \(hashes.count) part(s) to Files > On My iPhone > PhotoSync > PhotoSyncExport > \(folderName)."
        exportText = (failed.isEmpty ? saved : saved + " Could not read: " + failed.joined(separator: ", ") + ".") + manifestNote
    }

    private func photoAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Writes the part to a temporary file to learn its size. Network access is off, so an iCloud-only
    /// part fails here and is reported as unknown rather than downloaded.
    private func measure(_ resource: PHAssetResource) async -> PartRecord {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            return PartRecord(kind: Self.kindName(resource.type), filename: resource.originalFilename,
                              format: resource.uniformTypeIdentifier, bytes: size)
        } catch {
            return PartRecord(kind: Self.kindName(resource.type), filename: resource.originalFilename,
                              format: resource.uniformTypeIdentifier, bytes: nil)
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func kindName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .alternatePhoto: return "alternatePhoto"
        case .fullSizePhoto: return "fullSizePhoto"
        case .fullSizeVideo: return "fullSizeVideo"
        case .adjustmentData: return "adjustmentData"
        case .adjustmentBasePhoto: return "adjustmentBasePhoto"
        case .pairedVideo: return "pairedVideo"
        case .fullSizePairedVideo: return "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: return "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: return "adjustmentBaseVideo"
        @unknown default: return "unknown"
        }
    }
}

struct DiagnosticsView: View {
    @State private var model = DiagnosticsModel()
    let pairing: AppModel

    var body: some View {
        Form {
            Section {
                PhotosPicker("Pick an item", selection: $model.selection, matching: nil, photoLibrary: .shared())
            }
            Section("Stored parts") {
                Text(model.statusText)
                ForEach(Array(model.parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(part.filename)
                        Text("\(part.kind) · \(part.format)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(part.bytes.map { ItemParts.formatBytes($0) } ?? "Could not read without downloading from iCloud")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !model.parts.isEmpty {
                Section("Export for the USB check") {
                    Button("Export these parts") {
                        Task { await model.export() }
                    }
                    if let exportText = model.exportText {
                        Text(exportText)
                            .font(.footnote)
                    }
                }
                Section("Upload speed test") {
                    Button("Upload this video to the PC") {
                        Task { await model.uploadVideo(pairing: pairing) }
                    }
                    .disabled(model.uploading)
                    if let uploadText = model.uploadText {
                        Text(uploadText)
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
