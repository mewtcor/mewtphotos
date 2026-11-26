// Obsidian Glass Bento 3-tab shell (Backup, Library, Server) with floating glass dock.
// Pure SwiftUI/UIKit; must never import Photos or PhotosUI (enforced by ci.yml).
import SwiftUI
import UIKit

// MARK: - Root Redesigned Shell

public struct MewtPhotosRedesignView<DataSource: MewtPhotosUIDataSource, ScannerContent: View, DiagnosticsContent: View>: View {
    @ObservedObject private var dataSource: DataSource
    @AppStorage("mewt.ui.accent") private var accentRaw: String = MewtAccent.cyan.rawValue
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: MewtTab = .backup
    @State private var showingAlerts: Bool = false
    @State private var showingQRScanner: Bool = false
    @State private var showingDiagnostics: Bool = false
    @State private var hasUnreadAlerts: Bool = true
    @State private var expandedItemID: String?

    private let scannerBuilder: (@escaping (String) -> Void) -> ScannerContent
    private let diagnosticsBuilder: () -> DiagnosticsContent

    private var accent: MewtAccent {
        MewtAccent(rawValue: accentRaw) ?? .cyan
    }

    public init(
        dataSource: DataSource,
        @ViewBuilder scanner: @escaping (@escaping (String) -> Void) -> ScannerContent,
        @ViewBuilder diagnostics: @escaping () -> DiagnosticsContent
    ) {
        self.dataSource = dataSource
        self.scannerBuilder = scanner
        self.diagnosticsBuilder = diagnostics
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ObsidianBackground(accent: accent)

            ScrollView(showsIndicators: false) {
                Group {
                    switch selectedTab {
                    case .backup:
                        BackupBentoTab(
                            dataSource: dataSource,
                            accent: accent,
                            hasUnreadAlerts: $hasUnreadAlerts,
                            expandedItemID: $expandedItemID,
                            onOpenAlerts: {
                                hasUnreadAlerts = false
                                showingAlerts = true
                            },
                            onOpenQR: { showingQRScanner = true },
                            onSelectTab: { tab in
                                withAnimation(ObsidianPalette.smoothCurve) {
                                    selectedTab = tab
                                }
                            }
                        )
                    case .library:
                        LibraryBentoTab(
                            dataSource: dataSource,
                            accent: accent,
                            expandedItemID: $expandedItemID
                        )
                    case .server:
                        ServerBentoTab(
                            dataSource: dataSource,
                            accentRaw: $accentRaw,
                            accent: accent,
                            onOpenQR: { showingQRScanner = true },
                            onOpenDiagnostics: { showingDiagnostics = true }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 108)
            }
            .scrollDismissesKeyboard(.interactively)

            FloatingGlassDock(selectedTab: $selectedTab, accent: accent)
        }
        .preferredColorScheme(.dark)
        .onChange(of: dataSource.alerts) { _, alerts in
            if !alerts.isEmpty { hasUnreadAlerts = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dataSource.onBecameActive()
            } else if phase == .background {
                // Only .background pauses an active backup; .inactive (Control Center) does not.
                dataSource.onEnteredBackground()
            }
        }
        .sheet(isPresented: $showingAlerts) {
            AlertsSheetView(alerts: dataSource.alerts, accent: accent)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingQRScanner) {
            NavigationStack {
                scannerBuilder { scannedPayload in
                    dataSource.pair(fromQRPayload: scannedPayload)
                    showingQRScanner = false
                }
                .navigationTitle("Pair Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingQRScanner = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                diagnosticsBuilder()
                    .navigationTitle("Stored Parts")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingDiagnostics = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Tab 1: Backup Bento

private struct BackupBentoTab<DataSource: MewtPhotosUIDataSource>: View {
    @ObservedObject var dataSource: DataSource
    let accent: MewtAccent
    @Binding var hasUnreadAlerts: Bool
    @Binding var expandedItemID: String?
    let onOpenAlerts: () -> Void
    let onOpenQR: () -> Void
    let onSelectTab: (MewtTab) -> Void

    private var remainingCount: Int {
        guard dataSource.isPaired, dataSource.photoAccessState.isFull, dataSource.coverageKnown else {
            return dataSource.totalLibraryCount
        }
        return max(0, dataSource.totalLibraryCount - dataSource.backedUpCount)
    }

    private var coverageProgress: Double {
        guard dataSource.isPaired, dataSource.photoAccessState.isFull, dataSource.coverageKnown,
              dataSource.totalLibraryCount > 0 else { return 0 }
        return Double(dataSource.backedUpCount) / Double(dataSource.totalLibraryCount)
    }

    private var coverageSubtitle: String {
        if !dataSource.isPaired {
            return "Pair with your server to check coverage"
        }
        if !dataSource.photoAccessState.isFull {
            return "Full photo access is required to measure coverage"
        }
        if !dataSource.coverageKnown {
            return dataSource.isRecounting ? "Checking coverage with \(dataSource.serverName)…" : "Tap Recount to check what is on \(dataSource.serverName)"
        }
        if remainingCount == 0 {
            return "Coverage verified: every library item is on \(dataSource.serverName)"
        }
        return "\(remainingCount) original\(remainingCount == 1 ? "" : "s") not on \(dataSource.serverName)"
    }

    var body: some View {
        VStack(spacing: 14) {
            // 1. Top Header
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Wi-Fi Archive")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(ObsidianPalette.textSecondary)
                    Text("Mewt Photos")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(ObsidianPalette.textPrimary)
                }

                Spacer()

                Button { onSelectTab(.server) } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(dataSource.isPaired ? ObsidianPalette.ok : ObsidianPalette.warn)
                            .frame(width: 6, height: 6)
                        Text(dataSource.isPaired ? dataSource.serverName : "Unpaired")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .frame(minHeight: 34)
                    .foregroundStyle(dataSource.isPaired ? ObsidianPalette.ok : ObsidianPalette.warn)
                    .background(
                        Capsule()
                            .fill(dataSource.isPaired ? ObsidianPalette.okSoft : ObsidianPalette.warnSoft)
                    )
                    .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: onOpenAlerts) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ObsidianPalette.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(ObsidianPalette.surface))
                            .overlay(Circle().stroke(ObsidianPalette.border, lineWidth: 1))

                        if hasUnreadAlerts && !dataSource.alerts.isEmpty {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 7, height: 7)
                                .shadow(color: accent.color, radius: 5)
                                .offset(x: -6, y: 6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Alerts")
            }

            // Photo Access Guard Banner (when not full access)
            if !dataSource.photoAccessState.isFull {
                PhotoAccessBanner(
                    state: dataSource.photoAccessState,
                    message: dataSource.photoAccessMessage,
                    accent: accent,
                    onAllowAccess: { dataSource.requestPhotoAccess() }
                )
            }

            // Stop / Error Safety Banner (phone low storage, server full, connection dropped, etc.)
            if let warning = dataSource.stopWarning {
                AlertBannerCard(title: "Backup notice", detail: warning, isError: true)
            }

            // 2. Hero Metric Bento Card
            GlassCard(activeGlow: accent.glow) {
                VStack(spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LIBRARY COVERAGE")
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(ObsidianPalette.textMuted)

                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(dataSource.isPaired && dataSource.coverageKnown && dataSource.photoAccessState.isFull
                                     ? "\(dataSource.backedUpCount)"
                                     : "—")
                                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(ObsidianPalette.textPrimary)
                                Text("/ \(dataSource.totalLibraryCount)")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(ObsidianPalette.textMuted)
                            }

                            Text(coverageSubtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(ObsidianPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 4)

                        RadialCoverageRing(
                            progress: coverageProgress,
                            accent: accent,
                            known: dataSource.isPaired && dataSource.coverageKnown && dataSource.photoAccessState.isFull
                        )
                    }

                    if dataSource.isBackingUp {
                        VStack(spacing: 8) {
                            HStack {
                                Text(dataSource.activeFileName.isEmpty ? "Preparing next original…" : dataSource.activeFileName)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ObsidianPalette.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f MB/s", dataSource.transferSpeedMBps))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(accent.color)
                            }

                            TransferSparkline(samples: dataSource.speedSamples, accent: accent)

                            HStack {
                                Text(dataSource.activeItemProgressText ?? "Resumable stream · SHA-256 disk verify")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(ObsidianPalette.textMuted)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Int((dataSource.activeFileProgress * 100).rounded()))%")
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(ObsidianPalette.textSecondary)
                            }

                            Text("Keep this screen open. Your iPhone stays awake while the backup runs.")
                                .font(.system(size: 11))
                                .foregroundStyle(ObsidianPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(ObsidianPalette.border, lineWidth: 1)
                        )
                    } else {
                        HStack(spacing: 10) {
                            MiniBentoTile(
                                label: "Server Archive",
                                value: dataSource.serverArchiveSizeText,
                                subtitle: dataSource.serverVerifiedCountText,
                                subtitleColor: ObsidianPalette.ok
                            )
                            MiniBentoTile(
                                label: "Server Disk Free",
                                value: dataSource.serverFreeSpaceText,
                                subtitle: "\(dataSource.hiddenCount) hidden items",
                                subtitleColor: ObsidianPalette.textMuted
                            )
                        }
                    }

                    if let onServerOnly = dataSource.onServerOnlyCount, onServerOnly > 0 {
                        Text("On \(dataSource.serverName) but no longer on this iPhone: \(onServerOnly) (kept on purpose).")
                            .font(.system(size: 11))
                            .foregroundStyle(ObsidianPalette.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // 3. Quick Actions Row
            HStack(spacing: 8) {
                QuickActionPill(
                    title: dataSource.isBackingUp ? "Stop" : "Back up",
                    systemImage: dataSource.isBackingUp ? "stop.fill" : "arrow.up.circle.fill",
                    accent: accent,
                    isPrimary: true,
                    isDisabled: !dataSource.isPaired || !dataSource.photoAccessState.isFull
                ) {
                    if dataSource.isBackingUp {
                        dataSource.stopBackup()
                    } else {
                        dataSource.startBackup()
                    }
                }

                QuickActionPill(
                    title: dataSource.isRecounting ? "Checking" : "Recount",
                    systemImage: "arrow.clockwise",
                    accent: accent,
                    isDisabled: dataSource.isRecounting || dataSource.isBackingUp
                ) {
                    dataSource.recountLibrary()
                }

                QuickActionPill(
                    title: "Pair QR",
                    systemImage: "qrcode.viewfinder",
                    accent: accent,
                    isDisabled: !dataSource.isQRScannerAvailable
                ) {
                    onOpenQR()
                }

                QuickActionPill(
                    title: dataSource.isServerVerifying ? "Verifying" : "Verify",
                    systemImage: "checkmark.shield",
                    accent: accent,
                    isDisabled: !dataSource.isPaired || dataSource.isServerVerifying
                ) {
                    dataSource.triggerServerVerify()
                }
            }

            // Retry Failed Banner (when failures exist and not actively running)
            if dataSource.failedCount > 0 && !dataSource.isBackingUp {
                Button {
                    dataSource.retryFailed()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ObsidianPalette.err)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Retry \(dataSource.failedCount) failed item\(dataSource.failedCount == 1 ? "" : "s")")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(ObsidianPalette.textPrimary)
                            Text("Unavailable items stay untouched; failed transfers resume cleanly.")
                                .font(.system(size: 11))
                                .foregroundStyle(ObsidianPalette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ObsidianPalette.err)
                    }
                    .padding(14)
                    .frame(minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ObsidianPalette.errSoft))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ObsidianPalette.err.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(ScalePressButtonStyle())
            }

            // Last Run Totals Bento Card
            if let summary = dataSource.lastRunSummary {
                GlassCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("LAST RUN SUMMARY")
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(ObsidianPalette.textMuted)
                            Spacer()
                            Text(summary.finished ? "Finished · \(summary.considered) checked" : "Unfinished · Back up continues it")
                                .font(.system(size: 11))
                                .foregroundStyle(summary.finished ? ObsidianPalette.textMuted : ObsidianPalette.warn)
                        }
                        HStack(spacing: 8) {
                            RunCountPill(label: "On server", value: summary.alreadyOnServer, color: ObsidianPalette.textPrimary)
                            RunCountPill(label: "Verified", value: summary.verified, color: ObsidianPalette.ok)
                            RunCountPill(label: "Failed", value: summary.failed, color: summary.failed > 0 ? ObsidianPalette.err : ObsidianPalette.textMuted)
                            RunCountPill(label: "Unavail.", value: summary.unavailable, color: summary.unavailable > 0 ? ObsidianPalette.warn : ObsidianPalette.textMuted)
                        }
                    }
                }
            }

            // 4. Interactive Recent & Pending Feed
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Recent & Pending Files")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ObsidianPalette.textPrimary)
                        Spacer()
                        Button { onSelectTab(.library) } label: {
                            Text("View all \(dataSource.totalLibraryCount)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(accent.color)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    Divider().overlay(ObsidianPalette.border)

                    if dataSource.mediaItems.isEmpty {
                        Text(dataSource.photoAccessState.isFull
                             ? "Tap Recount to inspect items in your photo library."
                             : "Grant full photo access to list items.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(ObsidianPalette.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                    } else {
                        let previewItems = Array(dataSource.mediaItems.prefix(5))
                        ForEach(Array(previewItems.enumerated()), id: \.element.id) { idx, item in
                            ExpandableMediaRow(
                                item: item,
                                accent: accent,
                                isExpanded: expandedItemID == item.id,
                                canRetry: item.status == .failed && !dataSource.isBackingUp,
                                onTap: {
                                    let opening = expandedItemID != item.id
                                    if opening { dataSource.inspectItemIfNeeded(id: item.id) }
                                    withAnimation(ObsidianPalette.smoothCurve) {
                                        expandedItemID = opening ? item.id : nil
                                    }
                                },
                                onRetry: { dataSource.retryItem(id: item.id) }
                            )

                            if idx < previewItems.count - 1 {
                                Divider().overlay(ObsidianPalette.border)
                            }
                        }
                    }
                }
            }

            Text("\(dataSource.editsNoticeText) Nothing is ever deleted from your iPhone.")
                .font(.system(size: 11))
                .foregroundStyle(ObsidianPalette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
}

private struct RunCountPill: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(ObsidianPalette.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(ObsidianPalette.border, lineWidth: 1))
    }
}

private struct MiniBentoTile: View {
    let label: String
    let value: String
    let subtitle: String
    let subtitleColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(ObsidianPalette.textMuted)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(ObsidianPalette.textPrimary)
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ObsidianPalette.border, lineWidth: 1)
        )
    }
}

