// The backup planner (Phase 5, plan 05-01): decides what each library item needs, and adds up the result.
// Pure logic, tested on Linux. The app reads PhotoKit and passes plain values in.
import Foundation

public enum ItemKind: String, Codable, Sendable {
    case photo
    case video
    case livePhoto
}

/// One library item as the app sees it. `onPhone` is false when the original exists only in iCloud.
public struct LibraryItem: Equatable, Sendable {
    public let assetId: String
    public let fileName: String
    public let kind: ItemKind
    public let onPhone: Bool
    public let hidden: Bool
    public let date: Date?

    public init(assetId: String, fileName: String, kind: ItemKind, onPhone: Bool, hidden: Bool, date: Date?) {
        self.assetId = assetId
        self.fileName = fileName
        self.kind = kind
        self.onPhone = onPhone
        self.hidden = hidden
        self.date = date
    }
}

public enum PlanDecision: Equatable, Sendable {
    /// The PC already holds this item: skipped without sending its data.
    case alreadyOnPC
    /// A photo that is on the phone and not on the PC yet.
    case send
    /// Not backed up in this version, with the reason shown to the user.
    case unavailable(String)
}

public enum BackupPlanner {
    /// The reason every unsupported item shows (Phase 5 success criterion 5).
    public static let unsupportedReason = "not supported in this version yet"

    /// Stated on every result (REP-07).
    public static let editsNotice = "Edited versions of photos are not backed up yet. Only the originals are sent."

    /// One decision per item, in the same order. The PC's answer is checked first, so an item it already holds
    /// is never sent again, whatever its kind.
    public static func plan(_ items: [LibraryItem], alreadyOnPC: Set<String>) -> [(item: LibraryItem, decision: PlanDecision)] {
        items.map { item in
            if alreadyOnPC.contains(item.assetId) { return (item, .alreadyOnPC) }
            if item.kind != .photo || !item.onPhone { return (item, .unavailable(unsupportedReason)) }
            return (item, .send)
        }
    }
}

/// Where one item ended up. `pending` means not yet decided, which is never allowed at the end of a run.
public enum ItemOutcome: Equatable, Sendable {
    case pending
    case alreadyOnPC
    case verified
    case failed(String)
    case unavailable(String)
}

/// The totals shown at the end of a run (REP-02): considered = already on PC + verified + failed + unavailable.
public struct RunTotals: Equatable, Sendable {
    public let considered: Int
    public let alreadyOnPC: Int
    public let verified: Int
    public let failed: Int
    public let unavailable: Int
    public let pending: Int

    public init(considered: Int, alreadyOnPC: Int, verified: Int, failed: Int, unavailable: Int, pending: Int) {
        self.considered = considered
        self.alreadyOnPC = alreadyOnPC
        self.verified = verified
        self.failed = failed
        self.unavailable = unavailable
        self.pending = pending
    }

    public static func tally(_ outcomes: [ItemOutcome]) -> RunTotals {
        var counts = [Int](repeating: 0, count: 5)
        for outcome in outcomes {
            switch outcome {
            case .pending: counts[0] += 1
            case .alreadyOnPC: counts[1] += 1
            case .verified: counts[2] += 1
            case .failed: counts[3] += 1
            case .unavailable: counts[4] += 1
            }
        }
        return RunTotals(considered: outcomes.count, alreadyOnPC: counts[1], verified: counts[2],
                         failed: counts[3], unavailable: counts[4], pending: counts[0])
    }

    /// True when the parts add up to the whole. A total that does not add up must not be shown as complete.
    public var addsUp: Bool {
        alreadyOnPC + verified + failed + unavailable + pending == considered
    }

    /// True once nothing is left pending: the run has finished and the totals are final.
    public var finished: Bool { pending == 0 }

    /// Compares the verified count with the PC's own count. Nil when they agree; otherwise a sentence to show.
    public func pcMismatch(pcVerifiedCount: Int) -> String? {
        guard pcVerifiedCount != verified else { return nil }
        return "The PC reports \(pcVerifiedCount) items verified from this phone; this run counted \(verified). Check the failed list and run again."
    }
}
