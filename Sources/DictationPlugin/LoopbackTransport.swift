import Foundation

/// Sends a request and returns the answer. The formatting client and the endpoint probe use it, so tests
/// stub it (spec: `HTTPTransport`).
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum TransportError: Error, Equatable {
    /// The address is not on this Mac.
    case notLoopback
    /// The server answered with a redirect, which is never followed.
    case redirected
    case notHTTP
}

/// The transport to a server on this Mac: an ephemeral session with no proxy, no disk cache and no cookies,
/// that refuses redirects, and that checks every address with `LoopbackPolicy` before sending.
final class LoopbackTransport: HTTPTransport {
    private let session: URLSession

    /// - Parameter protocolClasses: for tests, a `URLProtocol` stub in front of the network.
    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = Self.makeConfiguration()
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return configuration
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let allowed = LoopbackPolicy.validated(url) else {
            throw TransportError.notLoopback
        }
        var checked = request
        checked.url = allowed
        let (data, response) = try await session.data(for: checked)
        guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP }
        if (300..<400).contains(http.statusCode) { throw TransportError.redirected }
        return (data, http)
    }

    /// Answers every redirect with "do not follow", so the redirect response itself comes back.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
