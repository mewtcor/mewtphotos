// The run loop with fake steps (Phase 5, plan 05-03): order, retries, stops, failures, cleanup, space rules.
import Testing
import Foundation
@testable import MewtPhotosCore

/// Records every step the runner takes, so tests can check order and cleanup.
actor StepLog {
    private(set) var calls: [String] = []
    private(set) var pauses: [Double] = []
    private(set) var discarded: [String] = []
    private var sendScript: [String: [Result<SendResult, ItemError>]]
    private var stopAfter: Int?
    private var sentCount = 0

    init(sendScript: [String: [Result<SendResult, ItemError>]] = [:], stopAfter: Int? = nil) {
        self.sendScript = sendScript
        self.stopAfter = stopAfter
    }

    func prepare(_ entry: RunEntry) throws -> PreparedItem {
        calls.append("prepare:\(entry.assetId)")
        return PreparedItem(entry: entry, fileURL: URL(fileURLWithPath: "/tmp/\(entry.assetId)"), bytes: 10, sha256: "h-\(entry.assetId)")
    }

    func send(_ item: PreparedItem) throws -> SendResult {
        calls.append("send:\(item.entry.assetId)")
        let id = item.entry.assetId
        guard var script = sendScript[id], !script.isEmpty else { return .verified }
        let next = script.removeFirst()
        sendScript[id] = script
        return try next.get()
    }

    func discard(_ item: PreparedItem) {
        discarded.append(item.entry.assetId)
    }

    func pause(_ seconds: Double) {
        pauses.append(seconds)
    }

    /// True once `stopAfter` items have been sent, so a stop can land between two items.
    func stopRequested() -> Bool {
        if let limit = stopAfter, sentCount >= limit { return true }
        return false
    }

    func countSent() {
        sentCount += 1
    }
}

private func entries(_ ids: [String], known: Set<String> = []) -> RunRecord {
    let items = ids.map { LibraryItem(assetId: $0, fileName: "\($0).HEIC", kind: .photo, onPhone: true, hidden: false, date: nil) }
    return RunRecord.start(BackupPlanner.plan(items, alreadyOnPC: known), at: Date(timeIntervalSince1970: 0))
}

private func runner(_ log: StepLog, retry: RetryPolicy = .standard) -> BackupRunner {
    BackupRunner(
        prepare: { try await log.prepare($0) },
        send: { item in
            await log.countSent()
            return try await log.send(item)
        },
        discard: { item in Task { await log.discard(item) } },
        stopRequested: { await log.stopRequested() },
        pause: { await log.pause($0) },
        retry: retry)
}

private let anyDate = Date(timeIntervalSince1970: 100)

@Suite("Run loop")
struct BackupRunnerTests {
    @Test("every pending photo is exported, sent and verified, and the run finishes")
    func happyPath() async {
        let log = StepLog()
        let result = await runner(log).run(entries(["A", "B"]), now: anyDate) { _ in }
        #expect(result.record.entries.map(\.outcome) == [.verified, .verified])
        #expect(result.record.status == .finished)
        #expect(result.stopMessage == nil)
        #expect(result.record.totals.addsUp)
    }

    @Test("items the PC already holds are not exported or sent")
    func knownItemsSkipped() async {
        let log = StepLog()
        let result = await runner(log).run(entries(["A", "B"], known: ["A"]), now: anyDate) { _ in }
        #expect(result.record.entries[0].outcome == .alreadyOnPC)
        #expect(await log.calls == ["prepare:B", "send:B"])
    }

    @Test("a failed item does not stop the run")
    func failureContinues() async {
        let log = StepLog(sendScript: ["A": [.failure(.failed("the PC refused it"))]])
        let result = await runner(log).run(entries(["A", "B"]), now: anyDate) { _ in }
        #expect(result.record.entries.map(\.outcome) == [.failed("the PC refused it"), .verified])
        #expect(result.record.status == .finished)
    }

    @Test("a short network problem is retried and then succeeds")
    func transientRetried() async {
        let log = StepLog(sendScript: ["A": [.failure(.transient("timed out")), .success(.verified)]])
        let result = await runner(log).run(entries(["A"]), now: anyDate) { _ in }
        #expect(result.record.entries[0].outcome == .verified)
        #expect(await log.pauses == [2])
    }

