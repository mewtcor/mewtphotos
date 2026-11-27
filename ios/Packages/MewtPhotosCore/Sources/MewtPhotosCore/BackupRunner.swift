// The run loop (Phase 5, plan 05-03): works through the pending items one at a time, saving the record after
// each. The app supplies the steps (export, send, discard, stop check, pause); this file decides the order,
// the retries and the stops. Pure logic, tested on Linux with fake steps.
import Foundation

/// Why one item did not go through. `unavailable` and `failed` are recorded and the run goes on; `transient`
/// is retried; `pcFull` and `phoneFull` stop the whole run with one message.
public enum ItemError: Error, Equatable, Sendable {
    case unavailable(String)
    case failed(String)
    case transient(String)
    case pcFull
    case phoneFull
}

/// What the PC said about a sent item: stored now, or already held.
public enum SendResult: Equatable, Sendable {
    case verified
    case alreadyOnPC
}

/// An original exported to a temporary file, with the facts the PC needs to check it.
public struct PreparedItem: Sendable {
    public let entry: RunEntry
    public let fileURL: URL
    public let bytes: Int64
    public let sha256: String
    /// The item is hidden on the phone; sent so the PC stores it under Hidden.
    public let hidden: Bool
    /// Other original files of the same photo (a RAW's JPEG or HEIC). Sent with the main file; the item counts as
    /// backed up only when every part is.
    public let companions: [PreparedPart]

    public var totalBytes: Int64 {
        bytes + companions.reduce(Int64(0)) { $0 + $1.bytes }
    }

    public init(entry: RunEntry, fileURL: URL, bytes: Int64, sha256: String, hidden: Bool = false,
                companions: [PreparedPart] = []) {
        self.entry = entry
        self.fileURL = fileURL
        self.bytes = bytes
        self.sha256 = sha256
        self.hidden = hidden
        self.companions = companions
    }
}

/// One original file of a photo, exported to a temporary file and hashed.
public struct PreparedPart: Sendable {
    public let fileName: String
    public let fileURL: URL
    public let bytes: Int64
    public let sha256: String

    public init(fileName: String, fileURL: URL, bytes: Int64, sha256: String) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// The rule for a photo with several parts: backed up only when every part is verified or already on the PC.
public enum PhotoParts {
    public static func combine(_ results: [SendResult]) -> SendResult {
        results.allSatisfy { $0 == .alreadyOnPC } ? .alreadyOnPC : .verified
    }
}

/// Retries for short network problems: how long to wait before each new attempt, and when to give up.
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let delaysSeconds: [Double]

    public init(maxAttempts: Int, delaysSeconds: [Double]) {
        self.maxAttempts = maxAttempts
        self.delaysSeconds = delaysSeconds
    }

    public static let standard = RetryPolicy(maxAttempts: 4, delaysSeconds: [2, 5, 15])

    /// Seconds to wait after attempt `attempt` failed, or nil when no attempts are left.
    public func delay(afterAttempt attempt: Int) -> Double? {
        guard attempt < maxAttempts, !delaysSeconds.isEmpty else { return nil }
        return delaysSeconds[min(attempt - 1, delaysSeconds.count - 1)]
    }
}

public enum NetworkErrors {
    /// Timeout, cannot connect, connection lost, not connected: the kind that a retry can fix. Anything else
    /// (a refused request, a bad answer) is not retried.
    public static func isTransient(domain: String, code: Int) -> Bool {
        domain == "NSURLErrorDomain" && [-1001, -1004, -1005, -1009].contains(code)
    }
}

public enum PhoneSpace {
    /// Free space the phone keeps back, so an export can never fill it up.
    public static let reserveBytes: Int64 = 1_000_000_000

    public static func hasRoom(free: Int64, needed: Int64, reserve: Int64 = reserveBytes) -> Bool {
        free - needed >= reserve
    }
}

public struct BackupRunner: Sendable {
    public typealias Prepare = @Sendable (RunEntry) async throws -> PreparedItem
    public typealias Send = @Sendable (PreparedItem) async throws -> SendResult
    public typealias Discard = @Sendable (PreparedItem) -> Void
    public typealias StopRequested = @Sendable () async -> Bool
    public typealias Pause = @Sendable (Double) async -> Void

    public struct RunResult: Sendable {
        public let record: RunRecord
        /// One plain sentence when the run stopped for a reason the user must act on; nil otherwise.
        public let stopMessage: String?
    }

    public static let pcFullMessage = "The PC's backup drive is full, so the run has stopped. Free up space on the PC, then run again. Items already verified are kept."
    public static let phoneFullMessage = "This iPhone is nearly out of storage, so the run has stopped to keep the phone safe. Free up space, then run again."

