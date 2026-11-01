import Darwin
import Foundation
import RepoPromptRemoteWire

/// A canonical, validated browser origin for a WebAuthn ceremony.
///
/// Built **only** from the app's own published HTTPS launch configuration — never from a request
/// `Host`, a forwarded header, the direct gateway discovery address, or any client input. The
/// scheme is required to be `https` and the host is required to be a DNS name (an IPv4/IPv6 literal
/// is rejected), so `rpID` is always a usable WebAuthn Relying Party ID.
struct RemotePasskeyOrigin: Equatable {
    /// Lowercased DNS hostname, without port. Also the WebAuthn RP ID.
    let host: String
    /// Effective TCP port (defaults to 443 when omitted).
    let port: Int

    /// Serialized origin: `https://host` when the port is 443, otherwise `https://host:port`.
    /// Matches the serialization a browser reports in `clientDataJSON.origin`.
    var serialized: String {
        port == 443 ? "https://\(host)" : "https://\(host):\(port)"
    }

    /// WebAuthn Relying Party ID — the origin's hostname without port.
    var rpID: String {
        host
    }

    /// Fails when the scheme is not `https`, the host is empty or an IP literal, or the port is out
    /// of range.
    init?(scheme: String, host: String, port: Int?) {
        guard scheme.lowercased() == "https" else { return nil }
        let loweredHost = host.lowercased()
        guard RemotePasskeyOrigin.isDNSHostname(loweredHost) else { return nil }
        let effectivePort = port ?? 443
        guard (1 ... 65535).contains(effectivePort) else { return nil }
        self.host = loweredHost
        self.port = effectivePort
    }

    /// Build from the app's published browser-launch origin. This is the ONLY production source:
    /// it comes from `RemoteGatewayStatusStore.activeBrowserOrigin`, never from a request header or
    /// client input. Returns nil unless the origin is `https` with a DNS hostname.
    init?(_ gateway: RemoteGatewayOrigin) {
        self.init(scheme: gateway.scheme, host: gateway.host, port: gateway.port == 0 ? nil : gateway.port)
    }

    /// Convenience parser for a full `https://host[:port]` string.
    init?(httpsURLString: String) {
        guard let components = URLComponents(string: httpsURLString),
              let scheme = components.scheme,
              let host = components.host,
              components.user == nil,
              components.password == nil
        else { return nil }
        self.init(scheme: scheme, host: host, port: components.port)
    }

    /// A DNS hostname is required: reject empty strings, IPv6 literals (contain `:` / brackets) and
    /// IPv4 literals (parse successfully via `inet_pton`).
    static func isDNSHostname(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        guard !host.contains(":"), !host.contains("["), !host.contains("]") else { return false }

        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return false
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return false
        }
        return true
    }
}
