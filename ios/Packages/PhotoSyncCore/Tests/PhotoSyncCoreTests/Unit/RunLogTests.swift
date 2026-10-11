// RunLog hazards: secrets, Bearer tokens, line injection, oversize messages, rotation, concurrency.
import Foundation
import Testing
import PhotoSyncCore

@Suite struct RunLogTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ps-log-\(UUID().uuidString)")
    }

    private func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test func aRegisteredSecretIsReplaced() async {
        let log = RunLog(directory: makeDirectory())
        await log.register(secret: "SECRET-VALUE-123")
        await log.append(.info, code: "probe", "value is SECRET-VALUE-123 and again SECRET-VALUE-123")
        let snapshot = await log.snapshot()
        #expect(!snapshot.contains("SECRET-VALUE-123"))
        #expect(snapshot.contains("value is <redacted> and again <redacted>"))
    }

    @Test func aSecretShorterThanEightCharactersIsNotRegistered() async {
        let log = RunLog(directory: makeDirectory())
        await log.register(secret: "abc1234")
        await log.append(.info, code: "probe", "keeps abc1234 as written")
        let snapshot = await log.snapshot()
        #expect(snapshot.contains("keeps abc1234 as written"))
    }

    @Test func aBearerTokenIsRedactedWithoutRegistration() async {
        let log = RunLog(directory: makeDirectory())
        await log.append(.warn, code: "probe", "Authorization: Bearer abc.def-123 was sent")
        let snapshot = await log.snapshot()
        #expect(snapshot.contains("Bearer <redacted> was sent"))
        #expect(!snapshot.contains("abc.def-123"))
    }

    @Test func controlCharactersCannotSplitOneCallIntoManyLines() async {
        let log = RunLog(directory: makeDirectory())
        await log.append(.info, code: "probe", "first\r\nsecond\nthird\u{0}fourth")
        let snapshot = await log.snapshot()
        #expect(lines(of: snapshot).count == 1)
        #expect(snapshot.hasSuffix("\n"))
        #expect(snapshot.contains("first  second third fourth"))
    }

    @Test func aLongMessageIsCutAtTwoThousandCharacters() async {
        let log = RunLog(directory: makeDirectory())
        await log.append(.info, code: "long", String(repeating: "x", count: 5000))
        let snapshot = await log.snapshot()
        #expect(snapshot.filter { $0 == "x" }.count == 2000)
    }

    @Test func rotationKeepsTheNewestLineAndNeverSplitsALine() async throws {
        let directory = makeDirectory()
        let log = RunLog(directory: directory, maxBytes: 600)
        for index in 0..<100 {
            await log.append(.info, code: "fill", "line \(index) padding")
        }
        let rotated = directory.appendingPathComponent("photosync.1.log")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let currentBytes = try Data(contentsOf: log.fileURL).count
        let rotatedBytes = try Data(contentsOf: rotated).count
        #expect(currentBytes <= 600)
        #expect(rotatedBytes <= 600)
        let snapshot = await log.snapshot()
        #expect(snapshot.contains("line 99 padding"))
        #expect(snapshot.hasSuffix("\n"))
        for line in lines(of: snapshot) {
            #expect(line.hasPrefix("20"), "line does not start with a timestamp: \(line)")
            #expect(line.hasSuffix(" padding"), "line is not complete: \(line)")
        }
    }

    @Test func twoHundredConcurrentAppendsMakeTwoHundredCompleteLines() async {
        let log = RunLog(directory: makeDirectory())
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { await log.append(.info, code: "burst", "msg-\(index)-end") }
            }
        }
        let snapshot = await log.snapshot()
        let all = lines(of: snapshot)
        #expect(all.count == 200)
        let numbers = Set(all.compactMap { line -> Int? in
            guard line.hasSuffix("-end"), let word = line.split(separator: " ").last else { return nil }
            return Int(word.dropFirst("msg-".count).dropLast("-end".count))
        })
        #expect(numbers == Set(0..<200))
    }

    @Test func aNewLogOverAnExistingDirectoryKeepsEarlierLines() async {
        let directory = makeDirectory()
        let first = RunLog(directory: directory)
        await first.append(.info, code: "before", "written by the first launch")
        let second = RunLog(directory: directory)
        await second.append(.info, code: "after", "written by the second launch")
        let snapshot = await second.snapshot()
        #expect(snapshot.contains("written by the first launch"))
        #expect(snapshot.contains("written by the second launch"))
    }

    @Test func theLogFileExistsImmediatelyAfterInit() {
        let log = RunLog(directory: makeDirectory())
        #expect(FileManager.default.fileExists(atPath: log.fileURL.path))
    }
}
