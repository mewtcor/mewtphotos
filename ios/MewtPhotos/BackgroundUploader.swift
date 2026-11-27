// File transfer uploaders for Mewt Photos.
//
// - `StreamUploader`: In-process URLSession used by active backup runs (foreground & BGProcessingTask).
//   Avoids iOS `nsurlsessiond` background-session rate limiting / 7-day resource timeouts, adds an active
//   inactivity stall watchdog, and supports immediate cancellation when the user taps Stop.
// - `BackgroundUploader`: Background URLSession used by DiagnosticsView's single-video locked-screen test.
//   Thread-safe dictionary synchronization; no entitlement required.
import Foundation

/// Thread-safe, cancellable in-process file uploader with an inactivity stall watchdog.
/// Used by `BackupModel` so multi-thousand-item runs never stall inside `nsurlsessiond`.
final class StreamUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamUploader()

    /// Abort a transfer if no bytes are sent for this many seconds while uploading.
    static let stallTimeoutSeconds: TimeInterval = 45
    /// Once all request bytes are sent, allow longer for the server to fsync and SHA-256 verify on disk.
    static let verifyTimeoutSeconds: TimeInterval = 180
    private static let maxResponseBytes = 64 * 1024

    private let lock = NSLock()
    private var completions: [Int: (Int?, Data, Error?) -> Void] = [:]
    private var progressHandlers: [Int: (Int64, Int64) -> Void] = [:]
    private var activeTasks: [Int: URLSessionUploadTask] = [:]
    private var responseData: [Int: Data] = [:]
    private var bodySentComplete: Set<Int> = []
    private var lastActivity: [Int: Date] = [:]
    private var stalledTaskIds: Set<Int> = []
    private var watchdogs: [Int: DispatchSourceTimer] = [:]
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.mewtcor.mewtphotos.stream-uploader"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 120
        // Large videos over Wi-Fi may legitimately take minutes; the stall watchdog enforces liveness.
        configuration.timeoutIntervalForResource = 0
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    /// Starts streaming `file` for `request`. Returns the task identifier so callers can cancel it.
    @discardableResult
    func send(
        _ request: URLRequest,
        fromFile file: URL,
        progress: ((Int64, Int64) -> Void)? = nil,
        completion: @escaping (Int?, Data, Error?) -> Void
    ) -> Int {
        lock.lock()
        let task = session.uploadTask(with: request, fromFile: file)
        let id = task.taskIdentifier
        if let progress {
            progressHandlers[id] = progress
        }
        completions[id] = completion
        activeTasks[id] = task
        responseData[id] = Data()
        lastActivity[id] = Date()
        let timer = makeWatchdog(for: id)
        watchdogs[id] = timer
        lock.unlock()

        timer.resume()
        task.resume()
        return id
    }

    /// Cancels a specific in-flight upload task, if still active.
    func cancel(taskId: Int) {
        lock.lock()
        let task = activeTasks[taskId]
        lock.unlock()
        task?.cancel()
    }

    /// Immediately cancels every active stream upload (used when the user taps Stop or BGTask expires).
    func cancelActive() {
        lock.lock()
        let tasks = Array(activeTasks.values)
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    private func makeWatchdog(for taskId: Int) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let last = self.lastActivity[taskId], let task = self.activeTasks[taskId] else {
                self.lock.unlock()
                return
            }
            let limit = self.bodySentComplete.contains(taskId) ? Self.verifyTimeoutSeconds : Self.stallTimeoutSeconds
            let elapsed = Date().timeIntervalSince(last)
            if elapsed >= limit {
                self.stalledTaskIds.insert(taskId)
                self.lock.unlock()
                task.cancel()
            } else {
                self.lock.unlock()
            }
        }
        return timer
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let id = task.taskIdentifier
        lock.lock()
        lastActivity[id] = Date()
        if totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend {
            bodySentComplete.insert(id)
        }
        let handler = progressHandlers[id]
        lock.unlock()
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        lock.lock()
        lastActivity[id] = Date()
        if var existing = responseData[id], existing.count < Self.maxResponseBytes {
            let remaining = Self.maxResponseBytes - existing.count
            existing.append(data.prefix(remaining))
            responseData[id] = existing
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let status = (task.response as? HTTPURLResponse)?.statusCode
        lock.lock()
        let completion = completions.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id)
        activeTasks.removeValue(forKey: id)
        let data = responseData.removeValue(forKey: id) ?? Data()
        bodySentComplete.remove(id)
        lastActivity.removeValue(forKey: id)
        let watchdog = watchdogs.removeValue(forKey: id)
        let wasStalled = stalledTaskIds.remove(id) != nil
        lock.unlock()

        watchdog?.cancel()
        let finalError: Error? = wasStalled ? URLError(.timedOut) : error
        completion?(status, data, finalError)
    }
}

/// Sends a single file in a background URLSession, so the Diagnostics speed-test transfer keeps going
/// while the screen is locked. No entitlement is needed, so it works with the free Apple ID.
final class BackgroundUploader: NSObject, URLSessionDataDelegate {
    static let shared = BackgroundUploader()

    private let lock = NSLock()
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
        lock.lock()
        let task = session.uploadTask(with: request, fromFile: file)
        if let progress {
            progressHandlers[task.taskIdentifier] = progress
        }
        completions[task.taskIdentifier] = completion
        lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let handler = progressHandlers[task.taskIdentifier]
        lock.unlock()
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        lock.lock()
        progressHandlers.removeValue(forKey: task.taskIdentifier)
        let completion = completions.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        completion?(status, error)
    }

    /// Copies the bytes from `offset` to the end into a second file. A resumed upload sends only those bytes.
    static func tail(of file: URL, from offset: Int64) throws -> URL {
        let output = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "-tail.part")
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
