// The first screen: the PC address and pairing code, whether this phone is paired, the version,
// and the log export.
import SwiftUI
import PhotoSyncCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Text(model.statusText)
                }
                Section("Pair with your PC") {
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
                    if let errorText = model.errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
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
                        DiagnosticsView()
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
        }
    }
}
