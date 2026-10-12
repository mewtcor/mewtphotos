// The first screen: pair with the PC (by QR code or typed address and code), manage the paired PC, the library
// check, diagnostics, the version, and the log export.
import SwiftUI
import UIKit
import PhotoSyncCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Text(model.statusText)
                }
                if case .paired(let info) = model.state {
                    pairedSection(info)
                } else {
                    pairSection
                }
                Section("Library") {
                    NavigationLink("Photo access and what is not on the PC") {
                        LibraryView(pairing: model)
                    }
                }
                Section("About") {
                    Text("Version \(model.versionText) (build \(model.buildText))")
                    Text("Git \(model.gitSHAText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    NavigationLink("Stored parts of a photo or video") {
                        DiagnosticsView(pairing: model)
                    }
                }
                Section("Log") {
                    if let logURL = model.logURL {
                        ShareLink("Export log", item: logURL)
                    }
                    Text("The same file is in Files under On My iPhone, then PhotoSync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PhotoSync")
            .sheet(isPresented: $scanning) {
                PairScanner { link in
                    scanning = false
                    model.addressText = link
                    model.codeText = ""
                    Task { await model.pair() }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var pairSection: some View {
        Section("Pair with your PC") {
            if PairScanner.isAvailable {
                Button("Scan the QR code on the PC") {
                    scanning = true
                }
                .disabled(model.isBusy)
            }
            TextField("PC address", text: $model.addressText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Pairing code", text: $model.codeText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Pair") {
                Task { await model.pair() }
            }
            .disabled(model.isBusy || model.addressText.isEmpty || model.codeText.isEmpty)
            Text("If iOS asks for Local Network access, tap Allow, then press Pair again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            errorRows
        }
    }

    private func pairedSection(_ info: PairedInfo) -> some View {
        Section("Paired PC") {
            Text(info.serverName)
            Text(info.serverURL)
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("PC address", text: $model.addressText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save address") {
                Task { await model.changeAddress(model.addressText) }
            }
            .disabled(model.isBusy || model.addressText.isEmpty)
            Button("Forget this PC", role: .destructive) {
                Task { await model.forget() }
            }
            .disabled(model.isBusy)
            if let noticeText = model.noticeText {
                Text(noticeText)
                    .foregroundStyle(.green)
            }
            errorRows
        }
        .onAppear {
            if model.addressText.isEmpty { model.addressText = info.serverURL }
        }
    }

    @ViewBuilder
    private var errorRows: some View {
        if let errorText = model.errorText {
            Text(errorText)
                .foregroundStyle(.red)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}
