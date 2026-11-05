import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

/// A `URLProtocol` that answers from a table keyed by URL path, so tests never touch the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case body(Data, status: Int = 200, failAfter: Int? = nil)
        case redirect(URL)
        case status(Int)
    }

    struct Seen: Sendable {
        let path: String
        let range: String?
    }

    nonisolated(unsafe) private static let state = Mutex<(replies: [String: @Sendable (Seen) -> Reply], seen: [Seen])>(
        ([:], []))

    static func register(path: String, _ reply: @escaping @Sendable (Seen) -> Reply) {
        state.withLock { $0.replies[path] = reply }
    }

    static func requests(forPathPrefix prefix: String) -> [Seen] {
        state.withLock { $0.seen.filter { $0.path.hasPrefix(prefix) } }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let seen = Seen(path: url.path, range: request.value(forHTTPHeaderField: "Range"))
        let reply = Self.state.withLock { state -> (@Sendable (Seen) -> Reply)? in
            state.seen.append(seen)
            return state.replies[url.path]
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        switch reply(seen) {
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .body(let data, let status, let failAfter):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let failAfter {
                client?.urlProtocol(self, didLoad: data.prefix(failAfter))
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A tiny package of two files (one in a sub folder) on a repository name unique to the test.
struct Fixture {
    let repository = "test/\(UUID().uuidString.lowercased())"
    let a = Data(repeating: 0x41, count: 100)
    let b = Data("second file, a little longer than the first".utf8)
    let package: ModelPackage
    let directory: TemporaryDirectory
    var prefix: String { "/" + repository }

    init() throws {
        directory = try TemporaryDirectory()
        let a = a
        let b = b
        package = ModelPackage(
            id: "fixture", title: "Fixture", license: "MIT", attribution: "",
            sources: [
                ModelSource(
                    repository: repository, revision: "rev", into: "",
                    files: [
                        ModelFile(path: "Model.mlmodelc/weights/weight.bin", size: a.count, sha256: sha(a)),
                        ModelFile(path: "vocab.json", size: b.count, sha256: sha(b)),
                    ])
            ])
    }

    func manager(space: Int = .max) -> ModelManager {
        ModelManager(
            directory: directory.url.appending(path: "Models", directoryHint: .isDirectory),
            downloader: SessionDownloader(makeConfiguration: { StubProtocol.configuration() }),
            availableSpace: { _ in space })
    }

    func serve(
        a replyA: (@Sendable (StubProtocol.Seen) -> StubProtocol.Reply)? = nil,
        b replyB: (@Sendable (StubProtocol.Seen) -> StubProtocol.Reply)? = nil
    ) {
        let a = a
        let b = b
        StubProtocol.register(
            path: prefix + "/resolve/rev/Model.mlmodelc/weights/weight.bin", replyA ?? { _ in .body(a) })
        StubProtocol.register(path: prefix + "/resolve/rev/vocab.json", replyB ?? { _ in .body(b) })
    }
}
