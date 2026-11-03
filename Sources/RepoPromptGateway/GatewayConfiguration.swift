import Foundation
import RepoPromptRemoteWire
import RepoPromptShared

struct GatewayConfiguration: Equatable {
    static let defaultBindHost = "127.0.0.1"
    static let defaultPort = 47391

    enum EnvironmentKey {
        static let bindHost = "REPOPROMPT_GATEWAY_BIND_HOST"
        static let port = "REPOPROMPT_GATEWAY_PORT"
        static let staticToken = "REPOPROMPT_GATEWAY_STATIC_TOKEN"
        static let tlsCertPath = "REPOPROMPT_GATEWAY_TLS_CERT_PATH"
        static let tlsKeyPath = "REPOPROMPT_GATEWAY_TLS_KEY_PATH"
        static let auditDirectory = "REPOPROMPT_GATEWAY_AUDIT_DIR"
        static let appSupportRoot = "REPOPROMPT_GATEWAY_APP_SUPPORT_ROOT"
        static let bootstrapToken = "REPOPROMPT_GATEWAY_BOOTSTRAP_TOKEN"
        static let bootstrapSocket = "REPOPROMPT_GATEWAY_BOOTSTRAP_SOCKET"
        static let appLegCredential = "REPOPROMPT_GATEWAY_APP_LEG_CREDENTIAL"
        static let parentPID = "REPOPROMPT_GATEWAY_PARENT_PID"
        static let processLeaseFile = "REPOPROMPT_GATEWAY_PROCESS_LEASE_FILE"
        static let appLinkMaximumReconnectAttempts = "REPOPROMPT_GATEWAY_APP_LINK_MAX_RECONNECT_ATTEMPTS"
        static let allowWildcardBind = "REPOPROMPT_GATEWAY_ALLOW_WILDCARD_BIND"
        static let allowStaticTokenAuth = "REPOPROMPT_GATEWAY_ALLOW_STATIC_TOKEN_AUTH"
        static let browserOrigin = "REPOPROMPT_GATEWAY_BROWSER_ORIGIN"
        static let passkeyPolicyVersion = "REPOPROMPT_GATEWAY_PASSKEY_POLICY_VERSION"
    }

    let bindHost: String
    let port: Int
    let staticToken: String?
    /// Reserved for a future in-process NIOSSL listener. Current v1 deployments
    /// terminate TLS externally (tailnet/tunnel/reverse proxy); these knobs are
    /// parsed for compatibility but not installed into the NIO pipeline yet.
    let tlsCertPath: String?
    /// Reserved with `tlsCertPath`; see the external-TLS note above.
    let tlsKeyPath: String?
    let auditDirectoryURL: URL
    let appSupportRootURL: URL
    let bootstrapSocketURL: URL
    let bootstrapToken: String
    let appLegCredential: String?
    let parentPID: Int32?
    let processLeaseFileURL: URL
    let appLinkMaximumReconnectAttempts: Int?
    let allowWildcardBind: Bool
    /// Phase 0 static-token WS auth is a developer-only escape hatch from M4 onward.
    /// Paired-device tickets are the normal remote path; this flag must be explicitly
    /// enabled for the static token to authorize a WebSocket hello.
    let allowStaticTokenAuth: Bool
    /// The build channel this gateway binary belongs to. It comes from the same compile-time
    /// flag as the app's `RemoteControlBuildIdentity.current`, so a gateway always reports its own
    /// app build. `/healthz` publishes it so a browser can pick the matching identity and discovery
    /// channel.
    let buildChannel: RemoteControlBuildChannel
    /// Lowercased `host:port` of the browser HTTPS origin (an owner-run `tailscale serve`
    /// listener forwarding here), accepted as a request Host besides the bind address. Nil when
    /// no browser origin was configured.
    let browserOriginAuthority: String?
    /// The remote-passkey policy wire version this gateway speaks. ONLY `1` is accepted. This is a
    /// compatibility guard, NOT an opt-in: a capable gateway always understands and enforces
    /// capability-1 trust snapshots regardless of this flag. The flag exists so a deployment can
    /// assert the version it expects and fail fast against an incompatible future projection.
    let passkeyPolicyVersion: Int

    /// The only passkey policy wire version this gateway build implements.
    static let supportedPasskeyPolicyVersion = 1

    static var compiledBuildChannel: RemoteControlBuildChannel {
        #if DEBUG
            .debug
        #else
            .release
        #endif
    }

    var listenAddressDescription: String {
        "\(bindHost):\(port)"
    }

