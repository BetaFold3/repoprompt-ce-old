import Foundation

/// Why a configured approved image host is rejected. Shared by Settings validation and the image fetcher.
package enum RichPresentationHostRejection: String, Error, Equatable {
    case empty
    case tooLong = "too_long"
    case wildcard
    case ipLiteral = "ip_literal"
    case localName = "local_name"
    case singleLabel = "single_label"
    case notLowercaseASCII = "not_lowercase_ascii"
    case invalidSyntax = "invalid_syntax"

    package var message: String {
        switch self {
        case .empty: "Enter a host name such as images.example.com."
        case .tooLong: "Host names can be at most 253 characters."
        case .wildcard: "Wildcards are not allowed; list each exact host."
        case .ipLiteral: "IP addresses are not allowed; use the exact DNS host name."
        case .localName: "localhost and .local names are not allowed."
        case .singleLabel: "Use a fully qualified host name with at least two labels."
        case .notLowercaseASCII: "Use lowercase ASCII letters."
        case .invalidSyntax:
            "Use letters, digits, hyphens and dots only, without a scheme, port, path or trailing dot."
        }
    }
}

/// HTTPS URL rules for source links and article images (rich presentation spec, A2 and image boundary).
package enum RichPresentationURLPolicy {
    private static let maxHostBytes = 253
    private static let maxLabelBytes = 63

    /// Strictly validates an exact approved host: lowercase ASCII DNS name, at least two labels, no
    /// wildcard, IP literal, port, trailing dot, `localhost`, or `.local`/`.localhost` name.
    package static func validateApprovedHost(_ host: String) -> Result<String, RichPresentationHostRejection> {
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty else { return .failure(.empty) }
        guard bytes.count <= maxHostBytes else { return .failure(.tooLong) }
        if bytes.contains(UInt8(ascii: "*")) { return .failure(.wildcard) }
        if bytes.contains(UInt8(ascii: "[")) || bytes.contains(UInt8(ascii: "]"))
            || bytes.count(where: { $0 == UInt8(ascii: ":") }) > 1
        {
            return .failure(.ipLiteral)
        }
        if bytes.contains(where: { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }) {
            return .failure(.notLowercaseASCII)
        }
        guard bytes.allSatisfy(isHostByte) else { return .failure(.invalidSyntax) }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ isValidLabel($0) }) else { return .failure(.invalidSyntax) }
        if host == "localhost" || host.hasSuffix(".localhost") || labels.last == "local" {
            return .failure(.localName)
        }
        if labels.allSatisfy({ $0.utf8.allSatisfy(isDigit) }) { return .failure(.ipLiteral) }
        guard labels.count >= 2 else { return .failure(.singleLabel) }
        guard let first = labels.last?.utf8.first, isLowercaseLetter(first) else {
            return .failure(.invalidSyntax)
        }
        return .success(host)
    }

    /// Settings entry convenience: trims surrounding whitespace and lowercases, then validates strictly.
    package static func normalizeApprovedHostInput(_ input: String) -> Result<String, RichPresentationHostRejection> {
        validateApprovedHost(input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Source link rule: absolute HTTPS URL with a host, no userinfo, printable ASCII only, at most 2,048 characters.
    package static func validatedSourceURL(_ text: String) -> URL? {
        guard text.utf8.count <= RichPresentationLimits.maxURLCharacters,
              let parsed = parseHTTPS(text)
        else { return nil }
        return parsed.url
    }

    /// Image request rule: HTTPS, port absent or 443, valid DNS host exactly in `approvedHosts`.
    /// Returns the URL to request, or the terminal image failure code. Never performs network work.
    package static func evaluateImageURL(
        _ text: String,
        approvedHosts: Set<String>
    ) -> Result<URL, RichPresentationImageFailureCode> {
        guard text.utf8.count <= RichPresentationLimits.maxURLCharacters,
              let parsed = parseHTTPS(text),
              parsed.port == nil || parsed.port == 443,
              case .success = validateApprovedHost(parsed.host)
        else { return .failure(.invalidURL) }
        guard approvedHosts.contains(parsed.host) else { return .failure(.hostNotApproved) }
        return .success(parsed.url)
    }

    // MARK: - Parsing

    private struct ParsedHTTPSURL {
        let url: URL
        /// Lowercased host from the raw authority.
        let host: String
        let port: Int?
    }

    /// Parses the raw authority itself (rather than trusting a lenient URL parser) and rejects
    /// ambiguous forms: userinfo, backslashes, bracketed hosts, non-printable or non-ASCII bytes.
    private static func parseHTTPS(_ text: String) -> ParsedHTTPSURL? {
        let bytes = Array(text.utf8)
        let schemePrefix = Array("https://".utf8)
        guard bytes.count > schemePrefix.count,
              bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E && $0 != UInt8(ascii: "\\") }),
              zip(bytes, schemePrefix).allSatisfy({ pair in lowercasedASCII(pair.0) == pair.1 })
        else { return nil }

        let afterScheme = bytes[schemePrefix.count...]
        let authorityEnd = afterScheme.firstIndex(where: {
            $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#")
        }) ?? bytes.endIndex
        let authority = Array(bytes[schemePrefix.count ..< authorityEnd])
        guard !authority.isEmpty, !authority.contains(UInt8(ascii: "@")) else { return nil }

        var hostBytes = authority
        var port: Int?
        if let colon = authority.firstIndex(of: UInt8(ascii: ":")) {
            let portBytes = authority[(colon + 1)...]
            guard (1 ... 5).contains(portBytes.count), portBytes.allSatisfy(isDigit),
                  let value = Int(String(decoding: portBytes, as: UTF8.self)), (1 ... 65535).contains(value)
            else { return nil }
            port = value
            hostBytes = Array(authority[..<colon])
        }
        let host = String(decoding: hostBytes.map(lowercasedASCII), as: UTF8.self)
        guard !host.isEmpty,
              host.utf8.allSatisfy(isHostByte),
              let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.host?.lowercased() == host,
              url.port == port
        else { return nil }
        return ParsedHTTPSURL(url: url, host: host, port: port)
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard let first = label.utf8.first, let last = label.utf8.last,
              label.utf8.count <= maxLabelBytes
        else { return false }
        return first != UInt8(ascii: "-") && last != UInt8(ascii: "-")
    }

    private static func isHostByte(_ byte: UInt8) -> Bool {
        isLowercaseLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
    }
}
