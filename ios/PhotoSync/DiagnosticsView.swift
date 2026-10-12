// Diagnostics: lists every stored part of one picked library item. Read-only: parts are written to a
// temporary file only to measure them, then deleted. iCloud-only parts are not downloaded.
import SwiftUI
import Photos
import PhotosUI
import PhotoSyncCore

@MainActor
@Observable
final class DiagnosticsModel {
    var selection: PhotosPickerItem? {
        didSet { Task { await load() } }
    }
    private(set) var parts: [PartRecord] = []
    private(set) var statusText = "Pick an item to see its stored parts."

    func load() async {
        guard let identifier = selection?.itemIdentifier else {
            statusText = "PhotoSync could not identify that item. Pick it again."
            return
        }
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized || access == .limited else {
            statusText = "Photo access is off. Turn it on in Settings, then try again."
            return
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            statusText = "That item is not in the library any more."
            return
        }
        var records: [PartRecord] = []
        for resource in PHAssetResource.assetResources(for: asset) {
            records.append(await measure(resource))
        }
        parts = records
        statusText = ItemParts.summary(records)
    }

    /// Writes the part to a temporary file to learn its size. Network access is off, so an iCloud-only
    /// part fails here and is reported as unknown rather than downloaded.
    private func measure(_ resource: PHAssetResource) async -> PartRecord {
        let kind = String(describing: resource.type)
        let format = resource.uniformTypeIdentifier
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            return PartRecord(kind: kind, filename: resource.originalFilename, format: format, bytes: size)
        } catch {
            return PartRecord(kind: kind, filename: resource.originalFilename, format: format, bytes: nil)
        }
    }
}

struct DiagnosticsView: View {
    @State private var model = DiagnosticsModel()

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
        }
        .navigationTitle("Diagnostics")
    }
}
