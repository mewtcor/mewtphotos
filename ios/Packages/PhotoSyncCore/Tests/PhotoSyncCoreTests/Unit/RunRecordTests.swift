// The run record: start, record, stop, resume, finish, and the file store (Phase 5, plan 05-02).
import Testing
import Foundation
@testable import PhotoSyncCore

private func photo(_ id: String) -> LibraryItem {
    LibraryItem(assetId: id, fileName: "\(id).HEIC", kind: .photo, onPhone: true, hidden: false, date: nil)
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Run record")
struct RunRecordTests {
    private func plan(_ ids: [String], known: Set<String> = []) -> [(item: LibraryItem, decision: PlanDecision)] {
        BackupPlanner.plan(ids.map(photo), alreadyOnPC: known)
    }

    @Test("a new run starts with known items done and new items pending")
    func startsFromPlan() {
        let record = RunRecord.start(plan(["A", "B", "C"], known: ["B"]), at: now)
        #expect(record.entries.map(\.outcome) == [.pending, .alreadyOnPC, .pending])
        #expect(record.status == .running)
        #expect(record.nextPending == 0)
    }

    @Test("outcomes are recorded and the next pending item moves on")
    func recordsAndAdvances() {
        var record = RunRecord.start(plan(["A", "B"]), at: now)
        record.record(.verified, at: 0)
        #expect(record.nextPending == 1)
        record.record(.failed("disk full"), at: 1)
        #expect(record.nextPending == nil)
        #expect(record.totals.addsUp)
        #expect(record.totals.failed == 1)
    }

    @Test("a stopped run resumes at the next item, with nothing redone")
    func stopThenResume() throws {
        var record = RunRecord.start(plan(["A", "B", "C"]), at: now)
        record.record(.verified, at: 0)
        record.stop()
        #expect(record.status == .stopped)

        let resumed = RunRecord.open(existing: record, plan: plan(["A", "B", "C"]), at: now.addingTimeInterval(60))
        #expect(resumed.nextPending == 1)
        #expect(resumed.entries[0].outcome == .verified)
        #expect(resumed.startedAt == now)
    }

    @Test("a run killed mid-send is resumed; the item that was in flight is pending again")
    func killedMidSend() throws {
        let dir = try scratchDirectory()
        let store = RunStore(directory: dir)
        var record = RunRecord.start(plan(["A", "B"]), at: now)
        record.record(.verified, at: 0)
        try store.save(record)
        // No stop(): the app was killed while item B was being sent.
        let loaded = try #require(store.load())
        #expect(loaded.nextPending == 1)
        #expect(RunRecord.open(existing: loaded, plan: plan(["A", "B"]), at: now).nextPending == 1)
    }

    @Test("a finished run keeps its result until a new run starts")
    func finishedKeptUntilReplaced() {
        var record = RunRecord.start(plan(["A"]), at: now)
        record.record(.verified, at: 0)
        let finished = record.finishIfDone(at: now.addingTimeInterval(5))
        #expect(finished)
        #expect(record.status == .finished)
        #expect(record.finishedAt == now.addingTimeInterval(5))
        #expect(record.totals.verified == 1)

        // Starting again replaces the finished record with a new running one.
        let next = RunRecord.open(existing: record, plan: plan(["A", "B"]), at: now.addingTimeInterval(100))
        #expect(next.status == .running)
        #expect(next.entries.count == 2)
    }

    @Test("a new run after a finished one starts again from the plan")
    func newRunAfterFinish() {
        var done = RunRecord.start(plan(["A"]), at: now)
        done.record(.verified, at: 0)
        done.finishIfDone(at: now)
        let next = RunRecord.open(existing: nil, plan: plan(["A", "B"]), at: now.addingTimeInterval(100))
        #expect(next.nextPending == 0)
        #expect(next.entries.count == 2)
    }

    @Test("stop does nothing to a finished run")
    func stopIgnoredWhenFinished() {
        var record = RunRecord.start(plan(["A"]), at: now)
        record.record(.verified, at: 0)
        record.finishIfDone(at: now)
        record.stop()
        #expect(record.status == .finished)
    }

    @Test("retrying failed items puts only them back in line and reopens a finished run")
    func retryFailedOnly() {
        var record = RunRecord.start(plan(["A", "B", "C"]), at: now)
        record.record(.failed("timed out"), at: 0)
        record.record(.unavailable("only in iCloud"), at: 1)
        record.record(.verified, at: 2)
        record.finishIfDone(at: now)
        #expect(record.status == .finished)
        #expect(record.retryFailed() == 1)
        #expect(record.entries.map(\.outcome) == [.pending, .unavailable("only in iCloud"), .verified])
        #expect(record.status == .running)
        #expect(record.finishedAt == nil)
    }

    @Test("one failed item can be retried; other items cannot")
    func retryOne() {
        var record = RunRecord.start(plan(["A", "B"]), at: now)
        record.record(.failed("timed out"), at: 0)
        record.record(.verified, at: 1)
        #expect(record.retry(at: 1) == false)
        #expect(record.retry(at: 0) == true)
        #expect(record.entries[0].outcome == .pending)
        #expect(record.nextPending == 0)
    }

    @Test("outcomes for indexes out of range are ignored")
    func outOfRange() {
        var record = RunRecord.start(plan(["A"]), at: now)
        record.record(.verified, at: 5)
        #expect(record.entries[0].outcome == .pending)
    }
}

@Suite("Run store")
struct RunStoreTests {
    @Test("a saved run loads back the same, dates included")
    func roundTrip() throws {
        let store = RunStore(directory: try scratchDirectory())
        var record = RunRecord.start(BackupPlanner.plan([photo("A")], alreadyOnPC: []), at: now)
        record.record(.unavailable("not supported in this version yet"), at: 0)
        try store.save(record)
        #expect(store.load() == record)
    }

    @Test("no file means no run")
    func none() throws {
        #expect(RunStore(directory: try scratchDirectory()).load() == nil)
    }

    @Test("a damaged file is treated as no run and does not crash")
    func damaged() throws {
        let dir = try scratchDirectory()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("run-record.json"))
        #expect(RunStore(directory: dir).load() == nil)
    }

    @Test("clear removes the run")
    func clear() throws {
        let store = RunStore(directory: try scratchDirectory())
        try store.save(RunRecord.start([], at: now))
        try store.clear()
        #expect(store.load() == nil)
    }
}
