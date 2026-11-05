import Foundation
import Synchronization
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

/// A URL protocol that answers by host, port and path, so the transport's session can be exercised without
/// a network. Registered only on the session under test.
final class LoopbackStub: URLProtocol, @unchecked Sendable {
    enum Reply {
        case json(String, status: Int = 200)
        case redirect(String)
    }

    nonisolated(unsafe) private static let state = Mutex<(replies: [String: Reply], seen: [URL])>(([:], []))

    /// `key` is `host:port/path`.
    static func register(_ key: String, _ reply: Reply) { state.withLock { $0.replies[key] = reply } }
    static func reset() { state.withLock { $0 = ([:], []) } }
    static var seen: [URL] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let key = "\(url.host() ?? ""):\(url.port ?? 80)\(url.path)"
        let reply = Self.state.withLock { state -> Reply? in
            state.seen.append(url)
            return state.replies[key]
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch reply {
        case .json(let body, let status):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target])!
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            // The session declines the redirect; the redirect response is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct LoopbackTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test(arguments: [
        "http://127.0.0.1:11434", "http://127.0.0.1", "http://127.1.2.3:80/v1", "http://[::1]:1234",
        "http://localhost:1234",
    ])
    func acceptsLoopback(_ text: String) {
        #expect(LoopbackPolicy.validated(url(text)) != nil)
    }

    @Test(arguments: [
        "http://example.com", "http://192.168.1.10:11434", "http://0.0.0.0:11434", "http://[::ffff:127.0.0.1]",
        "http://2130706433", "http://0177.0.0.1", "http://127.0.0.01", "http://127.1", "http://127.0.0.256",
        "http://127.0.0.1@evil.com", "http://user:pass@127.0.0.1", "https://example.com", "https://127.0.0.1:11434",
        "ftp://127.0.0.1", "http://0x7f.0.0.1", "http://localhost.evil.com", "http://127.0.0.1.evil.com",
    ])
    func rejectsEverythingElse(_ text: String) {
        #expect(LoopbackPolicy.validated(url(text)) == nil)
    }

    @Test func localhostBecomesNumeric() {
        #expect(LoopbackPolicy.validated(url("http://localhost:1234/v1/models"))?.host() == "127.0.0.1")
        #expect(LoopbackPolicy.validated(url("http://LOCALHOST:1234"))?.host() == "127.0.0.1")
    }

    @Test func parsesSettingsText() {
        #expect(LoopbackPolicy.parse("127.0.0.1:11434")?.absoluteString == "http://127.0.0.1:11434")
        #expect(LoopbackPolicy.parse("  localhost:1234  ")?.host() == "127.0.0.1")
        #expect(LoopbackPolicy.parse("example.com") == nil)
        #expect(LoopbackPolicy.parse("") == nil)
    }

    // MARK: Session

    @Test func sessionHasNoProxyNoCacheNoCookies() {
        let configuration = LoopbackTransport.makeConfiguration()
        #expect((configuration.connectionProxyDictionary ?? ["x": 1]).isEmpty)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test func transportRefusesNonLoopbackBeforeSending() async {
        LoopbackStub.reset()
        let transport = LoopbackTransport(protocolClasses: [LoopbackStub.self])
        await #expect(throws: TransportError.notLoopback) {
            _ = try await transport.send(URLRequest(url: url("http://example.com/v1/models")))
        }
        await #expect(throws: TransportError.notLoopback) {
            _ = try await transport.send(URLRequest(url: url("http://127.0.0.1@evil.com/v1/models")))
        }
        #expect(LoopbackStub.seen.isEmpty)
    }

    @Test func transportSendsLocalhostAsNumeric() async throws {
        LoopbackStub.reset()
        LoopbackStub.register("127.0.0.1:1234/v1/models", .json(#"{"data":[]}"#))
        let transport = LoopbackTransport(protocolClasses: [LoopbackStub.self])
        let (_, response) = try await transport.send(URLRequest(url: url("http://localhost:1234/v1/models")))
        #expect(response.statusCode == 200)
        #expect(LoopbackStub.seen.first?.host() == "127.0.0.1")
    }

    @Test func transportBlocksRedirects() async {
        LoopbackStub.reset()
        LoopbackStub.register("127.0.0.1:11434/v1/models", .redirect("http://evil.example.com/steal"))
        let transport = LoopbackTransport(protocolClasses: [LoopbackStub.self])
        await #expect(throws: TransportError.redirected) {
            _ = try await transport.send(URLRequest(url: url("http://127.0.0.1:11434/v1/models")))
        }
        #expect(!LoopbackStub.seen.contains { $0.host() == "evil.example.com" })
    }

    // MARK: Probe

    @Test func probeFindsTheThreeKnownServers() async {
        LoopbackStub.reset()
        LoopbackStub.register("127.0.0.1:11434/v1/models", .json(#"{"data":[{"id":"qwen3:4b"},{"id":"bielik"}]}"#))
        LoopbackStub.register("127.0.0.1:1234/v1/models", .json(#"{"data":[{"id":"lm-model"}]}"#))
        LoopbackStub.register("127.0.0.1:9931/v1/models", .json(#"{"data":[]}"#))
        let probe = EndpointProbe(transport: LoopbackTransport(protocolClasses: [LoopbackStub.self]))
        let found = await probe.discover()
        #expect(found.map(\.name) == ["Ollama", "LM Studio", "llama-server"])
        #expect(found[0].models == ["qwen3:4b", "bielik"])
        #expect(found[2].models.isEmpty)
    }

    @Test func probeSkipsServersThatDoNotAnswerOrAnswerWithAnError() async {
        LoopbackStub.reset()
        LoopbackStub.register("127.0.0.1:1234/v1/models", .json("{}", status: 500))
        LoopbackStub.register("127.0.0.1:9931/v1/models", .json(#"{"data":[{"id":"m"}]}"#))
        let probe = EndpointProbe(transport: LoopbackTransport(protocolClasses: [LoopbackStub.self]))
        #expect(await probe.discover().map(\.name) == ["llama-server"])
    }

    @Test func probeAsksTheCustomAddressOnlyWhenItIsLoopback() async {
        LoopbackStub.reset()
        LoopbackStub.register("127.0.0.1:8080/v1/models", .json(#"{"data":[{"id":"x"}]}"#))
        let probe = EndpointProbe(transport: LoopbackTransport(protocolClasses: [LoopbackStub.self]))
        let found = await probe.discover(custom: url("http://localhost:8080"))
        #expect(found.map(\.baseURL.absoluteString) == ["http://127.0.0.1:8080"])
        _ = await probe.discover(custom: url("http://example.com:8080"))
        #expect(!LoopbackStub.seen.contains { $0.host() == "example.com" })
    }

    @Test func probeFollowsNoRedirect() async {
        LoopbackStub.reset()
        LoopbackStub.register("127.0.0.1:11434/v1/models", .redirect("http://evil.example.com/"))
        let probe = EndpointProbe(transport: LoopbackTransport(protocolClasses: [LoopbackStub.self]))
        #expect(await probe.discover().isEmpty)
        #expect(!LoopbackStub.seen.contains { $0.host() == "evil.example.com" })
    }
}
