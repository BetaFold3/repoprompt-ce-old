import Foundation
import RepoPromptPlatform
import RepoPromptRemoteWire

package enum TailscaleStatusError: Error, Equatable, LocalizedError {
    case commandUnavailable(String)
    case processFailed(status: Int32, message: String)
    case timedOut
    case cancelled
    case outputTooLarge
    case invalidJSON
    case backendUnavailable(String)
    case missingSelf
    case noEligibleSelfIPv4
    case invalidAddress(String)

    package var errorDescription: String? {
        switch self {
        case let .commandUnavailable(message):
            "Tailscale CLI is unavailable: \(message)"
        case let .processFailed(status, message):
            "tailscale status failed (\(status)): \(message)"
        case .timedOut:
            "Tailscale status timed out after 5 seconds."
        case .cancelled:
            "Tailscale status was cancelled."
        case .outputTooLarge:
            "Tailscale status output exceeded 2 MiB."
        case .invalidJSON:
            "Tailscale returned malformed status JSON."
        case let .backendUnavailable(state):
            "Tailscale is not ready (\(state))."
        case .missingSelf:
            "Tailscale status did not include this Mac."
        case .noEligibleSelfIPv4:
            "This Mac has no eligible Tailscale IPv4 address."
        case let .invalidAddress(value):
            "Tailscale returned an invalid address: \(value)."
        }
    }
}

struct TailscaleNode: Equatable {
    let id: String?
    let hostName: String?
    let dnsName: String?
    let tailscaleIPs: [String]
    let online: Bool?

    var displayName: String {
        let dns = dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return [dns, hostName, id]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Tailscale peer"
    }

    var eligibleIPv4s: [String] {
        tailscaleIPs
            .filter(RemoteGatewayOrigin.isTailscaleIPv4)
            .sorted {
                (RemoteGatewayOrigin.numericIPv4SortKey($0) ?? .max)
                    < (RemoteGatewayOrigin.numericIPv4SortKey($1) ?? .max)
            }
    }
}

package struct TailscaleStatusSnapshot: Equatable {
    let backendState: String?
    let selfNode: TailscaleNode
    let peers: [TailscaleNode]

    package var selectedSelfIPv4: String? {
        selfNode.eligibleIPv4s.first
    }

    /// This Mac's MagicDNS name (`Self.DNSName`) without the trailing dot, lowercased; nil when
    /// Tailscale reports none.
    package var selfDNSName: String? {
        let trimmed = selfNode.dnsName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var visiblePeers: [TailscaleNode] {
        peers
            .filter { $0.online != false && !$0.eligibleIPv4s.isEmpty }
            .sorted {
                let left = $0.eligibleIPv4s.first ?? ""
                let right = $1.eligibleIPv4s.first ?? ""
                let leftKey = RemoteGatewayOrigin.numericIPv4SortKey(left) ?? .max
                let rightKey = RemoteGatewayOrigin.numericIPv4SortKey(right) ?? .max
                if leftKey == rightKey { return $0.displayName < $1.displayName }
                return leftKey < rightKey
            }
    }
}

package struct TailscaleDiscoveryCandidate: Hashable {
    let peerID: String?
    let peerDisplayName: String
    let peerDNSName: String?
    let peerIPv4: String
    let channel: RemoteControlBuildChannel
    let origin: RemoteGatewayOrigin
}

package protocol TailscaleStatusProviding: Sendable {
    func status() async throws -> TailscaleStatusSnapshot
}

enum TailscaleCommandResolver {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledExecutablePath: String = CLILaunchProfiles.tailscaleAppBundleExecutablePath,
        additionalSearchPaths: [String] = CLILaunchProfiles.tailscale.supplementalSearchPaths
    ) -> String? {
        let expandedBundlePath = CommandPathResolver.expandPath(bundledExecutablePath, environment: environment)
        if CommandPathResolver.launchability(of: expandedBundlePath) == .launchable {
            return expandedBundlePath
        }

        let resolved = CommandPathResolver.resolve(
            CLILaunchProfiles.tailscale.commandName,
            environment: environment,
            additionalPaths: additionalSearchPaths,
            preferredBasenames: CLILaunchProfiles.tailscale.preferredBasenames,
            shellLookupMode: .disabled
        )
        guard CommandPathResolver.launchability(of: resolved) == .launchable else { return nil }
        return resolved
    }
}

