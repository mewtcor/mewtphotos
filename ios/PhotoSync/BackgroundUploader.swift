// Sends a file in a background URLSession, so the transfer keeps going while the screen is locked. iOS runs
// the transfer; the app starts it and hears the result in the delegate. No entitlement is needed, so it works
// with the free Apple ID.
import Foundation

final class BackgroundUploader: NSObject, URLSessionDataDelegate {
    static let shared = BackgroundUploader()

    private var completions: [Int: (Int?, Error?) -> Void] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.mewtcor.photosync.upload")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    /// Starts the transfer. `completion` gets the HTTP status (nil when there was no answer) and any error.
    /// If the app is relaunched after the transfer ends, the completion is lost; a later upload finishes the file.
    func send(_ request: URLRequest, fromFile file: URL, completion: @escaping (Int?, Error?) -> Void) {
        let task = session.uploadTask(with: request, fromFile: file)
        completions[task.taskIdentifier] = completion
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
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
