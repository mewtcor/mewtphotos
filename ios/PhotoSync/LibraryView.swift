// The library check: what photo access allows, and how many items the PC does not have yet. Nothing is sent
// to the PC except asset identifiers, and nothing is written to the library. This file and DiagnosticsView.swift
// are the only ones allowed to import Photos (see ci.yml).
import SwiftUI
import UIKit
import Photos
import PhotoSyncCore

@MainActor
@Observable
final class LibraryModel {
    private(set) var access: LibraryAccess = .notDetermined
    private(set) var countText: String?
    private(set) var counting = false

    /// Reads the permission again and, with full access, counts what the PC does not have yet. Runs at the
    /// start of each check and when the app becomes active, so a change made in Settings is noticed.
    func refresh(connection: PairedConnection?) async {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard access.canRun else {
            countText = nil
            return
        }
        guard let connection else {
            countText = "Pair with your PC to see what is not on it yet."
            return
        }
        counting = true
        defer { counting = false }
        // ponytail: the identifiers are read on the main thread; a very large library may stall for a moment.
        let ids = Self.libraryIdentifiers()
        do {
            let known = try await connection.client.knownAssets(key: connection.key, assetIds: ids)
            countText = "\(known.filter { !$0 }.count) of \(ids.count) items are not on the PC yet."
        } catch {
            countText = "Could not check with the PC. Make sure it is reachable, then count again."
        }
    }

    func requestAccess() async {
        access = Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func map(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// The whole library, newest first. Hidden items and every burst frame are included. Shared-album items
    /// that are not in the library, and Recently Deleted items, are not in this fetch, so they are left out.
    static func libraryIdentifiers() -> [String] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var ids: [String] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }
}

struct LibraryView: View {
    let pairing: AppModel
    @State private var model = LibraryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("Photo access") {
                Text(model.access.message)
                if model.access == .notDetermined {
                    Button("Allow Access") {
                        Task {
                            await model.requestAccess()
                            await refresh()
                        }
                    }
                } else if !model.access.canRun {
                    Button("Open Settings") { openSettings() }
                }
            }
            Section("Not on the PC yet") {
                if let countText = model.countText {
                    Text(countText)
                }
                if model.counting {
                    ProgressView()
                }
                Button("Count again") {
                    Task { await refresh() }
                }
                .disabled(!model.access.canRun || model.counting)
            }
        }
        .navigationTitle("Library")
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        await model.refresh(connection: await pairing.connection())
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