// MARK: - Expandable Media Feed Row

private struct ExpandableMediaRow: View {
    let item: MewtMediaItem
    let accent: MewtAccent
    let isExpanded: Bool
    let canRetry: Bool
    let onTap: () -> Void
    let onRetry: () -> Void

    private var statusForeground: Color {
        switch item.status {
        case .verified: return ObsidianPalette.ok
        case .failed: return ObsidianPalette.err
        case .pending: return ObsidianPalette.warn
        case .unavailable: return ObsidianPalette.textSecondary
        }
    }

    private var statusBackground: Color {
        switch item.status {
        case .verified: return ObsidianPalette.okSoft
        case .failed: return ObsidianPalette.errSoft
        case .pending: return ObsidianPalette.warnSoft
        case .unavailable: return Color.white.opacity(0.08)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Text(item.fileExtension)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ObsidianPalette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.filename)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(ObsidianPalette.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(item.sizeText)
                                .font(.system(size: 11, design: .monospaced))
                            if !item.dateText.isEmpty {
                                Text("·")
                                Text(item.dateText)
                                    .font(.system(size: 11))
                            }
                        }
                        .foregroundStyle(ObsidianPalette.textMuted)
                    }

                    Spacer(minLength: 6)

                    Text(item.status.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(statusForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusBackground))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ObsidianPalette.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PHAssetResources")
                            .font(.system(size: 10.5))
                            .foregroundStyle(ObsidianPalette.textMuted)
                        Spacer()
                        Text("\(item.resourceParts.count) part\(item.resourceParts.count == 1 ? "" : "s")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(ObsidianPalette.textSecondary)
                    }

