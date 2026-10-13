// The coverage comparison: what the PC is missing, what it holds, and what it keeps after a phone deletion (milestone 7).
import Testing
import Foundation
@testable import PhotoSyncCore

private func item(_ id: String) -> LibraryItem {
    LibraryItem(assetId: id, fileName: "\(id).HEIC", kind: .photo, onPhone: true, hidden: false, date: nil)
}

@Suite("Coverage")
struct CoverageTests {
    @Test("lists what the PC does not hold, and counts what it holds beyond the library")
    func compares() {
        let coverage = Coverage.compare(library: [item("A"), item("B"), item("C")], held: ["A", "C", "Z"])
        #expect(coverage.missing == [item("B")])
        #expect(coverage.held == 2)
        #expect(coverage.onPCOnly == 1)
        #expect(coverage.isVerified == false)
    }

    @Test("verified when every library item is on the PC")
    func verified() {
        let coverage = Coverage.compare(library: [item("A")], held: ["A", "Z"])
        #expect(coverage.isVerified)
        #expect(coverage.missing.isEmpty)
        #expect(coverage.onPCOnly == 1)
    }
}