    @Test("a network problem that keeps happening gives up with its reason")
    func transientGivesUp() async {
        let script: [Result<SendResult, ItemError>] = Array(repeating: .failure(.transient("lost the connection")), count: 4)
        let log = StepLog(sendScript: ["A": script])
        let result = await runner(log).run(entries(["A", "B"]), now: anyDate) { _ in }
        #expect(result.record.entries.map(\.outcome) == [.failed("lost the connection"), .verified])
        #expect(await log.pauses == [2, 5, 15])
    }

    @Test("the PC being full stops the run with one message, keeping what is done")
    func pcFullStops() async {
        let log = StepLog(sendScript: ["B": [.failure(.pcFull)]])
        let result = await runner(log).run(entries(["A", "B", "C"]), now: anyDate) { _ in }
        #expect(result.record.entries.map(\.outcome) == [.verified, .pending, .pending])
        #expect(result.record.status == .stopped)
        #expect(result.stopMessage == BackupRunner.pcFullMessage)
    }

    @Test("the phone running short of space stops the run")
    func phoneFullStops() async {
        let log = StepLog()
        let failing = BackupRunner(
            prepare: { entry in
                if entry.assetId == "B" { throw ItemError.phoneFull }
                return try await log.prepare(entry)
            },
            send: { try await log.send($0) },
            discard: { _ in },
            stopRequested: { false },
            pause: { _ in })
        let result = await failing.run(entries(["A", "B", "C"]), now: anyDate) { _ in }
        #expect(result.record.entries.map(\.outcome) == [.verified, .pending, .pending])
        #expect(result.stopMessage == BackupRunner.phoneFullMessage)
    }

    @Test("a stop between items keeps the rest pending, and a later run continues from there")
    func stopThenResume() async {
        let log = StepLog(stopAfter: 1)
        let first = await runner(log).run(entries(["A", "B", "C"]), now: anyDate) { _ in }
        #expect(first.record.status == .stopped)
        #expect(first.record.entries.map(\.outcome) == [.verified, .pending, .pending])

        let later = StepLog()
        let second = await runner(later).run(RunRecord.open(existing: first.record, plan: [], at: anyDate), now: anyDate) { _ in }
        #expect(second.record.entries.map(\.outcome) == [.verified, .verified, .verified])
        #expect(await later.calls == ["prepare:B", "send:B", "prepare:C", "send:C"])
    }

    @Test("every exported copy is discarded, including when its send fails")
    func cleanupAlways() async {
        let log = StepLog(sendScript: ["A": [.failure(.failed("nope"))]])
        _ = await runner(log).run(entries(["A", "B"]), now: anyDate) { _ in }
        // Discard runs in a detached task; give it a moment before reading the log.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(Set(await log.discarded) == ["A", "B"])
    }

    @Test("the record is saved after each item")
    func savesEachItem() async {
        let saves = SaveCounter()
        let log = StepLog()
        _ = await runner(log).run(entries(["A", "B"]), now: anyDate) { _ in saves.bump() }
        #expect(saves.count >= 3)
    }

    @Test("stopping during a transient retry aborts cleanly and keeps the item pending")
    func stopDuringTransientRetry() async {
        let log = StepLog(
            sendScript: ["A": [.failure(.transient("stalled")), .success(.verified)]],
            stopAfter: 1
        )
        let result = await runner(log).run(entries(["A", "B"]), now: anyDate) { _ in }
        #expect(result.record.status == .stopped)
        #expect(result.record.entries.map(\.outcome) == [.pending, .pending])
        #expect(await log.pauses.isEmpty)
    }

    @Test("cancellation after a stop request keeps the interrupted item pending")
    func cancelAfterStopKeepsPending() async {
        let log = StepLog(stopAfter: 1)
        let cancelling = BackupRunner(
            prepare: { try await log.prepare($0) },
            send: { _ in
                await log.countSent()
                throw CancellationError()
            },
            discard: { item in Task { await log.discard(item) } },
            stopRequested: { await log.stopRequested() },
            pause: { await log.pause($0) })
        let result = await cancelling.run(entries(["A", "B"]), now: anyDate) { _ in }
        #expect(result.record.status == .stopped)
        #expect(result.record.entries.map(\.outcome) == [.pending, .pending])
    }

