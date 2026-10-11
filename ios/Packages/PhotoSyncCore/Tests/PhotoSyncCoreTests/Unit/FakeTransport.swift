// Test double for HTTPTransport: records every request and replays scripted outcomes in order.
// Internal (not private) because later plans' tests reuse it.
import Foundation
import PhotoSyncCore

actor FakeTransport: HTTPTransport {
    enum Outcome: Sendable {
        case response(status: Int, body: Data)
        case failure(any Error)

        static func json(_ text: String, status: Int = 200) -> Outcome {
            .response(status: status, body: Data(text.utf8))
        }
    }

    private var script: [Outcome]
    private var seen: [HTTPRequest] = []

    init(_ script: [Outcome]) {
        self.script = script
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        seen.append(request)
        guard !script.isEmpty else { throw URLError(.badServerResponse) }
        switch script.removeFirst() {
        case .response(let status, let body): return HTTPResponse(status: status, body: body)
        case .failure(let error): throw error
        }
    }

    func requests() -> [HTTPRequest] { seen }
}

/// Runs `body` and returns the ServerClientError it threw, or nil if it threw nothing (or something else).
func capturedError(_ body: () async throws -> Void) async -> ServerClientError? {
    do {
        try await body()
        return nil
    } catch let error as ServerClientError {
        return error
    } catch {
        return nil
    }
}