package struct TailscaleStatusClient: TailscaleStatusProviding {
    static let timeout: TimeInterval = 5
    static let maximumCombinedOutputBytes = 2 * 1024 * 1024
    static let maximumCandidates = 256

    package typealias Run = @Sendable () async throws -> CLIProcessRunner.Result

    private let run: Run

    package init(run: @escaping Run = TailscaleStatusClient.runCLI) {
        self.run = run
    }

    package func status() async throws -> TailscaleStatusSnapshot {
        let result: CLIProcessRunner.Result
        do {
            result = try await run()
        } catch is CancellationError {
            throw TailscaleStatusError.cancelled
        } catch let error as TailscaleStatusError {
            throw error
        } catch let error as CLIProcessRunnerError {
            throw TailscaleStatusError.commandUnavailable(error.localizedDescription)
        } catch {
            throw TailscaleStatusError.commandUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()
        if result.timedOut { throw TailscaleStatusError.timedOut }
        guard result.stdout.count + result.stderr.count <= Self.maximumCombinedOutputBytes else {
            throw TailscaleStatusError.outputTooLarge
        }
        guard result.status == 0 else {
            let message = String(decoding: result.stderr.suffix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TailscaleStatusError.processFailed(status: result.status, message: message)
        }
        return try Self.decode(result.stdout)
    }

    func candidates() async throws -> [TailscaleDiscoveryCandidate] {
        let snapshot = try await status()
        var candidates: [TailscaleDiscoveryCandidate] = []
        var seen: Set<String> = []
        for peer in snapshot.visiblePeers {
            for ip in peer.eligibleIPv4s {
                for channel in RemoteControlBuildChannel.allCases {
                    let key = "\(ip):\(channel.rawValue)"
                    guard seen.insert(key).inserted else { continue }
                    let origin = try RemoteGatewayOrigin(tailscaleIPv4: ip, channel: channel)
                    candidates.append(TailscaleDiscoveryCandidate(
                        peerID: peer.id,
                        peerDisplayName: peer.displayName,
                        peerDNSName: peer.dnsName,
                        peerIPv4: ip,
                        channel: channel,
                        origin: origin
                    ))
                    if candidates.count == Self.maximumCandidates {
                        return candidates
                    }
                }
            }
        }
        return candidates
    }

    static func decode(_ data: Data) throws -> TailscaleStatusSnapshot {
        let document: StatusDocument
        do {
            document = try JSONDecoder().decode(StatusDocument.self, from: data)
        } catch {
            throw TailscaleStatusError.invalidJSON
        }
        if let backend = document.backendState,
           backend.lowercased() != "running"
        {
            throw TailscaleStatusError.backendUnavailable(backend)
        }
        guard let selfNode = document.selfNode else {
            throw TailscaleStatusError.missingSelf
        }
        let resolvedSelf = selfNode.model
        guard resolvedSelf.eligibleIPv4s.first != nil else {
            throw TailscaleStatusError.noEligibleSelfIPv4
        }
        return TailscaleStatusSnapshot(
            backendState: document.backendState,
            selfNode: resolvedSelf,
            peers: (document.peers ?? [:]).values.map(\.model)
        )
    }

    private static func runCLI() async throws -> CLIProcessRunner.Result {
        guard let command = TailscaleCommandResolver.resolve() else {
            throw TailscaleStatusError.commandUnavailable("No executable was found in the Tailscale app bundle, Homebrew locations, or PATH.")
        }
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: command,
            additionalPaths: [],
            resolveCandidates: ["Tailscale", "tailscale"],
            shellLookupMode: .disabled,
            captureStdoutTailBytes: Self.maximumCombinedOutputBytes,
            captureStderrTailBytes: Self.maximumCombinedOutputBytes
        ))
        let stream = try await runner.runStreaming(
            args: ["status", "--json"],
            stdin: nil,
            outputMode: .none,
            timeout: Self.timeout
        )
        var stdout = Data()
        var stderr = Data()
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case let .stdout(chunk):
                guard stdout.count + stderr.count + chunk.count <= Self.maximumCombinedOutputBytes else {
                    throw TailscaleStatusError.outputTooLarge
                }
                stdout.append(chunk)
            case let .stderr(chunk):
                guard stdout.count + stderr.count + chunk.count <= Self.maximumCombinedOutputBytes else {
                    throw TailscaleStatusError.outputTooLarge
                }
                stderr.append(chunk)
            case let .terminated(status, timedOut, resolvedCommand):
                return CLIProcessRunner.Result(
                    stdout: stdout,
                    stderr: stderr,
                    status: status,
                    timedOut: timedOut,
                    resolvedCommand: resolvedCommand
                )
            }
        }
        throw TailscaleStatusError.processFailed(status: -1, message: "process ended without termination status")
    }
}

private struct StatusDocument: Decodable {
    let backendState: String?
    let selfNode: StatusNode?
    let peers: [String: StatusNode]?

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case selfNode = "Self"
        case peers = "Peer"
    }
}

private struct StatusNode: Decodable {
    let id: String?
    let hostName: String?
    let dnsName: String?
    let tailscaleIPs: [String]?
    let online: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case hostName = "HostName"
        case dnsName = "DNSName"
        case tailscaleIPs = "TailscaleIPs"
        case online = "Online"
    }

    var model: TailscaleNode {
        TailscaleNode(
            id: id,
            hostName: hostName,
            dnsName: dnsName,
            tailscaleIPs: tailscaleIPs ?? [],
            online: online
        )
    }
}
