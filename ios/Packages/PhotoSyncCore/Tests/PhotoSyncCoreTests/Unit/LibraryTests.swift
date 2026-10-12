// Library access rules, the known-assets check, and the pairing changes (Phase 4).
import Testing
import Foundation
@testable import PhotoSyncCore

@Suite("Library access")
struct LibraryAccessTests {
    @Test("only full access may run")
    func onlyFullRuns() {
        #expect(LibraryAccess.full.canRun)
        for access in [LibraryAccess.limited, .denied, .restricted, .notDetermined] {
            #expect(!access.canRun)
        }
    }

    @Test("limited access says plainly that the result is not complete")
    func limitedWarns() {
        #expect(LibraryAccess.limited.message.contains("selected photos only"))
        #expect(LibraryAccess.limited.message.contains("will not show a complete result"))
    }

    @Test("every state has its own words")
    func messagesDiffer() {
        let all: [LibraryAccess] = [.full, .limited, .denied, .restricted, .notDetermined]
        #expect(Set(all.map(\.message)).count == all.count)
    }
}

@Suite("Known assets")
struct KnownAssetsTests {
    @Test("answers come back in the same order as the identifiers")
    func order() async throws {
        let fake = FakeTransport([.json(#"{"known":[true,false]}"#)])
        let client = ServerClient(base: URL(string: "http://127.0.0.1:8787")!, transport: fake)
        let known = try await client.knownAssets(key: DeviceKey("tok"), assetIds: ["A", "B"])
        #expect(known == [true, false])
        let sent = await fake.requests()
        #expect(sent.count == 1)
        #expect(sent.first?.url.path == "/api/v1/assets/check")
    }

    @Test("an answer for a different number of items is refused")
    func mismatch() async {
        let fake = FakeTransport([.json(#"{"known":[true]}"#)])
        let client = ServerClient(base: URL(string: "http://127.0.0.1:8787")!, transport: fake)
        let error = await capturedError { _ = try await client.knownAssets(key: DeviceKey("tok"), assetIds: ["A", "B"]) }
        #expect(error != nil)
    }

    @Test("no identifiers means no request")
    func empty() async throws {
        let fake = FakeTransport([])
        let client = ServerClient(base: URL(string: "http://127.0.0.1:8787")!, transport: fake)
        #expect(try await client.knownAssets(key: DeviceKey("tok"), assetIds: []).isEmpty)
        #expect(await fake.requests().isEmpty)
    }
}
