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

/// The rule for an item with several parts: backed up only when every part is verified or already on the PC.
public enum ItemParts {
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

    public init(prepare: @escaping Prepare, send: @escaping Send, discard: @escaping Discard,
                stopRequested: @escaping StopRequested, pause: @escaping Pause, retry: RetryPolicy = .standard) {
        self.prepare = prepare
        self.send = send
        self.discard = discard
        self.stopRequested = stopRequested
        self.pause = pause
        self.retry = retry
    }

    /// Works through the pending items in order. The record is saved after every item, so a stop or a kill
    /// resumes at the next item that has no outcome.
    public func run(_ start: RunRecord, now: Date, save: @escaping @Sendable (RunRecord) -> Void) async -> RunResult {
        var record = start
        var stopMessage: String?
        while let index = record.nextPending {
            if await stopRequested() {
                record.stop()
                break
            }
            do {
                record.record(try await attemptItem(record.entries[index]), at: index)
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

    /// One item: export, then send, retrying short network problems. The temporary copy is always discarded.
    private func attemptItem(_ entry: RunEntry) async throws -> ItemOutcome {
        let prepared = try await prepare(entry)
        defer { discard(prepared) }
        var attempt = 1
        while true {
            do {
                switch try await send(prepared) {
                case .verified: return .verified
                case .alreadyOnPC: return .alreadyOnPC
                }
            } catch ItemError.transient(let reason) {
                guard let wait = retry.delay(afterAttempt: attempt) else {
                    throw ItemError.failed(reason)
                }
                attempt += 1
                await pause(wait)
            }
        }
    }
}
