// Bridges @Observable AppModel + BackupModel to MewtPhotosUIDataSource (ObservableObject)
// using Observation tracking so SwiftUI stays reactive without polling or importing Photos (see ci.yml).
import Combine
import Foundation
import Observation
import SwiftUI
import MewtPhotosCore

@MainActor
final class AppModelUIAdapter: MewtPhotosUIDataSource {
    let objectWillChange = ObservableObjectPublisher()
    private let model: AppModel
    private var cachedMediaItems: [MewtMediaItem] = []
    private var cachedAlerts: [MewtAlertItem] = []
    private var formattedDateCache: [String: String] = [:]
    private var lastListRebuildAt: ContinuousClock.Instant?
    private var deferredRebuildTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        rebuildDerivedState()
        observeStructuralChanges()
        observeTelemetryChanges()
    }

    // MARK: - Pairing & Server

    var serverName: String {
        model.serverStatus?.serverName ?? model.pairedInfo?.serverName ?? "Unpaired"
    }

    var serverAddress: String {
        model.pairedInfo?.serverURL ?? ""
    }

    var isPaired: Bool {
        model.pairedInfo != nil
    }

    var isPairingBusy: Bool {
        model.isBusy
    }

    var isQRScannerAvailable: Bool {
        PairScanner.isAvailable
    }

    var connectionSummary: String {
        model.statusText
    }

    var pairingErrorText: String? {
        model.errorText
    }

    var pairingNoticeText: String? {
        model.noticeText
    }

    // MARK: - Library & Coverage

    var photoAccessState: MewtPhotoAccessState {
        guard let access = model.backup?.photoAccess else { return .notDetermined }
        switch access {
        case .full: return .full
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        }
    }

    var photoAccessMessage: String {
        model.backup?.photoAccess.message ?? LibraryAccess.notDetermined.message
    }

    var coverageKnown: Bool {
        model.backup?.coverage != nil
    }

    var isRecounting: Bool {
        model.backup?.recounting ?? false
    }

    var totalLibraryCount: Int {
        if let counts = model.backup?.libraryCounts { return counts.total }
        if let record = model.backup?.record { return record.totals.considered }
        return 0
    }

    var backedUpCount: Int {
        if let coverage = model.backup?.coverage { return coverage.held }
        if let pcCount = model.backup?.pcCount { return pcCount }
        return 0
    }

    var hiddenCount: Int {
        model.backup?.libraryCounts?.hidden ?? 0
    }

    var onServerOnlyCount: Int? {
        model.backup?.coverage?.onPCOnly
    }

    // MARK: - Server Archive Metrics

    var serverArchiveSizeText: String {
        guard let bytes = model.serverStatus?.storedBytes else { return "—" }
        return ItemParts.formatBytes(bytes)
    }

    var serverVerifiedCountText: String {
        if model.verifying || model.serverStatus?.verifyRunning == true {
            return "Verifying SHA-256…"
        }
        if let files = model.serverStatus?.storedFiles {
            return "\(files.formatted()) files verified"
        }
        if let pcCount = model.backup?.pcCount {
            return "\(pcCount.formatted()) from this iPhone"
        }
        return "SHA-256 verified"
    }

    var serverFreeSpaceText: String {
        guard let free = model.serverStatus?.freeBytes else { return "—" }
        return ItemParts.formatBytes(free)
    }

    var isServerVerifying: Bool {
        model.verifying || (model.serverStatus?.verifyRunning ?? false)
    }

    // MARK: - Live Transfer Telemetry

    var isBackingUp: Bool {
        model.backup?.running ?? false
    }

    var activeFileName: String {
        model.backup?.activeFileName ?? ""
    }

    var activeItemProgressText: String? {
        guard let record = model.backup?.record, record.nextPending != nil else { return nil }
        let done = record.entries.filter { $0.outcome != .pending }.count
        let phase = model.backup?.activePhaseText ?? "Resumable stream"
        return "Item \(done + 1) of \(record.entries.count) · \(phase)"
    }

    var activeFileProgress: Double {
        model.backup?.activeFileProgress ?? 0
    }

    var transferSpeedMBps: Double {
        model.backup?.transferSpeedMBps ?? 0
    }

    var speedSamples: [Double] {
        model.backup?.speedSamples ?? [0, 0, 0, 0, 0, 0, 0, 0]
    }

    // MARK: - Run Summary & Safety

    var lastRunSummary: MewtRunSummary? {
        guard let record = model.backup?.record else { return nil }
        let totals = record.totals
        return MewtRunSummary(
            considered: totals.considered,
            alreadyOnServer: totals.alreadyOnPC,
            verified: totals.verified,
            failed: totals.failed,
            unavailable: totals.unavailable,
            finished: record.status == .finished
        )
    }

    var failedCount: Int {
        model.backup?.record?.totals.failed ?? 0
    }

    var stopWarning: String? {
        model.backup?.stopMessage
    }

    var editsNoticeText: String {
        BackupPlanner.editsNotice
    }

    var autoBackup247Enabled: Bool {
        get { model.autoBackup247Enabled }
        set { model.setAutoBackup247(newValue) }
    }

    var autoBackupStatusText: String {
        if !isPaired {
            return "Pair with your server to enable overnight Wi-Fi sync."
        }
        if !photoAccessState.isFull {
            return "Full photo access is required for automatic overnight sync."
        }
        if !model.autoBackup247Enabled {
            return "Off · Turn on to sync automatically over home Wi-Fi while charging."
        }
        if let last = model.lastAutoBackupSummary {
            return "Armed · Last run: \(last)"
        }
        return "Armed · iOS runs automatically while charging on home Wi-Fi."
    }

    var mediaItems: [MewtMediaItem] {
        cachedMediaItems
    }

    var alerts: [MewtAlertItem] {
        cachedAlerts
    }

    var logExportURL: URL? {
        model.logURL
    }

    var appVersionText: String {
        "Version \(model.versionText) (build \(model.buildText)) · Git \(model.gitSHAText)"
    }

    // MARK: - Actions

    func startBackup() {
        guard let backup = model.backup else { return }
        Task { await backup.start(pairing: model) }
    }

    func stopBackup() {
        model.backup?.stop()
    }

    func retryFailed() {
        guard let backup = model.backup else { return }
        Task { await backup.retryFailed(pairing: model) }
    }

    func retryItem(id: String) {
        guard let backup = model.backup else { return }
        Task { await backup.retry(assetId: id, pairing: model) }
    }

    func recountLibrary() {
        guard let backup = model.backup else { return }
        Task { await backup.recount(pairing: model) }
    }

    func requestPhotoAccess() {
        guard let backup = model.backup else { return }
        Task {
            await backup.requestPhotoAccess()
            await backup.recount(pairing: model)
        }
    }

    func triggerServerVerify() {
        Task { await model.triggerServerVerify() }
    }

    func inspectItemIfNeeded(id: String) {
        model.backup?.inspectResourceParts(assetId: id)
    }

    func saveServerAddress(_ address: String) {
        Task {
            await model.changeAddress(address)
            if case .paired = model.state {
                await model.refreshServerStatus()
                await model.backup?.recount(pairing: model)
            }
        }
    }

    func forgetServer() {
        Task { await model.forget() }
    }

    func pair(fromQRPayload payload: String) {
        Task { await model.pair(fromQRPayload: payload) }
    }

    func pairManually(address: String, code: String) {
        Task { await model.pairManually(address: address, code: code) }
    }

    func onBecameActive() {
        model.backup?.refreshPhotoAccess()
        Task {
            await model.retryPendingFinish()
            if case .paired = model.state {
                await model.refreshServerStatus()
                if model.backup?.running != true && model.backup?.coverage == nil {
                    await model.backup?.recount(pairing: model)
                }
            }
        }
    }

    func onEnteredBackground() {
        if !(model.backup?.isBackgroundRun ?? false) {
            model.backup?.stop()
        }
        if model.autoBackup247Enabled && isPaired && photoAccessState.isFull {
            BackgroundSyncScheduler.shared.scheduleNext(reason: "entered_background")
        }
    }

    // MARK: - Observation Bridge & Derived Models

    /// Watches structural state that affects the library list or alerts, rebuilding derived arrays
    /// only when those actually change (never on high-frequency upload progress ticks).
    private func observeStructuralChanges() {
        withObservationTracking {
            _ = model.state
            _ = model.isBusy
            _ = model.errorText
            _ = model.noticeText
            _ = model.connectionText
            _ = model.serverStatus
            _ = model.verifying
            _ = model.autoBackup247Enabled
            _ = model.lastAutoBackupSummary
            if let backup = model.backup {
                _ = backup.photoAccess
                _ = backup.libraryCounts
                _ = backup.librarySnapshot
                _ = backup.pcCount
                _ = backup.pcCountFailed
                _ = backup.coverage
                _ = backup.coverageFailed
                _ = backup.record
                _ = backup.stopMessage
                _ = backup.running
                _ = backup.recounting
                _ = backup.inspectedParts
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleDerivedStateRebuild()
                self.objectWillChange.send()
                self.observeStructuralChanges()
            }
        }
    }

    /// Rebuilds the 4,500+ item list immediately when idle, or throttled to ~1 Hz while a backup is
    /// actively finishing multiple photos per second so the Main Thread stays smooth and cool.
    private func scheduleDerivedStateRebuild() {
        let isRunning = model.backup?.running ?? false
        guard isRunning else {
            deferredRebuildTask?.cancel()
            deferredRebuildTask = nil
            rebuildDerivedState()
            lastListRebuildAt = .now
            return
        }
        let now = ContinuousClock.now
        if let last = lastListRebuildAt {
            let parts = last.duration(to: now).components
            let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            if elapsed < 1.0 {
                if deferredRebuildTask == nil {
                    deferredRebuildTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(1000))
                        guard let self, !Task.isCancelled else { return }
                        self.deferredRebuildTask = nil
                        self.rebuildDerivedState()
                        self.lastListRebuildAt = .now
                        self.objectWillChange.send()
                    }
                }
                return
            }
        }
        deferredRebuildTask?.cancel()
        deferredRebuildTask = nil
        rebuildDerivedState()
        lastListRebuildAt = now
    }

    /// Watches high-frequency live transfer telemetry without rebuilding or sorting the 4,500+ item list.
    private func observeTelemetryChanges() {
        withObservationTracking {
            if let backup = model.backup {
                _ = backup.activeFileName
                _ = backup.activePhaseText
                _ = backup.activeFileProgress
                _ = backup.transferSpeedMBps
                _ = backup.speedSamples
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.observeTelemetryChanges()
            }
        }
    }

    private func cachedDateText(assetId: String, date: Date?) -> String {
        guard let date else { return "" }
        if let cached = formattedDateCache[assetId] { return cached }
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        formattedDateCache[assetId] = formatted
        return formatted
    }

    private func rebuildDerivedState() {
        cachedMediaItems = buildMediaItems()
        cachedAlerts = buildAlerts()
    }

    private func buildMediaItems() -> [MewtMediaItem] {
        guard let backup = model.backup else { return [] }
        let missingIds = Set(backup.coverage?.missing.map(\.assetId) ?? [])
        let hasCoverage = backup.coverage != nil
        var outcomeByAsset: [String: ItemOutcome] = [:]
        if let entries = backup.record?.entries {
            for entry in entries {
                outcomeByAsset[entry.assetId] = entry.outcome
            }
        }

        if !backup.librarySnapshot.isEmpty {
            let mapped = backup.librarySnapshot.map { item -> MewtMediaItem in
                let outcome = outcomeByAsset[item.assetId]
                let (status, destination, sha) = Self.describe(
                    outcome: outcome,
                    hasCoverage: hasCoverage,
                    isMissing: missingIds.contains(item.assetId)
                )
                let ext = ((item.fileName as NSString).pathExtension.uppercased())
                let kindLabel: String = {
                    switch item.kind {
                    case .photo: return item.hidden ? "Photo · Hidden" : "Photo"
                    case .video: return item.hidden ? "Video · Hidden" : "Video"
                    case .livePhoto: return item.hidden ? "Live Photo · Hidden" : "Live Photo"
                    }
                }()
                let dateText = cachedDateText(assetId: item.assetId, date: item.date)
                let parts = backup.inspectedParts[item.assetId] ?? ["\(item.fileName) (\(kindLabel))"]
                return MewtMediaItem(
                    id: item.assetId,
                    filename: item.fileName,
                    fileExtension: ext.isEmpty ? "FILE" : ext,
                    sizeText: kindLabel,
                    dateText: dateText,
                    status: status,
                    resourceParts: parts,
                    destinationSummary: destination,
                    shaSummary: sha
                )
            }
            // Show failed / pending / unavailable items ahead of already-verified ones for quick triage.
            return mapped.sorted { lhs, rhs in
                Self.sortRank(lhs.status) < Self.sortRank(rhs.status)
            }
        }

        // Fallback before first recount: show entries from the saved RunRecord if one exists.
        guard let entries = backup.record?.entries else { return [] }
        return entries.map { entry in
            let (status, destination, sha) = Self.describe(outcome: entry.outcome, hasCoverage: false, isMissing: false)
            let ext = (entry.fileName as NSString).pathExtension.uppercased()
            let dateText = cachedDateText(assetId: entry.assetId, date: entry.date)
            let parts = backup.inspectedParts[entry.assetId] ?? [entry.fileName]
            return MewtMediaItem(
                id: entry.assetId,
                filename: entry.fileName,
                fileExtension: ext.isEmpty ? "FILE" : ext,
                sizeText: "Run entry",
                dateText: dateText,
                status: status,
                resourceParts: parts,
                destinationSummary: destination,
                shaSummary: sha
            )
        }
    }

    private func buildAlerts() -> [MewtAlertItem] {
        var list: [MewtAlertItem] = []

        if let stopMessage = model.backup?.stopMessage {
            list.append(MewtAlertItem(id: "stop", title: "Backup stopped", detail: stopMessage, isError: true))
        }

        if let record = model.backup?.record {
            let totals = record.totals
            if totals.failed > 0 {
                let sample = record.entries.compactMap { entry -> String? in
                    if case .failed = entry.outcome { return entry.fileName }
                    return nil
                }.prefix(4).joined(separator: ", ")
                list.append(MewtAlertItem(
                    id: "failed",
                    title: "\(totals.failed) item\(totals.failed == 1 ? "" : "s") failed in last run",
                    detail: sample.isEmpty ? "Tap Retry failed to resend." : "\(sample). Tap Retry failed to resend.",
                    isError: true
                ))
            }
            if totals.unavailable > 0 {
                list.append(MewtAlertItem(
                    id: "unavailable",
                    title: "\(totals.unavailable) item\(totals.unavailable == 1 ? "" : "s") unavailable",
                    detail: "iCloud-only or unsupported originals are skipped and never counted as backed up.",
                    isError: false
                ))
            }
            if let pcCount = model.backup?.pcCount, pcCount < totals.verified + totals.alreadyOnPC {
                list.append(MewtAlertItem(
                    id: "mismatch",
                    title: "Server count is lower than last run",
                    detail: "The server holds \(pcCount) items from this iPhone, fewer than the \(totals.verified + totals.alreadyOnPC) counted. Check the backup folder and run again.",
                    isError: true
                ))
            }
        }

        if model.backup?.coverageFailed == true {
            list.append(MewtAlertItem(
                id: "coverage_failed",
                title: "Coverage check failed",
                detail: "Make sure the server is on and reachable on Wi-Fi, then tap Recount.",
                isError: true
            ))
        }

        if model.backup?.pcCountFailed == true {
            list.append(MewtAlertItem(
                id: "count_failed",
                title: "Could not read server count",
                detail: "Make sure the server is reachable, then tap Recount.",
                isError: true
            ))
        }

        if let error = model.errorText {
            list.append(MewtAlertItem(id: "pair_error", title: "Server connection", detail: error, isError: true))
        }

        if let backup = model.backup, !backup.photoAccess.canRun {
            list.append(MewtAlertItem(id: "photo_access", title: "Photo library access", detail: backup.photoAccess.message, isError: false))
        }

        return list
    }

    private static func sortRank(_ status: MewtItemStatus) -> Int {
        switch status {
        case .failed: return 0
        case .pending: return 1
        case .unavailable: return 2
        case .verified: return 3
        }
    }

    private static func describe(
        outcome: ItemOutcome?,
        hasCoverage: Bool,
        isMissing: Bool
    ) -> (MewtItemStatus, String, String) {
        // Live server coverage is the source of truth for whether an item is currently held on disk.
        if hasCoverage && !isMissing {
            return (.verified, "Held on server (verified on disk)", "Verified")
        }
        if let outcome {
            switch outcome {
            case .failed(let reason):
                return (.failed, reason, "Not backed up")
            case .unavailable(let reason):
                return (.unavailable, reason, "Skipped")
            case .verified:
                return hasCoverage ? (.pending, "Not currently found on server", "Pending") : (.verified, "Verified in last run", "Verified")
            case .alreadyOnPC:
                return hasCoverage ? (.pending, "Not currently found on server", "Pending") : (.verified, "Already on server", "Verified")
            case .pending:
                return (.pending, "Waiting to transfer", "Pending")
            }
        }
        if hasCoverage && isMissing {
            return (.pending, "Not on server yet", "Pending")
        }
        return (.pending, "Recount or pair to check server status", "Unchecked")
    }
}