    static func parse(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> GatewayConfiguration {
        var values = ParsedValues(environment: environment)
        try values.apply(arguments: arguments)

        let buildFlavor: MCPFilesystemIdentity.BuildFlavor
        #if DEBUG
            buildFlavor = .debug
        #else
            buildFlavor = .release
        #endif
        let identity = MCPFilesystemIdentity.repoPromptCE(buildFlavor)

        let appSupportRoot = values.appSupportRoot.map { URL(fileURLWithPath: $0) }
            ?? identity.applicationSupportRootURL(fileManager: fileManager)
        let auditDirectory = values.auditDirectory.map { URL(fileURLWithPath: $0) }
            ?? appSupportRoot
            .appendingPathComponent("RemoteGateway", isDirectory: true)
            .appendingPathComponent("audit", isDirectory: true)
        let bootstrapSocket = values.bootstrapSocket.map { URL(fileURLWithPath: $0) }
            ?? identity.bootstrapSocketURL()
        let bootstrapToken = values.bootstrapToken?.nilIfEmpty
            ?? "gateway-\(UUID().uuidString)"
        let bindHost = values.bindHost?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Self.defaultBindHost
        let port = try parsePort(values.port, defaultValue: Self.defaultPort)
        let parentPID = try parseOptionalInt32(values.parentPID, name: "parent PID")
        let processLeaseFile = values.processLeaseFile.map { URL(fileURLWithPath: $0) }
            ?? RemoteGatewayProcessLeaseFile.defaultURL(appSupportRoot: appSupportRoot)
        let appLinkMaximumReconnectAttempts = try parseOptionalPositiveInt(
            values.appLinkMaximumReconnectAttempts,
            name: "app link maximum reconnect attempts"
        ) ?? (parentPID == nil ? nil : 24)
        let allowWildcardBind = values.allowWildcardBind
        let browserOriginAuthority = try parseBrowserOriginAuthority(values.browserOrigin)
        let passkeyPolicyVersion = try parsePasskeyPolicyVersion(values.passkeyPolicyVersion)

        guard allowWildcardBind || !isWildcardBindHost(bindHost) else {
            throw GatewayConfigurationError.wildcardBindRequiresExplicitOptIn(bindHost)
        }

        return GatewayConfiguration(
            bindHost: bindHost,
            port: port,
            staticToken: values.staticToken?.nilIfEmpty,
            tlsCertPath: values.tlsCertPath?.nilIfEmpty,
            tlsKeyPath: values.tlsKeyPath?.nilIfEmpty,
            auditDirectoryURL: auditDirectory,
            appSupportRootURL: appSupportRoot,
            bootstrapSocketURL: bootstrapSocket,
            bootstrapToken: bootstrapToken,
            appLegCredential: values.appLegCredential?.nilIfEmpty,
            parentPID: parentPID,
            processLeaseFileURL: processLeaseFile,
            appLinkMaximumReconnectAttempts: appLinkMaximumReconnectAttempts,
            allowWildcardBind: allowWildcardBind,
            allowStaticTokenAuth: values.allowStaticTokenAuth,
            buildChannel: compiledBuildChannel,
            browserOriginAuthority: browserOriginAuthority,
            passkeyPolicyVersion: passkeyPolicyVersion
        )
    }

    /// Accepts an absent flag (defaults to the supported version) or an explicit value that must
    /// equal the supported version. Any other value fails fast.
    private static func parsePasskeyPolicyVersion(_ raw: String?) throws -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return supportedPasskeyPolicyVersion
        }
        guard let value = Int(raw), value == supportedPasskeyPolicyVersion else {
            throw GatewayConfigurationError.unsupportedPasskeyPolicyVersion(raw)
        }
        return value
    }

    /// Accepts only `https://host:port` with an explicit port and nothing else (no credentials,
    /// path, query, or fragment). Empty means unset.
    private static func parseBrowserOriginAuthority(_ raw: String?) throws -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let origin = try? RemoteGatewayOrigin(string: raw),
              origin.scheme == "https",
              !origin.host.isEmpty,
              (1 ... 65535).contains(origin.port)
        else {
            throw GatewayConfigurationError.invalidBrowserOrigin(raw)
        }
        return GatewayHostAllowlist.authority(host: origin.host, port: origin.port)
    }

    private static func parsePort(_ raw: String?, defaultValue: Int) throws -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultValue
        }
        // Port 0 requests an ephemeral bind (useful for tests and local tooling).
        guard let value = Int(raw), (0 ... 65535).contains(value) else {
            throw GatewayConfigurationError.invalidPort(raw)
        }
        return value
    }

    private static func parseOptionalInt32(_ raw: String?, name: String) throws -> Int32? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let value = Int32(raw), value > 0 else {
            throw GatewayConfigurationError.invalidInteger(name: name, value: raw)
        }
        return value
    }

    private static func parseOptionalPositiveInt(_ raw: String?, name: String) throws -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let value = Int(raw), value > 0 else {
            throw GatewayConfigurationError.invalidInteger(name: name, value: raw)
        }
        return value
    }

    static func isWildcardBindHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "0.0.0.0" || normalized == "::" || normalized == "[::]" || normalized == "*"
    }
}

enum GatewayConfigurationError: Error, Equatable, CustomStringConvertible {
    case unknownArgument(String)
    case missingArgumentValue(String)
    case invalidPort(String)
    case invalidInteger(name: String, value: String)
    case wildcardBindRequiresExplicitOptIn(String)
    case invalidBrowserOrigin(String)
    case unsupportedPasskeyPolicyVersion(String)