                    ForEach(item.resourceParts, id: \.self) { part in
                        Text(part)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ObsidianPalette.textPrimary)
                    }

                    Divider().overlay(ObsidianPalette.border)

                    HStack(alignment: .top) {
                        Text(item.destinationSummary)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(ObsidianPalette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(item.shaSummary)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(accent.color)
                    }

                    if canRetry {
                        Button(action: onRetry) {
                            Label("Retry this item", systemImage: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(accent.foreground)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.color))
                        }
                        .buttonStyle(ScalePressButtonStyle())
                        .padding(.top, 4)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(ObsidianPalette.border, lineWidth: 1)
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Tab 2: Library & Coverage

private struct LibraryBentoTab<DataSource: MewtPhotosUIDataSource>: View {
    @ObservedObject var dataSource: DataSource
    let accent: MewtAccent
    @Binding var expandedItemID: String?

    @State private var searchText: String = ""
    @State private var filter: LibraryFilter = .pending

    enum LibraryFilter: String, CaseIterable {
        case pending = "Not on server"
        case verified = "Verified"
        case all = "All"
    }

    private var filteredItems: [MewtMediaItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return dataSource.mediaItems.filter { item in
            let matchesFilter: Bool = {
                switch filter {
                case .pending: return item.status != .verified
                case .verified: return item.status == .verified
                case .all: return true
                }
            }()
            let matchesQuery = query.isEmpty || item.filename.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesQuery
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dataSource.photoAccessState.isFull ? "Full library access granted" : "Photo access required")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(dataSource.photoAccessState.isFull ? ObsidianPalette.ok : ObsidianPalette.warn)
                    Text("Library")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(ObsidianPalette.textPrimary)
                }
                Spacer()
                Button { dataSource.recountLibrary() } label: {
                    Label(dataSource.isRecounting ? "Checking" : "Recount", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ObsidianPalette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 38)
                        .background(Capsule().fill(ObsidianPalette.surface))
                        .overlay(Capsule().stroke(ObsidianPalette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(dataSource.isRecounting || dataSource.isBackingUp)
            }

            if !dataSource.photoAccessState.isFull {
                PhotoAccessBanner(
                    state: dataSource.photoAccessState,
                    message: dataSource.photoAccessMessage,
                    accent: accent,
                    onAllowAccess: { dataSource.requestPhotoAccess() }
                )
            }

            // Search Bar (pinned at top so it never overlaps filenames)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(ObsidianPalette.textMuted)
                TextField("File name, e.g. IMG_4303", text: $searchText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(ObsidianPalette.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(ObsidianPalette.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ObsidianPalette.border, lineWidth: 1)
            )

            // Filter Pills
            HStack(spacing: 4) {
                ForEach(LibraryFilter.allCases, id: \.self) { option in
                    let isSelected = filter == option
                    Button {
                        withAnimation(ObsidianPalette.smoothCurve) { filter = option }
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? ObsidianPalette.textPrimary : ObsidianPalette.textMuted)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.10) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ObsidianPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ObsidianPalette.border, lineWidth: 1)
            )

            // Lazy list for 4,500+ library items
            GlassCard(padding: 0) {
                if filteredItems.isEmpty {
                    Text(searchText.isEmpty ? "No items in this filter." : "No item named \"\(searchText)\" is in this list.")
                        .font(.system(size: 13))
                        .foregroundStyle(ObsidianPalette.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredItems) { item in
                            ExpandableMediaRow(
                                item: item,
                                accent: accent,
                                isExpanded: expandedItemID == item.id,
                                canRetry: item.status == .failed && !dataSource.isBackingUp,
                                onTap: {
                                    let opening = expandedItemID != item.id
                                    if opening { dataSource.inspectItemIfNeeded(id: item.id) }
                                    withAnimation(ObsidianPalette.smoothCurve) {
                                        expandedItemID = opening ? item.id : nil
                                    }
                                },
                                onRetry: { dataSource.retryItem(id: item.id) }
                            )
                            Divider().overlay(ObsidianPalette.border)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tab 3: Server, 24/7 Mac mini & Diagnostics

private struct ServerBentoTab<DataSource: MewtPhotosUIDataSource>: View {
    @ObservedObject var dataSource: DataSource
    @Binding var accentRaw: String
    let accent: MewtAccent
    let onOpenQR: () -> Void
    let onOpenDiagnostics: () -> Void

    @State private var editingAddress: Bool = false
    @State private var draftAddress: String = ""
    @State private var manualAddress: String = ""
    @State private var manualCode: String = ""

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Destination & Tools")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ObsidianPalette.textSecondary)
                Text("Server")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ObsidianPalette.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Paired Server Card
            GlassCard {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(accent.color)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(accent.softFill)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(dataSource.isPaired ? dataSource.serverName : "No server paired")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(ObsidianPalette.textPrimary)
                            Text(dataSource.isPaired ? dataSource.serverAddress : dataSource.connectionSummary)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(ObsidianPalette.textSecondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Text(dataSource.isPaired ? "Paired" : "Offline")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(dataSource.isPaired ? ObsidianPalette.ok : ObsidianPalette.warn)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(dataSource.isPaired ? ObsidianPalette.okSoft : ObsidianPalette.warnSoft))
                    }

                    if !dataSource.isPaired {
                        if dataSource.isQRScannerAvailable {
                            QuickActionPill(
                                title: "Scan Server QR Code",
                                systemImage: "qrcode.viewfinder",
                                accent: accent,
                                isPrimary: true,
                                isDisabled: dataSource.isPairingBusy
                            ) {
                                onOpenQR()
                            }
                        }

                        Divider().overlay(ObsidianPalette.border)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("OR PAIR MANUALLY")
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(ObsidianPalette.textMuted)

                            TextField("http://192.168.4.20:8788", text: $manualAddress)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(ObsidianPalette.textPrimary)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ObsidianPalette.border, lineWidth: 1))

                            TextField("Pairing code shown on dashboard", text: $manualCode)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(ObsidianPalette.textPrimary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ObsidianPalette.border, lineWidth: 1))

                            Button {
                                dataSource.pairManually(address: manualAddress, code: manualCode)
                                manualCode = ""
                            } label: {
                                Text(dataSource.isPairingBusy ? "Pairing…" : "Pair")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(ObsidianPalette.textPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(ObsidianPalette.surfaceHover))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ObsidianPalette.borderStrong, lineWidth: 1))
                            }
                            .buttonStyle(ScalePressButtonStyle())
                            .disabled(dataSource.isPairingBusy || manualAddress.isEmpty || manualCode.isEmpty)

                            Text("If iOS asks for Local Network access, tap Allow, then press Pair again.")
                                .font(.system(size: 11))
                                .foregroundStyle(ObsidianPalette.textMuted)
                        }
                    } else if editingAddress {
                        VStack(spacing: 8) {
                            TextField("http://192.168.4.20:8788", text: $draftAddress)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(ObsidianPalette.textPrimary)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.color, lineWidth: 1))

                            HStack(spacing: 8) {
                                Button("Cancel") { editingAddress = false }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(ObsidianPalette.textSecondary)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(ObsidianPalette.surface))

                                Button("Save") {
                                    dataSource.saveServerAddress(draftAddress)
                                    editingAddress = false
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(accent.foreground)
                                .background(RoundedRectangle(cornerRadius: 10).fill(accent.color))
                                .disabled(dataSource.isPairingBusy || draftAddress.isEmpty)
                            }
                        }
                    } else {
                        Text(dataSource.connectionSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(ObsidianPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 8) {
                            Button {
                                draftAddress = dataSource.serverAddress
                                editingAddress = true
                            } label: {
                                Text("Edit address")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(ObsidianPalette.textPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(ObsidianPalette.surface))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ObsidianPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Button {
                                dataSource.forgetServer()
                            } label: {
                                Text("Forget server")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(ObsidianPalette.err)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(ObsidianPalette.errSoft))
                            }
                            .buttonStyle(.plain)
                            .disabled(dataSource.isPairingBusy)
                        }
                    }

                    if let notice = dataSource.pairingNoticeText {
                        AlertBannerCard(title: "Saved", detail: notice, isError: false)
                    }

                    if let error = dataSource.pairingErrorText {
                        VStack(spacing: 8) {
                            AlertBannerCard(title: "Connection issue", detail: error, isError: true)
                            Button {
                                openAppSettings()
                            } label: {
                                Text("Open Settings")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(ObsidianPalette.textPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(ObsidianPalette.surface))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ObsidianPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 24/7 Auto-Backup (BGProcessingTask while charging on home Wi-Fi)
            GlassCard {
                let canSchedule = dataSource.isPaired && dataSource.photoAccessState.isFull
                let isArmed = canSchedule && dataSource.autoBackup247Enabled
                Toggle(isOn: $dataSource.autoBackup247Enabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("24/7 Auto-Backup")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ObsidianPalette.textPrimary)
                            Text(isArmed ? "Armed" : "BGTask")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(isArmed ? ObsidianPalette.ok : accent.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isArmed ? ObsidianPalette.okSoft : accent.softFill)
                                )
                        }
                        Text(dataSource.autoBackupStatusText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(ObsidianPalette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent.color)
                .disabled(!canSchedule)
                .opacity(canSchedule ? 1.0 : 0.6)
            }

            // Accent Picker
            GlassCard {
                HStack {
                    Text("Accent")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(ObsidianPalette.textPrimary)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(MewtAccent.allCases) { option in
                            Button {
                                withAnimation(ObsidianPalette.smoothCurve) {
                                    accentRaw = option.rawValue
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(option.color).frame(width: 8, height: 8)
                                    Text(option.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 36)
                                .foregroundStyle(accentRaw == option.rawValue ? ObsidianPalette.textPrimary : ObsidianPalette.textMuted)
                                .background(
                                    Capsule()
                                        .fill(accentRaw == option.rawValue ? Color.white.opacity(0.10) : .clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Tools & Diagnostics
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    Button(action: onOpenDiagnostics) {
                        HStack {
                            Label("Stored parts of a photo or video", systemImage: "square.stack.3d.up")
                                .font(.system(size: 13.5))
                                .foregroundStyle(ObsidianPalette.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ObsidianPalette.textMuted)
                        }
                        .padding(14)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().overlay(ObsidianPalette.border)

                    if let url = dataSource.logExportURL {
                        ShareLink(item: url) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label("Export diagnostics log", systemImage: "square.and.arrow.up")
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(ObsidianPalette.textPrimary)
                                    Text("Files › On My iPhone › MewtPhotos")
                                        .font(.system(size: 11))
                                        .foregroundStyle(ObsidianPalette.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ObsidianPalette.textMuted)
                            }
                            .padding(14)
                            .frame(minHeight: 50)
                        }
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Export diagnostics log")
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(ObsidianPalette.textMuted)
                                Text("Log file appears after first run")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ObsidianPalette.textMuted)
                            }
                            Spacer()
                        }
                        .padding(14)
                    }
                }
            }

            HStack {
                Text(dataSource.appVersionText)
                Spacer()
                Text("Plain HTTP · Local LAN")
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(ObsidianPalette.textMuted)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Shared Banners & Alerts Sheet

private struct PhotoAccessBanner: View {
    let state: MewtPhotoAccessState
    let message: String
    let accent: MewtAccent
    let onAllowAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(ObsidianPalette.warn)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state == .notDetermined ? "Photo access needed" : "Full photo access required")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ObsidianPalette.warn)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(ObsidianPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if state == .notDetermined {
                Button(action: onAllowAccess) {
                    Text("Allow Access")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent.foreground)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.color))
                }
                .buttonStyle(ScalePressButtonStyle())
            } else if state != .restricted {
                Button {
                    openAppSettings()
                } label: {
                    Text("Open Settings")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ObsidianPalette.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ObsidianPalette.surfaceHover))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ObsidianPalette.borderStrong, lineWidth: 1))
                }
                .buttonStyle(ScalePressButtonStyle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ObsidianPalette.warnSoft))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ObsidianPalette.warn.opacity(0.28), lineWidth: 1))
    }
}