    private let prepare: Prepare
    private let send: Send
    private let discard: Discard
    private let stopRequested: StopRequested
    private let pause: Pause
    private let retry: RetryPolicy
    private let maxConcurrency: Int
    private let largeFileThresholdBytes: Int64
    private let maxBufferedBytes: Int64

    public init(prepare: @escaping Prepare, send: @escaping Send, discard: @escaping Discard,
                stopRequested: @escaping StopRequested, pause: @escaping Pause, retry: RetryPolicy = .standard,
                maxConcurrency: Int = 1, largeFileThresholdBytes: Int64 = 16_000_000,
                maxBufferedBytes: Int64 = 150_000_000) {
        self.prepare = prepare
        self.send = send
        self.discard = discard
        self.stopRequested = stopRequested
        self.pause = pause
        self.retry = retry
        self.maxConcurrency = max(1, maxConcurrency)
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.maxBufferedBytes = maxBufferedBytes
    }

    private enum StopAbort: Error { case requested }

    /// Works through the pending items in order. The record is saved after every item, so a stop or a kill
    /// resumes at the next item that has no outcome. When `maxConcurrency > 1`, exporting/hashing overlaps
    /// with concurrent uploads of small files while large videos still upload exclusively one at a time.
    public func run(_ start: RunRecord, now: Date, save: @escaping @Sendable (RunRecord) -> Void) async -> RunResult {
        if maxConcurrency > 1 {
            return await runPipelined(start, now: now, save: save)
        }
        var record = start
        var stopMessage: String?
        while let index = record.nextPending {
            if await stopRequested() {
                record.stop()
                break
            }
            do {
                record.record(try await attemptItem(record.entries[index]), at: index)
            } catch StopAbort.requested {
                // Leave the interrupted item pending so the next run picks it up cleanly.
                record.stop()
                break
            } catch is CancellationError {
                if await stopRequested() {
                    record.stop()
                    break
                }
                record.record(.failed("Transfer was cancelled before finishing."), at: index)
            } catch ItemError.pcFull {
                stopMessage = Self.pcFullMessage
                record.stop()
                break
            } catch ItemError.phoneFull {
                stopMessage = Self.phoneFullMessage
                record.stop()
                break
            } catch ItemError.unavailable(let reason) {
                record.record(.unavailable(reason), at: index)
            } catch ItemError.failed(let reason), ItemError.transient(let reason) {
                record.record(.failed(reason), at: index)
            } catch {
                record.record(.failed("Something unexpected went wrong with this item."), at: index)
            }
            save(record)
        }
        if record.finishIfDone(at: now) { save(record) }
        return RunResult(record: record, stopMessage: stopMessage)
    }

