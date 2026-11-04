import Foundation

public enum ModelError: Error, Equatable {
    case insufficientSpace(needed: Int, available: Int)
    case checksumMismatch(path: String)
    case sizeMismatch(path: String)
    case disallowedHost(String)
    case httpStatus(Int)
    case folderIncomplete(missing: [String])
    case notInstalled
}

/// Downloads one file, appending to a partial file so an interrupted download resumes.
public protocol FileDownloading: Sendable {
    /// Downloads `url` into `file`. When `file` already has bytes, asks the server to continue after them.
    /// `progress` gets the number of bytes in `file` so far.
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int) -> Void) async throws
}

/// The live downloader: an ephemeral `URLSession` (no cache on disk) that talks HTTPS to the allowed model
/// hosts only, and follows a redirect only to another allowed host (spec: `LoopbackPolicy`).
public struct SessionDownloader: FileDownloading {
    /// Tests put a `URLProtocol` stub in here.
    public var makeConfiguration: @Sendable () -> URLSessionConfiguration

    public init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = Self.ephemeralConfiguration) {
        self.makeConfiguration = makeConfiguration
    }

    @Sendable public static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    public func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int) -> Void) async throws {
        guard url.scheme == "https", let host = url.host, ModelCatalog.isAllowedDownloadHost(host) else {
            throw ModelError.disallowedHost(url.host ?? "")
        }
        let offset = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let job = DownloadJob(file: file, offset: offset, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: makeConfiguration(), delegate: job, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                job.start(task, continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private var offset: Int
    private let progress: @Sendable (Int) -> Void
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var alreadyComplete = false

    init(file: URL, offset: Int, progress: @escaping @Sendable (Int) -> Void) {
        self.file = file
        self.offset = offset
        self.progress = progress
    }

    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        task.resume()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, url.scheme == "https", let host = url.host, ModelCatalog.isAllowedDownloadHost(host) {
            completionHandler(request)
        } else {
            failure = ModelError.disallowedHost(request.url?.host ?? "")
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard failure == nil, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            openHandle(truncate: false)
        case 200:
            // The server ignored the range: start the file over.
            offset = 0
            openHandle(truncate: true)
        case 416:
            // Nothing left to send after the bytes we have; the checksum decides whether they are all.
            alreadyComplete = true
            completionHandler(.cancel)
            return
        default:
            failure = ModelError.httpStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    private func openHandle(truncate: Bool) {
        do {
            if truncate || !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            if truncate {
                try handle.truncate(atOffset: 0)
            }
            try handle.seekToEnd()
            self.handle = handle
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            offset += data.count
            progress(offset)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let result: Result<Void, Error>
        if let failure {
            result = .failure(failure)
        } else if alreadyComplete {
            result = .success(())
        } else if let error {
            result = .failure(error)
        } else {
            result = .success(())
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}
