// pairing.json: round trip, strict validation of what is read back, and no secret fields.
import Foundation
import Testing
import PhotoSyncCore

@Suite struct PairingStoreTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ps-store-\(UUID().uuidString)")
    }

    private func record(schema: Int = 1, serverURL: String = "http://192.168.1.20:8787") -> PairingRecord {
        PairingRecord(schema: schema, serverURL: serverURL, deviceId: "dev-1", deviceName: "Phone",
                      serverName: "My PC", pairedAtEpoch: 1_700_000_000)
    }

    @Test func aMissingFileIsNone() {
        #expect(PairingStore(directory: makeDirectory()).load() == PairingLoad.none)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = PairingStore(directory: makeDirectory())
        try store.save(record())
        #expect(store.load() == .record(record()))
    }

    @Test func garbageBytesAreCorrupt() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x12, 0x7B]).write(to: directory.appendingPathComponent("pairing.json"))
        #expect(PairingStore(directory: directory).load() == .corrupt)
    }

    @Test func aSchemaOtherThanOneIsCorrupt() throws {
        let store = PairingStore(directory: makeDirectory())
        try store.save(record(schema: 2))
        #expect(store.load() == .corrupt)
    }

    @Test func aForeignOrHandEditedServerURLIsCorrupt() throws {
        let rows = [
            "https://evil.example",
            "http://192.168.1.20:8787/#pair=ABCD2345",
            "http://192.168.1.20:8787/extra",
            "192.168.1.20:8787",
            "http://user@192.168.1.20:8787",
            "",
        ]
        for url in rows {
            let store = PairingStore(directory: makeDirectory())
            try store.save(record(serverURL: url))
            #expect(store.load() == .corrupt, "accepted serverURL \(url)")
        }
    }

    @Test func theFileHasExactlyTheSixDocumentedKeysAndNoSecretField() throws {
        let directory = makeDirectory()
        try PairingStore(directory: directory).save(record())
        let data = try Data(contentsOf: directory.appendingPathComponent("pairing.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "serverURL", "deviceId", "deviceName", "serverName", "pairedAtEpoch"])
        for name in object.keys {
            let lowered = name.lowercased()
            #expect(!lowered.contains("token") && !lowered.contains("secret") && !lowered.contains("key"))
        }
    }

    @Test func savingTwiceReplacesTheFileAndLeavesNothingElseBehind() throws {
        let directory = makeDirectory()
        let store = PairingStore(directory: directory)
        try store.save(record())
        let second = PairingRecord(serverURL: "http://192.168.1.21:8787", deviceId: "dev-2", deviceName: "Phone",
                                   serverName: "Other PC", pairedAtEpoch: 1_700_000_100)
        try store.save(second)
        #expect(store.load() == .record(second))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["pairing.json"])
    }

    @Test func clearRemovesTheRecordAndToleratesAbsence() throws {
        let store = PairingStore(directory: makeDirectory())
        try store.save(record())
        try store.clear()
        #expect(store.load() == PairingLoad.none)
        try store.clear()
    }

    @Test func savingIntoAMissingDirectoryCreatesIt() throws {
        let nested = makeDirectory().appendingPathComponent("a").appendingPathComponent("b")
        let store = PairingStore(directory: nested)
        try store.save(record())
        #expect(store.load() == .record(record()))
    }
}