private struct AlertBannerCard: View {
    let title: String
    let detail: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(isError ? ObsidianPalette.err : ObsidianPalette.ok)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isError ? ObsidianPalette.err : ObsidianPalette.ok)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ObsidianPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isError ? ObsidianPalette.errSoft : ObsidianPalette.okSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke((isError ? ObsidianPalette.err : ObsidianPalette.ok).opacity(0.28), lineWidth: 1)
        )
    }
}

private func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}

private struct AlertsSheetView: View {
    let alerts: [MewtAlertItem]
    let accent: MewtAccent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ObsidianPalette.sheetBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        if alerts.isEmpty {
                            Text("No active alerts.")
                                .font(.system(size: 13))
                                .foregroundStyle(ObsidianPalette.textMuted)
                                .padding(.top, 32)
                        } else {
                            ForEach(alerts) { alert in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(alert.title)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(alert.isError ? ObsidianPalette.err : ObsidianPalette.textPrimary)
                                    Text(alert.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(ObsidianPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(alert.isError ? ObsidianPalette.errSoft : ObsidianPalette.surface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(alert.isError ? ObsidianPalette.err.opacity(0.25) : ObsidianPalette.border, lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Alerts & Safety")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(accent.color)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Xcode Preview

#Preview("Obsidian Glass Bento") {
    MewtPhotosRedesignView(
        dataSource: PreviewMewtDataSource(),
        scanner: { onScan in
            VStack(spacing: 16) {
                Text("Attach existing PairScanner here")
                    .foregroundStyle(ObsidianPalette.textSecondary)
                Button("Simulate Pair") { onScan("http://192.168.4.48:8787/#pair=TEST1234") }
            }
        },
        diagnostics: {
            Text("Attach existing DiagnosticsView here")
                .foregroundStyle(ObsidianPalette.textSecondary)
        }
    )
}
