import Foundation
import NIOCore
import NIOHTTP1

/// DNS-rebinding guard for the gateway's HTTP routes and WebSocket upgrade. A request is
/// served only when its single `Host` header names the address the client actually connected
/// to (the bind host or the accepted socket's local `ip:port`) or the configured browser HTTPS
/// origin's authority. Forwarded headers (`X-Forwarded-Host`, `Forwarded`) are never consulted.
struct GatewayHostAllowlist: Equatable {
    let authorities: Set<String>

    /// `localAddress` is the accepted connection's local address, so an ephemeral (`--port 0`)
    /// or wildcard bind still allows exactly the address that was dialed.
    init(configuration: GatewayConfiguration, localAddress: SocketAddress?) {
        let port = localAddress?.port ?? configuration.port
        var authorities: Set<String> = [Self.authority(host: configuration.bindHost, port: port)]
        if let localIP = localAddress?.ipAddress {
            authorities.insert(Self.authority(host: localIP, port: port))
        }
        if let browserAuthority = configuration.browserOriginAuthority {
            authorities.insert(browserAuthority)
        }
        self.authorities = authorities
    }

    func allows(_ head: HTTPRequestHead) -> Bool {
        let values = head.headers["Host"]
        guard values.count == 1 else { return false }
        return authorities.contains(values[0].trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Lowercased `host:port`; IPv6 literals are bracketed as they appear in a Host header.
    static func authority(host: String, port: Int) -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hostPart = normalized.contains(":") && !normalized.hasPrefix("[") ? "[\(normalized)]" : normalized
        return "\(hostPart):\(port)"
    }
}
