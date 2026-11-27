// Launch evidence: the counter survives bad files, and the one-line facts are stable and secret-free.
import Foundation
import Testing
import MewtPhotosCore

@Suite struct LaunchEvidenceTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ps-launch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func facts(launch: Int = 3, alt: String? = nil, keychain: String = "found",
                       pairing: String = "present") -> LaunchFacts {
        LaunchFacts(launch: launch, version: "0.1.0", build: "1", gitSHA: "abc1234",
                    bundleID: "com.mewtcor.mewtphotos", altBundleID: alt, keychain: keychain, pairing: pairing)
    }

    @Test func counterCountsUpAcrossCalls() throws {
        let dir = makeDirectory()
        #expect(try LaunchCounter.next(in: dir) == 1)
        #expect(try LaunchCounter.next(in: dir) == 2)
        #expect(try LaunchCounter.next(in: dir) == 3)
    }

    @Test func missingEmptyOrNonNumericFileRestartsAtOne() throws {
        for contents in [nil, "", "not a number"] as [String?] {
            let dir = makeDirectory()
            if let contents {
                try contents.write(to: dir.appendingPathComponent("launch-count"), atomically: true, encoding: .utf8)
            }
            #expect(try LaunchCounter.next(in: dir) == 1)
        }
    }

    @Test func logLineHasTheFixedFieldsInOrder() {
        #expect(facts().logLine ==
            "launch=3 version=0.1.0 build=1 sha=abc1234 bundle=com.mewtcor.mewtphotos alt_bundle=- keychain=found pairing=present")
    }

    @Test func altBundleIsShownWhenPresent() {
        #expect(facts(alt: "com.mewtcor.mewtphotos.alt").logLine.contains("alt_bundle=com.mewtcor.mewtphotos.alt"))
    }

    @Test func newlinesInsideValuesAreStripped() {
        let line = LaunchFacts(launch: 1, version: "0.1\n.2", build: "1\r", gitSHA: "a\nb",
                               bundleID: "x", altBundleID: nil, keychain: "found", pairing: "none").logLine
        #expect(!line.contains("\n"))
        #expect(!line.contains("\r"))
        #expect(line.hasPrefix("launch=1 version=0.1.2 build=1 sha=ab"))
    }
}