    var description: String {
        switch self {
        case let .unknownArgument(argument):
            "Unknown gateway argument: \(argument)"
        case let .missingArgumentValue(argument):
            "Missing value for gateway argument: \(argument)"
        case let .invalidPort(value):
            "Invalid gateway port: \(value)"
        case let .invalidInteger(name, value):
            "Invalid gateway \(name): \(value)"
        case let .wildcardBindRequiresExplicitOptIn(host):
            "Wildcard gateway bind host requires explicit opt-in: \(host)"
        case let .invalidBrowserOrigin(value):
            "Invalid gateway browser origin (expected https://host:port): \(value)"
        case let .unsupportedPasskeyPolicyVersion(value):
            "Unsupported gateway passkey policy version (only 1 is accepted): \(value)"
        }
    }
}

private struct ParsedValues {
    var bindHost: String?
    var port: String?
    var staticToken: String?
    var tlsCertPath: String?
    var tlsKeyPath: String?
    var auditDirectory: String?
    var appSupportRoot: String?
    var bootstrapToken: String?
    var bootstrapSocket: String?
    var appLegCredential: String?
    var parentPID: String?
    var processLeaseFile: String?
    var appLinkMaximumReconnectAttempts: String?
    var allowWildcardBind: Bool
    var allowStaticTokenAuth: Bool
    var browserOrigin: String?
    var passkeyPolicyVersion: String?

    init(environment: [String: String]) {
        bindHost = environment[GatewayConfiguration.EnvironmentKey.bindHost]
        port = environment[GatewayConfiguration.EnvironmentKey.port]
        staticToken = environment[GatewayConfiguration.EnvironmentKey.staticToken]
        tlsCertPath = environment[GatewayConfiguration.EnvironmentKey.tlsCertPath]
        tlsKeyPath = environment[GatewayConfiguration.EnvironmentKey.tlsKeyPath]
        auditDirectory = environment[GatewayConfiguration.EnvironmentKey.auditDirectory]
        appSupportRoot = environment[GatewayConfiguration.EnvironmentKey.appSupportRoot]
        bootstrapToken = environment[GatewayConfiguration.EnvironmentKey.bootstrapToken]
        bootstrapSocket = environment[GatewayConfiguration.EnvironmentKey.bootstrapSocket]
        appLegCredential = environment[GatewayConfiguration.EnvironmentKey.appLegCredential]
        parentPID = environment[GatewayConfiguration.EnvironmentKey.parentPID]
        processLeaseFile = environment[GatewayConfiguration.EnvironmentKey.processLeaseFile]
        appLinkMaximumReconnectAttempts = environment[GatewayConfiguration.EnvironmentKey.appLinkMaximumReconnectAttempts]
        allowWildcardBind = Self.parseBool(environment[GatewayConfiguration.EnvironmentKey.allowWildcardBind]) ?? false
        allowStaticTokenAuth = Self.parseBool(environment[GatewayConfiguration.EnvironmentKey.allowStaticTokenAuth]) ?? false
        browserOrigin = environment[GatewayConfiguration.EnvironmentKey.browserOrigin]
        passkeyPolicyVersion = environment[GatewayConfiguration.EnvironmentKey.passkeyPolicyVersion]
    }

    mutating func apply(arguments: [String]) throws {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--allow-wildcard-bind" {
                allowWildcardBind = true
                index = arguments.index(after: index)
                continue
            }
            if argument == "--allow-static-token-auth" {
                allowStaticTokenAuth = true
                index = arguments.index(after: index)
                continue
            }
            guard argument.hasPrefix("--") else {
                throw GatewayConfigurationError.unknownArgument(argument)
            }

            let key: String
            let value: String
            if let equalsIndex = argument.firstIndex(of: "=") {
                key = String(argument[..<equalsIndex])
                value = String(argument[argument.index(after: equalsIndex)...])
                index = arguments.index(after: index)
            } else {
                key = argument
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex else {
                    throw GatewayConfigurationError.missingArgumentValue(argument)
                }
                value = arguments[valueIndex]
                index = arguments.index(after: valueIndex)
            }

            switch key {
            case "--bind-host", "--host": bindHost = value
            case "--port": port = value
            case "--static-token": staticToken = value
            case "--tls-cert": tlsCertPath = value
            case "--tls-key": tlsKeyPath = value
            case "--audit-dir": auditDirectory = value
            case "--app-support-root": appSupportRoot = value
            case "--bootstrap-token": bootstrapToken = value
            case "--bootstrap-socket": bootstrapSocket = value
            case "--app-leg-credential": appLegCredential = value
            case "--parent-pid": parentPID = value
            case "--process-lease-file": processLeaseFile = value
            case "--app-link-max-reconnect-attempts": appLinkMaximumReconnectAttempts = value
            case "--browser-origin": browserOrigin = value
            case "--passkey-policy-version": passkeyPolicyVersion = value
            case "--allow-wildcard-bind":
                allowWildcardBind = Self.parseBool(value) ?? true
            case "--allow-static-token-auth":
                allowStaticTokenAuth = Self.parseBool(value) ?? true
            default:
                throw GatewayConfigurationError.unknownArgument(key)
            }
        }
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return nil
        }
        switch value {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