    /// Bounded 2-stage pipeline: one producer exports/hashes up to `maxConcurrency + 1` items (capped by
    /// `maxBufferedBytes` on disk) while up to `maxConcurrency` workers upload small files concurrently
    /// and large files (`>= largeFileThresholdBytes`) exclusively.
    private func runPipelined(_ start: RunRecord, now: Date, save: @escaping @Sendable (RunRecord) -> Void) async -> RunResult {
        let pendingIndices = start.entries.indices.filter { start.entries[$0].outcome == .pending }
        guard !pendingIndices.isEmpty else {
            var done = start
            if done.finishIfDone(at: now) { save(done) }
            return RunResult(record: done, stopMessage: nil)
        }

        let coordinator = PipelineCoordinator(
            maxConcurrency: maxConcurrency,
            maxBufferedBytes: maxBufferedBytes,
            discard: discard
        )
        let box = RecordBox(record: start)
        let entries = start.entries
        let runner = self

        await withTaskGroup(of: Void.self) { group in
            // Producer: sequentially exports and hashes pending originals ahead of the network workers.
            group.addTask {
                for index in pendingIndices {
                    if await runner.stopRequested() {
                        await box.stop(message: nil)
                        await coordinator.halt()
                        break
                    }
                    guard await coordinator.waitToProduce() else { break }
                    if await runner.stopRequested() {
                        await box.stop(message: nil)
                        await coordinator.halt()
                        break
                    }
                    do {
                        let prepared = try await runner.prepare(entries[index])
                        await coordinator.enqueue(index: index, item: prepared)
                    } catch is CancellationError {
                        if await runner.stopRequested() {
                            await box.stop(message: nil)
                            await coordinator.halt()
                            break
                        }
                        await box.record(.failed("Export was cancelled before finishing."), at: index, save: save)
                    } catch ItemError.phoneFull {
                        await box.stop(message: Self.phoneFullMessage)
                        await coordinator.halt()
                        break
                    } catch ItemError.unavailable(let reason) {
                        await box.record(.unavailable(reason), at: index, save: save)
                    } catch ItemError.failed(let reason), ItemError.transient(let reason) {
                        await box.record(.failed(reason), at: index, save: save)
                    } catch {
                        await box.record(.failed("Something unexpected went wrong with this item."), at: index, save: save)
                    }
                }
                await coordinator.markProducerDone()
            }

            // Consumers: upload prepared items with adaptive concurrency (parallel small files, solo large videos).
            for _ in 0..<maxConcurrency {
                group.addTask {
                    while let work = await coordinator.dequeue() {
                        let isLarge = work.item.totalBytes >= runner.largeFileThresholdBytes
                        let acquired = await coordinator.acquireSendSlot(isLarge: isLarge)
                        guard acquired else {
                            runner.discard(work.item)
                            await coordinator.releaseUnstarted(bytes: work.item.totalBytes)
                            break
                        }
                        do {
                            let outcome = try await runner.sendWithRetry(work.item)
                            runner.discard(work.item)
                            await coordinator.releaseSendSlot(isLarge: isLarge, bytes: work.item.totalBytes)
                            await box.record(outcome, at: work.index, save: save)
                        } catch StopAbort.requested {
                            runner.discard(work.item)
                            await coordinator.releaseSendSlot(isLarge: isLarge, bytes: work.item.totalBytes)
                            await box.stop(message: nil)
                            await coordinator.halt()
                            break
                        } catch is CancellationError {
                            runner.discard(work.item)
                            await coordinator.releaseSendSlot(isLarge: isLarge, bytes: work.item.totalBytes)
                            if await runner.stopRequested() {
                                await box.stop(message: nil)
                                await coordinator.halt()
                                break
                            }
                            await box.record(.failed("Transfer was cancelled before finishing."), at: work.index, save: save)
                        } catch ItemError.pcFull {
                            runner.discard(work.item)
                            await coordinator.releaseSendSlot(isLarge: isLarge, bytes: work.item.totalBytes)
                            await box.stop(message: Self.pcFullMessage)
                            await coordinator.halt()
                            break
                        } catch ItemError.unavailable(let reason) {
                            runner.discard(work.item)
                            await coordinator.releaseSendSlot(isLarge: isLarge, bytes: work.item.totalBytes)
                            await box.record(.unavailable(reason), at: work.index, save: save)
                        } catch ItemError.failed(let reason), ItemError.transient(let reason) {
                            runner.discard(work.item)
                            await coordinator.releaseSendSlot(isLarge: isLarge, bytes: work.item.totalBytes)
                            await box.record(.failed(reason), at: work.index, save: save)
                        } catch {
                            runner.discard(work.item)
                            await coordinator.releaseSendSlot(isLarge: isLarge, bytes: work.item.totalBytes)
                            await box.record(.failed("Something unexpected went wrong with this item."), at: work.index, save: save)
                        }
                    }
                }
            }
        }

        return await box.finalize(now: now, save: save)
    }

    /// One item: export, then send, retrying short network problems. The temporary copy is always discarded.
    private func attemptItem(_ entry: RunEntry) async throws -> ItemOutcome {
        let prepared = try await prepare(entry)
        defer { discard(prepared) }
        return try await sendWithRetry(prepared)
    }

    private func sendWithRetry(_ prepared: PreparedItem) async throws -> ItemOutcome {
        var attempt = 1
        while true {
            if await stopRequested() {
                throw StopAbort.requested
            }
            do {
                switch try await send(prepared) {
                case .verified: return .verified
                case .alreadyOnPC: return .alreadyOnPC
                }
            } catch ItemError.transient(let reason) {
                if await stopRequested() {
                    throw StopAbort.requested
                }
                guard let wait = retry.delay(afterAttempt: attempt) else {
                    throw ItemError.failed(reason)
                }
                attempt += 1
                await pause(wait)
                if await stopRequested() {
                    throw StopAbort.requested
                }
            }
        }
    }
}

private actor RecordBox {
    private var record: RunRecord
    private var stopMessage: String?

    init(record: RunRecord) {
        self.record = record
    }

    func record(_ outcome: ItemOutcome, at index: Int, save: @Sendable (RunRecord) -> Void) {
        record.record(outcome, at: index)
        save(record)
    }

    func stop(message: String?) {
        if let message, stopMessage == nil {
            stopMessage = message
        }
        record.stop()
    }

    func finalize(now: Date, save: @Sendable (RunRecord) -> Void) -> BackupRunner.RunResult {
        if record.finishIfDone(at: now) {
            save(record)
        }
        return BackupRunner.RunResult(record: record, stopMessage: stopMessage)
    }
}

