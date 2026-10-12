// The run record kept on the phone (Phase 5, plan 05-02). Each item's outcome is saved as soon as it is known,
// so a run that is stopped or killed resumes at the next item that has no outcome yet. Pure logic plus a small
// file store; tested on Linux.
import Foundation

public enum RunStatus: String, Codable, Sendable {
    case running
    case stopped
    case finished
}

public struct RunEntry: Codable, Equatable, Sendable {
    public let assetId: String
    public let fileName: String
    public let date: Date?
    /// `pending` until the item's outcome is known. An item that was mid-send when the app stopped stays
    /// pending and is sent again; the PC recognises it, so nothing is stored twice.
    public var outcome: ItemOutcome

    public init(assetId: String, fileName: String, date: Date?, outcome: ItemOutcome) {
        self.assetId = assetId
        self.fileName = fileName
        self.date = date
        self.outcome = outcome
    }
}

public struct RunRecord: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schema: Int
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var entries: [RunEntry]

    public init(startedAt: Date, entries: [RunEntry]) {
        self.schema = Self.currentSchema
        self.startedAt = startedAt
        self.finishedAt = nil
        self.status = .running
        self.entries = entries
    }

    /// A new run: every planned item gets its outcome from the plan (already on the PC, unavailable), or waits
    /// as pending when it is to be sent.
    public static func start(_ plan: [(item: LibraryItem, decision: PlanDecision)], at now: Date) -> RunRecord {
        let entries = plan.map { entry -> RunEntry in
            let outcome: ItemOutcome
            switch entry.decision {
            case .alreadyOnPC: outcome = .alreadyOnPC
            case .send: outcome = .pending
            case .unavailable(let reason): outcome = .unavailable(reason)
            }
            return RunEntry(assetId: entry.item.assetId, fileName: entry.item.fileName, date: entry.item.date, outcome: outcome)
        }
        return RunRecord(startedAt: now, entries: entries)
    }

    /// Opens the run to use now. An unfinished run (running or stopped) is continued as it was; a finished one is
    /// kept until a new run replaces it, so its result can still be shown.
    public static func open(existing: RunRecord?, plan: [(item: LibraryItem, decision: PlanDecision)], at now: Date) -> RunRecord {
        if let existing, existing.status != .finished { return existing }
        return start(plan, at: now)
    }

    /// The index of the next item still waiting for an outcome, or nil when none is left.
    public var nextPending: Int? {
        entries.firstIndex { $0.outcome == .pending }
    }

    public var totals: RunTotals {
        RunTotals.tally(entries.map(\.outcome))
    }

    /// Saves one item's outcome. Ignored for an index out of range.
    public mutating func record(_ outcome: ItemOutcome, at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries[index].outcome = outcome
    }

    /// The user stopped the run, or the app was closed during it. Nothing is lost: the record keeps what is done.
    public mutating func stop() {
        guard status == .running else { return }
        status = .stopped
    }

    /// Puts every failed item back in line to be sent again, and reopens a finished run so the next start
    /// continues it. Unavailable items are not retried. Returns how many items were put back.
    @discardableResult
    public mutating func retryFailed() -> Int {
        var count = 0
        for index in entries.indices where Self.isFailed(entries[index].outcome) {
            entries[index].outcome = .pending
            count += 1
        }
        if count > 0 { reopen() }
        return count
    }

    /// Puts one failed item back in line to be sent again. Returns false, and changes nothing, for any other item.
    @discardableResult
    public mutating func retry(at index: Int) -> Bool {
        guard entries.indices.contains(index), Self.isFailed(entries[index].outcome) else { return false }
        entries[index].outcome = .pending
        reopen()
        return true
    }

    private static func isFailed(_ outcome: ItemOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    private mutating func reopen() {
        guard status == .finished else { return }
        status = .running
        finishedAt = nil
    }

    /// Ends the run when nothing is pending any more. Returns true when it finished now.
    @discardableResult
    public mutating func finishIfDone(at now: Date) -> Bool {
        guard nextPending == nil, status != .finished else { return false }
        status = .finished
        finishedAt = now
        return true
    }
}

/// The run record as one JSON file in the app's support folder.
public struct RunStore: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("run-record.json")
    }

    /// The saved run, or nil when there is none or the file cannot be read. A damaged file is treated as no run:
    /// the next run starts clean instead of stopping the app.
    public func load() -> RunRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let record = try? decoder.decode(RunRecord.self, from: data), record.schema == RunRecord.currentSchema else {
            return nil
        }
        return record
    }

    /// Writes atomically, so a crash mid-write leaves the previous record, not a half-written one.
    public func save(_ record: RunRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(record)
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
