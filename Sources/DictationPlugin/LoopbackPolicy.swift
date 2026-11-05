import Foundation

/// Decides which addresses the formatting client may talk to: this Mac only (spec: `LoopbackPolicy`).
///
/// Pure and without DNS. Accepted: `localhost` (rewritten to `127.0.0.1` by Lintel itself, so neither DNS
/// nor `/etc/hosts` is asked), a dotted-decimal `127.x.x.x` and `[::1]`, over plain `http`. Everything else is
/// refused: other hosts, mapped (`::ffff:`), numeric and octal IP forms, `user@host` tricks and other schemes.
enum LoopbackPolicy {
    /// The URL to use, with `localhost` rewritten, or `nil` when the address is not loopback.
    static func validated(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.scheme?.lowercased() == "http" else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        guard let rawHost = components.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()

        if host == "localhost" {
            components.host = "127.0.0.1"
        } else if host == "::1" {
            // Kept as it is: the URL already carries `[::1]`.
        } else if isLoopbackIPv4(host) {
            // Kept as it is.
        } else {
            return nil
        }
        return components.url
    }

    static func isAllowed(_ url: URL) -> Bool { validated(url) != nil }

    /// Parses the text of a settings field: with or without `http://`.
    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: withScheme) else { return nil }
        return validated(url)
    }

    /// `127.a.b.c` in plain decimal: no leading zeros (which some resolvers read as octal), four parts.
    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                part == "0" || !part.hasPrefix("0"), let value = Int(part), value <= 255
            else { return false }
            return true
        }
    }
}
