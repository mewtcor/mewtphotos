// The first screen: the PC address and pairing code, and whether this phone is paired yet.
import SwiftUI
import PhotoSyncCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Text(statusLine)
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
                    if let errorText = model.errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("PhotoSync")
        }
    }

    private var statusLine: String {
        switch model.state {
        case .unpaired:
            return "Not paired yet"
        case .paired(let info):
            return "Paired with \(info.serverName)"
        case .needsRepair:
            return "Pairing needs to be repeated"
        }
    }
}
