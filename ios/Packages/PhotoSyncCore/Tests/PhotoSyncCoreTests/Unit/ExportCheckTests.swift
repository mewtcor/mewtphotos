// Export check: the SHA-256 lists from the phone and from the PC agree, or the difference is named.
import Testing
import PhotoSyncCore

@Suite struct ExportCheckTests {
    @Test func matchingHashesAreMatches() {
        let results = ExportCheck.compare(phone: ["a.HEIC": "h1"], pc: ["a.HEIC": "h1"])
        #expect(results == [ExportResult(name: "a.HEIC", outcome: .match)])
    }

    @Test func differentHashIsAMismatch() {
        let results = ExportCheck.compare(phone: ["a.MOV": "h1"], pc: ["a.MOV": "h2"])
        #expect(results == [ExportResult(name: "a.MOV", outcome: .mismatch)])
    }

    @Test func fileOnlyOnOneSideIsReported() {
        let results = ExportCheck.compare(phone: ["a.DNG": "h1"], pc: ["b.DNG": "h2"])
        #expect(results.contains(ExportResult(name: "a.DNG", outcome: .onlyOnPhone)))
        #expect(results.contains(ExportResult(name: "b.DNG", outcome: .onlyOnPC)))
    }

    @Test func manifestRoundTrips() {
        let text = ExportManifest.text(["a.HEIC": "h1", "b.MOV": "h2"])
        #expect(ExportManifest.parse(text) == ["a.HEIC": "h1", "b.MOV": "h2"])
    }

    @Test func emptyInputsGiveNoResults() {
        #expect(ExportCheck.compare(phone: [:], pc: [:]).isEmpty)
    }
}
