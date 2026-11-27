// Schedules and executes opportunistic overnight background backups via iOS BGProcessingTask
// (while plugged into power and on local Wi-Fi). Requires no paid entitlements — only Info.plist keys.
// Pure Foundation/BackgroundTasks; must never import Photos or PhotosUI (enforced by ci.yml).
import BackgroundTasks
import Foundation
import MewtPhotosCore

@MainActor
final class BackgroundSyncScheduler {
    static let shared = BackgroundSyncScheduler()
    static let taskIdentifier = "com.mewtcor.mewtphotos.autobackup"

    private static let enabledKey = "mewt.autobackup.enabled"
    private static let lastRunAtKey = "mewt.autobackup.lastRunAt"
    private static let lastRunSummaryKey = "mewt.autobackup.lastRunSummary"

    private weak var model: AppModel?
    private var registered = false
    private var currentRunExpired = false

    private init() {}

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue {
                scheduleNext(reason: "enabled")
            } else {
                cancelAll(reason: "disabled")
            }
        }
    }

    var lastRunSummaryText: String? {
        guard let summary = UserDefaults.standard.string(forKey: Self.lastRunSummaryKey) else { return nil }
        let epoch = UserDefaults.standard.double(forKey: Self.lastRunAtKey)
        if epoch > 0 {
            let date = Date(timeIntervalSince1970: epoch)
            return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(summary)"
        }
        return summary
    }

    func attach(model: AppModel) {
        self.model = model
    }

    /// Must be called once during `application(_:didFinishLaunchingWithOptions:)`, before launch completes.
    func registerHandler() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await BackgroundSyncScheduler.shared.handle(task: processingTask)
            }
        }
    }

    /// Submits (or replaces) the next BGProcessingTask request when 24/7 Auto-Backup is enabled.
    func scheduleNext(reason: String, earliestDelaySeconds: TimeInterval = 15 * 60) {
        guard isEnabled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestDelaySeconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            log(.info, code: "autobackup_scheduled", "scheduled BGProcessingTask (\(reason))")
        } catch {
            log(.warn, code: "autobackup_schedule_failed", "could not schedule BGProcessingTask (\(reason)): \(error.localizedDescription)")
        }
    }

    func cancelAll(reason: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        log(.info, code: "autobackup_cancelled", "cancelled BGProcessingTask (\(reason))")
    }

    private func handle(task: BGProcessingTask) async {
        // Schedule the next window up front so nightly sync keeps repeating even if iOS expires this run.
        if isEnabled {
            scheduleNext(reason: "reschedule", earliestDelaySeconds: 4 * 60 * 60)
        }

        guard let model = self.model, let backup = model.backup else {
            log(.warn, code: "autobackup_no_model", "background wake had no attached AppModel")
            task.setTaskCompleted(success: false)
            return
        }

        guard isEnabled else {
            task.setTaskCompleted(success: true)
            return
        }

        log(.info, code: "autobackup_start", "BGProcessingTask woke up")

        // Ensure pairing state is restored if iOS launched the app headless in the background.
        await model.ensureRestoredForBackground()
        backup.refreshPhotoAccess()

        guard backup.photoAccess.canRun else {
            recordOutcome("Skipped (full photo access required)")
            log(.warn, code: "autobackup_no_photo_access", "background wake skipped: photo access is \(backup.photoAccess)")
            task.setTaskCompleted(success: true)
            return
        }

        guard let connection = await model.connection() else {
            recordOutcome("Skipped (not paired)")
            log(.warn, code: "autobackup_unpaired", "background wake skipped: not paired")
            task.setTaskCompleted(success: true)
            return
        }

        // Fast reachability check: if away from home Wi-Fi, finish cleanly without wasting background time.
        do {
            _ = try await connection.client.health()
        } catch {
            recordOutcome("Server unreachable (not on home Wi-Fi)")
            log(.info, code: "autobackup_unreachable", "server unreachable on background wake; waiting for next window")
            task.setTaskCompleted(success: true)
            return
        }

        currentRunExpired = false
        task.expirationHandler = {
            Task { @MainActor in
                self.currentRunExpired = true
                backup.stop()
                self.log(.warn, code: "autobackup_expired", "iOS requested background task expiration; stopping cleanly after current item")
            }
        }

        await backup.start(pairing: model, isBackgroundTask: true)

        let expired = currentRunExpired
        if let record = backup.record {
            let t = record.totals
            let suffix = expired ? " (paused by iOS)" : ""
            let summary = "\(t.verified) verified, \(t.failed) failed\(suffix)"
            recordOutcome(summary)
            log(.info, code: "autobackup_finished", "background run ended: \(summary)")
        } else {
            recordOutcome(expired ? "Paused by iOS" : "Up to date")
            log(.info, code: "autobackup_finished", "background run ended with no new record")
        }

        task.setTaskCompleted(success: !expired)
    }

    private func recordOutcome(_ summary: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunAtKey)
        UserDefaults.standard.set(summary, forKey: Self.lastRunSummaryKey)
        model?.refreshAutoBackupState()
    }

    private func log(_ level: LogLevel, code: String, _ message: String) {
        guard let model = self.model else { return }
        Task { await model.logEvent(level, code: code, message) }
    }
}