    @Test("pipelined runner uploads small files concurrently and discards every prepared copy")
    func pipelinedConcurrentUploads() async {
        let tracker = PipelineTracker()
        let runner = BackupRunner(
            prepare: { entry in
                PreparedItem(entry: entry, fileURL: URL(fileURLWithPath: "/tmp/\(entry.assetId)"), bytes: 1_000, sha256: "h-\(entry.assetId)")
            },
            send: { _ in
                await tracker.beginSend()
                try? await Task.sleep(nanoseconds: 40_000_000)
                await tracker.endSend()
                return .verified
            },
            discard: { item in Task { await tracker.markDiscarded(item.entry.assetId) } },
            stopRequested: { false },
            pause: { _ in },
            maxConcurrency: 3
        )
        let ids = ["A", "B", "C", "D", "E", "F"]
        let result = await runner.run(entries(ids), now: anyDate) { _ in }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(result.record.status == .finished)
        #expect(result.record.entries.map(\.outcome) == Array(repeating: .verified, count: ids.count))
        #expect(await tracker.peak >= 2)
        #expect(await tracker.discarded == Set(ids))
    }

    @Test("pipelined runner halts cleanly on pcFull and discards queued temp files")
    func pipelinedPcFullStopsAndCleansUp() async {
        let state = PipelineTracker()
        let runner = BackupRunner(
            prepare: { entry in
                await state.markPrepared(entry.assetId)
                return PreparedItem(entry: entry, fileURL: URL(fileURLWithPath: "/tmp/\(entry.assetId)"), bytes: 1_000, sha256: "h")
            },
            send: { item in
                if item.entry.assetId == "A" { throw ItemError.pcFull }
                try? await Task.sleep(nanoseconds: 30_000_000)
                return .verified
            },
            discard: { item in Task { await state.markDiscarded(item.entry.assetId) } },
            stopRequested: { false },
            pause: { _ in },
            maxConcurrency: 3
        )
        let result = await runner.run(entries(["A", "B", "C", "D", "E"]), now: anyDate) { _ in }
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(result.record.status == .stopped)
        #expect(result.stopMessage == BackupRunner.pcFullMessage)
        #expect(await state.discarded == await state.prepared)
    }
}

private actor PipelineTracker {
    var active = 0
    var peak = 0
    var prepared: Set<String> = []
    var discarded: Set<String> = []

    func beginSend() {
        active += 1
        if active > peak { peak = active }
    }

    func endSend() {
        active -= 1
    }

    func markPrepared(_ id: String) {
        prepared.insert(id)
    }

    func markDiscarded(_ id: String) {
        discarded.insert(id)
    }
}

/// Counts saves from the runner's save closure (which is called on the runner's own task).
final class SaveCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()

    func bump() {
        lock.lock()
        n += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

@Suite("Retries, network and space rules")
struct RetryAndSpaceTests {
    @Test("retries wait the listed times, then give up")
    func delays() {
        #expect(RetryPolicy.standard.delay(afterAttempt: 1) == 2)
        #expect(RetryPolicy.standard.delay(afterAttempt: 2) == 5)
        #expect(RetryPolicy.standard.delay(afterAttempt: 3) == 15)
        #expect(RetryPolicy.standard.delay(afterAttempt: 4) == nil)
    }

    @Test("only the short network problems are retried")
    func transient() {
        #expect(NetworkErrors.isTransient(domain: "NSURLErrorDomain", code: -1001))
        #expect(NetworkErrors.isTransient(domain: "NSURLErrorDomain", code: -1005))
        #expect(!NetworkErrors.isTransient(domain: "NSURLErrorDomain", code: -1200))
        #expect(!NetworkErrors.isTransient(domain: "Other", code: -1001))
    }

    @Test("the phone keeps its reserve back")
    func reserve() {
        #expect(PhoneSpace.hasRoom(free: 5_000_000_000, needed: 1_000_000_000))
        #expect(!PhoneSpace.hasRoom(free: 1_500_000_000, needed: 1_000_000_000))
    }
}

@Suite("Photos with several parts")
struct PhotoPartsCombineTests {
    @Test("an item is backed up only when every part is verified or already held")
    func everyPart() {
        #expect(PhotoParts.combine([.verified, .verified]) == .verified)
        #expect(PhotoParts.combine([.alreadyOnPC, .verified]) == .verified)
        #expect(PhotoParts.combine([.alreadyOnPC, .alreadyOnPC]) == .alreadyOnPC)
        #expect(PhotoParts.combine([.verified]) == .verified)
    }
}