private actor PipelineCoordinator {
    private let maxConcurrency: Int
    private let maxBufferedBytes: Int64
    private let discard: BackupRunner.Discard

    private var ready: [(index: Int, item: PreparedItem)] = []
    private var producerDone = false
    private var halted = false
    private var inFlightCount = 0
    private var queuedBytes: Int64 = 0
    private var activeSends = 0
    private var exclusiveActive = false
    private var exclusiveWaiting = 0

    private var producerWaiters: [CheckedContinuation<Bool, Never>] = []
    private var consumerWaiters: [CheckedContinuation<(index: Int, item: PreparedItem)?, Never>] = []
    private var slotWaiters: [CheckedContinuation<Bool, Never>] = []

    init(maxConcurrency: Int, maxBufferedBytes: Int64, discard: @escaping BackupRunner.Discard) {
        self.maxConcurrency = maxConcurrency
        self.maxBufferedBytes = maxBufferedBytes
        self.discard = discard
    }

    func waitToProduce() async -> Bool {
        while !halted && (inFlightCount >= maxConcurrency + 1 || (inFlightCount > 0 && queuedBytes >= maxBufferedBytes)) {
            let canContinue = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                producerWaiters.append(c)
            }
            if !canContinue { return false }
        }
        return !halted
    }

    func enqueue(index: Int, item: PreparedItem) {
        guard !halted else {
            discard(item)
            return
        }
        inFlightCount += 1
        queuedBytes += item.totalBytes
        if !consumerWaiters.isEmpty {
            let waiter = consumerWaiters.removeFirst()
            waiter.resume(returning: (index, item))
        } else {
            ready.append((index, item))
        }
    }

    func markProducerDone() {
        producerDone = true
        let waiters = consumerWaiters
        consumerWaiters.removeAll()
        for w in waiters { w.resume(returning: nil) }
    }

    func halt() {
        guard !halted else { return }
        halted = true
        for queued in ready {
            inFlightCount = max(0, inFlightCount - 1)
            queuedBytes = max(0, queuedBytes - queued.item.totalBytes)
            discard(queued.item)
        }
        ready.removeAll()

        let pWaiters = producerWaiters
        producerWaiters.removeAll()
        for w in pWaiters { w.resume(returning: false) }

        let cWaiters = consumerWaiters
        consumerWaiters.removeAll()
        for w in cWaiters { w.resume(returning: nil) }

        let sWaiters = slotWaiters
        slotWaiters.removeAll()
        for w in sWaiters { w.resume(returning: false) }
    }

    func dequeue() async -> (index: Int, item: PreparedItem)? {
        while true {
            if halted { return nil }
            if !ready.isEmpty { return ready.removeFirst() }
            if producerDone { return nil }
            let next = await withCheckedContinuation { (c: CheckedContinuation<(index: Int, item: PreparedItem)?, Never>) in
                consumerWaiters.append(c)
            }
            if let next { return next }
            if halted || producerDone { return nil }
        }
    }

    func acquireSendSlot(isLarge: Bool) async -> Bool {
        if isLarge { exclusiveWaiting += 1 }
        defer { if isLarge { exclusiveWaiting = max(0, exclusiveWaiting - 1) } }
        while true {
            if halted { return false }
            if isLarge {
                if activeSends == 0 && !exclusiveActive {
                    exclusiveActive = true
                    activeSends = 1
                    return true
                }
            } else {
                if !exclusiveActive && exclusiveWaiting == 0 && activeSends < maxConcurrency {
                    activeSends += 1
                    return true
                }
            }
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                slotWaiters.append(c)
            }
            if !ok { return false }
        }
    }

    func releaseSendSlot(isLarge: Bool, bytes: Int64) {
        activeSends = max(0, activeSends - 1)
        if isLarge { exclusiveActive = false }
        inFlightCount = max(0, inFlightCount - 1)
        queuedBytes = max(0, queuedBytes - bytes)
        wakeWaiters()
    }

    func releaseUnstarted(bytes: Int64) {
        inFlightCount = max(0, inFlightCount - 1)
        queuedBytes = max(0, queuedBytes - bytes)
        wakeWaiters()
    }

    private func wakeWaiters() {
        let sWaiters = slotWaiters
        slotWaiters.removeAll()
        for w in sWaiters { w.resume(returning: !halted) }

        if !producerWaiters.isEmpty && (halted || (inFlightCount < maxConcurrency + 1 && (inFlightCount == 0 || queuedBytes < maxBufferedBytes))) {
            let pWaiters = producerWaiters
            producerWaiters.removeAll()
            for w in pWaiters { w.resume(returning: !halted) }
        }
    }
}
