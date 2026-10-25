// The first screen: pair with the PC (by QR code or typed address and code), manage the paired PC, the library
// check, diagnostics, the version, and the log export.
import SwiftUI
import UIKit
import MewtPhotosCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Screen {
                hero
                if case .paired(let info) = model.state {
                    pairedSection(info)
                } else {
                    pairSection
                }
                Panel("Library") {
                    NavigationLink {
                        LibraryView(pairing: model)
                    } label: {
                        NavRow(title: "Photo access and what is not on the PC", systemName: "photo.stack")
                    }
                    if let backup = model.backup {
                        RowDivider()
                        NavigationLink {
                            BackupView(pairing: model, model: backup)
                        } label: {
                            NavRow(title: "Back up photos", systemName: "arrow.up.circle.fill", tint: Theme.cyan)
                        }
                    }
                }
                Panel("Tools") {
                    NavigationLink {
                        DiagnosticsView(pairing: model)
                    } label: {
                        NavRow(title: "Stored parts of a photo or video", systemName: "stethoscope", tint: Theme.warn)
                    }
                    if let logURL = model.logURL {
                        RowDivider()
                        ShareLink(item: logURL) {
                            NavRow(title: "Export log", systemName: "square.and.arrow.up", tint: Theme.good)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("The log is also in Files under On My iPhone, then MewtPhotos.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                about
            }
            .navigationTitle("Mewt Photos")
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

    private var isPaired: Bool {
        if case .paired = model.state { return true }
        return false
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Image(systemName: isPaired ? "checkmark.icloud.fill" : "icloud.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.statusText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                StatusPill(text: isPaired ? "Paired" : "Not paired", tint: isPaired ? Theme.good : Theme.warn)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border))
        .accessibilityElement(children: .combine)
    }

    private var about: some View {
        VStack(spacing: 4) {
            Text("Version \(model.versionText) (build \(model.buildText))")
            Text("Git \(model.gitSHAText)")
        }
        .font(.footnote)
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity)
    }

    private var pairSection: some View {
        Panel("Pair with your PC") {
            if PairScanner.isAvailable {
                Button {
                    scanning = true
                } label: {
                    Label("Scan the QR code on the PC", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.primary)
                .disabled(model.isBusy)
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("PC address")
                TextField("http://192.168.1.10:8787", text: $model.addressText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fieldStyle()
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Pairing code")
                TextField("Code shown on the PC", text: $model.codeText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .fieldStyle()
            }
            Button("Pair") {
                Task { await model.pair() }
            }
            .buttonStyle(.secondary)
            .disabled(model.isBusy || model.addressText.isEmpty || model.codeText.isEmpty)
            Text("If iOS asks for Local Network access, tap Allow, then press Pair again.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
            errorRows
        }
    }

    private func pairedSection(_ info: PairedInfo) -> some View {
        Panel("Paired PC") {
            HStack(spacing: 14) {
                IconBadge(systemName: "desktopcomputer", tint: Theme.cyan, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.serverName)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text(info.serverURL)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.muted)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("PC address")
                TextField("PC address", text: $model.addressText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fieldStyle()
            }
            Button("Save address") {
                Task { await model.changeAddress(model.addressText) }
            }
            .buttonStyle(.secondary)
            .disabled(model.isBusy || model.addressText.isEmpty)
            Button("Forget this PC", role: .destructive) {
                Task { await model.forget() }
            }
            .buttonStyle(.danger)
            .disabled(model.isBusy)
            if let noticeText = model.noticeText {
                Callout(text: noticeText, systemName: "checkmark.circle.fill", tint: Theme.good)
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
            Callout(text: errorText)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.secondary)
        }
    }
}
