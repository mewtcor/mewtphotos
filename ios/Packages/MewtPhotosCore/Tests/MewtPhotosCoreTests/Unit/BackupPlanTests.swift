// The backup planner and the run totals (Phase 5, plan 05-01).
import Testing
import Foundation
@testable import MewtPhotosCore

private func item(_ id: String, _ kind: ItemKind = .photo, onPhone: Bool = true, hidden: Bool = false) -> LibraryItem {
    LibraryItem(assetId: id, fileName: "\(id).HEIC", kind: kind, onPhone: onPhone, hidden: hidden, date: nil)
}

@Suite("Backup planner")
struct BackupPlannerTests {
    @Test("a photo on the phone and not on the PC is sent")
    func sendsNewPhotos() {
        let plan = BackupPlanner.plan([item("A")], alreadyOnPC: [])
        #expect(plan.first?.decision == .send)
    }

    @Test("an item the PC already holds is skipped, whatever its kind")
    func skipsKnown() {
        let plan = BackupPlanner.plan([item("A"), item("V", .video)], alreadyOnPC: ["A", "V"])
        #expect(plan.map { $0.decision } == [.alreadyOnPC, .alreadyOnPC])
    }

    @Test("iCloud-only items are never sent; videos are sent like photos")
    func unsupportedNeverSent() {
        let plan = BackupPlanner.plan([item("V", .video), item("C", onPhone: false)], alreadyOnPC: [])
        #expect(plan.map { $0.decision } == [.send, .unavailable(BackupPlanner.unsupportedReason)])
    }

    @Test("a Live Photo is sent; its video part is sent beside the still")
    func livePhotoSent() {
        let plan = BackupPlanner.plan([item("L", .livePhoto)], alreadyOnPC: [])
        #expect(plan.first?.decision == .send)
    }

    @Test("hidden photos and burst frames are planned like any other photo")
    func hiddenAndBurstAreIncluded() {
        let plan = BackupPlanner.plan([item("H", hidden: true), item("B1"), item("B2")], alreadyOnPC: [])
        #expect(plan.map { $0.decision } == [.send, .send, .send])
    }

    @Test("every item gets exactly one decision, in the same order")
    func oneDecisionEach() {
        let items = [item("A"), item("V", .video), item("K"), item("C", onPhone: false)]
        let plan = BackupPlanner.plan(items, alreadyOnPC: ["K"])
        #expect(plan.map { $0.item.assetId } == ["A", "V", "K", "C"])
        #expect(plan.count == items.count)
    }
}

@Suite("Run totals")
struct RunTotalsTests {
    @Test("the parts add up to the whole")
    func addsUp() {
        let totals = RunTotals.tally([.alreadyOnPC, .verified, .verified, .failed("x"), .unavailable("y")])
        #expect(totals.considered == 5)
        #expect(totals.alreadyOnPC == 1)
        #expect(totals.verified == 2)
        #expect(totals.failed == 1)
        #expect(totals.unavailable == 1)
        #expect(totals.addsUp)
        #expect(totals.finished)
    }

    @Test("a run with pending items is not finished")
    func pendingNotFinished() {
        let totals = RunTotals.tally([.verified, .pending])
        #expect(totals.addsUp)
        #expect(!totals.finished)
    }

    @Test("a count that disagrees with the PC is reported, and agreement is silent")
    func pcMismatch() {
        let totals = RunTotals.tally([.verified, .verified])
        #expect(totals.pcMismatch(pcVerifiedCount: 2) == nil)
        #expect(totals.pcMismatch(pcVerifiedCount: 3) != nil)
    }

    @Test("the edits notice is stated plainly")
    func editsNotice() {
        #expect(BackupPlanner.editsNotice.contains("Edited versions of photos are not backed up yet"))
    }
}
