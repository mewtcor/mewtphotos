// Sends a file in a background URLSession, so the transfer keeps going while the screen is locked. iOS runs
// the transfer; the app starts it and hears the result in the delegate. No entitlement is needed, so it works
// with the free Apple ID.
import Foundation

final class BackgroundUploader: NSObject, URLSessionDataDelegate {
    static let shared = BackgroundUploader()

    private var completions: [Int: (Int?, Error?) -> Void] = [:]
    private var progressHandlers: [Int: (Int64, Int64) -> Void] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.mewtcor.mewtphotos.upload")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    /// Starts the transfer. `progress` receives `(totalBytesSent, totalBytesExpectedToSend)` on the main queue.
    /// `completion` gets the HTTP status (nil when there was no answer) and any error.
    /// If the app is relaunched after the transfer ends, the completion is lost; a later upload finishes the file.
    func send(
        _ request: URLRequest,
        fromFile file: URL,
        progress: ((Int64, Int64) -> Void)? = nil,
        completion: @escaping (Int?, Error?) -> Void
    ) {
        let task = session.uploadTask(with: request, fromFile: file)
        if let progress {
            progressHandlers[task.taskIdentifier] = progress
        }
        completions[task.taskIdentifier] = completion
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressHandlers[task.taskIdentifier]?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        progressHandlers.removeValue(forKey: task.taskIdentifier)
        completions.removeValue(forKey: task.taskIdentifier)?(status, error)
    }

    /// Copies the bytes from `offset` to the end into a second file. A resumed upload sends only those bytes.
    static func tail(of file: URL, from offset: Int64) throws -> URL {
        let output = file.deletingLastPathComponent().appendingPathComponent("upload-tail.part")
        try? FileManager.default.removeItem(at: output)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        let sink = try FileHandle(forWritingTo: output)
        defer { try? sink.close() }
        while let chunk = try input.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            try sink.write(contentsOf: chunk)
        }
        return output
    }
}

/// An upload whose bytes reached the PC but whose finish step did not get an answer. It is kept on disk and
/// retried when the app becomes active, so a finish lost to backgrounding is not lost for good.
struct PendingFinish: Codable {
    let uploadId: String
    let sha256: String

    private static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("pending-finish.json")
    }

    static func load(in directory: URL) -> PendingFinish? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? JSONDecoder().decode(PendingFinish.self, from: data)
    }

    func save(in directory: URL) {
        try? JSONEncoder().encode(self).write(to: Self.url(in: directory), options: .atomic)
    }

    static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }
}
