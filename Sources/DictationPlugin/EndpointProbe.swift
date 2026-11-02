import Foundation

/// A formatting server found on this Mac.
struct LLMEndpoint: Equatable, Sendable, Identifiable {
    /// `http://127.0.0.1:11434`
    let baseURL: URL
    let name: String
    /// The ids `GET /v1/models` listed.
    let models: [String]

    var id: String { baseURL.absoluteString }
}

/// Finds OpenAI-compatible servers: `GET /v1/models` on the usual ports and on the address from Settings
/// (spec: `EndpointProbe`). Only loopback addresses are asked.
struct EndpointProbe: Sendable {
    static let wellKnown: [(name: String, url: String)] = [
        ("Ollama", "http://127.0.0.1:11434"),
        ("LM Studio", "http://127.0.0.1:1234"),
        ("llama-server", "http://127.0.0.1:9931"),
    ]

    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    init(transport: any HTTPTransport, timeout: TimeInterval = 1.5) {
        self.transport = transport
        self.timeout = timeout
    }

    /// Every server that answers, in the order of the list, the one from Settings last.
    func discover(custom: URL? = nil) async -> [LLMEndpoint] {
        var candidates: [(String, URL)] = Self.wellKnown.compactMap { entry in
            URL(string: entry.url).map { (entry.name, $0) }
        }
        if let custom, let valid = LoopbackPolicy.validated(custom), !candidates.contains(where: { $0.1 == valid }) {
            candidates.append((valid.host() ?? "Custom", valid))
        }
        return await withTaskGroup(of: (Int, LLMEndpoint?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { (index, await probe(name: candidate.0, base: candidate.1)) }
            }
            var found: [(Int, LLMEndpoint)] = []
            for await (index, endpoint) in group {
                if let endpoint { found.append((index, endpoint)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// One server, or `nil` when nothing answers there.
    func probe(name: String, base: URL) async -> LLMEndpoint? {
        var request = URLRequest(url: base.appending(path: "v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200 else {
            return nil
        }
        return LLMEndpoint(baseURL: base, name: name, models: Self.modelIDs(in: data))
    }

    static func modelIDs(in data: Data) -> [String] {
        struct Listing: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return (try? JSONDecoder().decode(Listing.self, from: data))?.data.map(\.id) ?? []
    }
}
