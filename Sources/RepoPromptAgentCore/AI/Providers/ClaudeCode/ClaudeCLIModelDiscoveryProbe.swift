import CryptoKit
import Foundation
import RepoPromptPlatform

/// Initialization only: never sends a user message or performs model inference.
package enum ClaudeCLIModelDiscoveryProbe {
    struct Result: Equatable {
        let modelIDs: [String]
        let scope: String?
    }

    enum Failure: Error {
        case unavailable
        case invalidResponse
        case invalidModels(scope: String?)
        case unsupportedBackend
        case timedOut
    }

    package static let maximumOutputBytes = 1_048_576
    static let requestID = "rpce-model-discovery"
    static let input = "{\"type\":\"control_request\",\"request_id\":\"rpce-model-discovery\",\"request\":{\"subtype\":\"initialize\"}}\n"
    static let arguments = [
        "--print", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--tools", "", "--no-session-persistence"
    ]

    static func run(
        config originalConfig: CLIProcessConfiguration,
        launchAuthority: AgentRuntimeLaunchAuthority = .production
    ) async throws -> Result {
        var config = originalConfig
        config.captureStdoutTailBytes = maximumOutputBytes
        config.captureStderrTailBytes = 8192
        config.enableDebugLogging = false
        config.logCollector = nil
        config.logStdinSampleBytes = 0
        // Match the standard launch environment, not a compatible backend's injected credentials.
        let environment = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(purpose: .cliRunner, overrides: config.environment)
        ).environment
        guard isFirstPartyEnvironment(environment) else { throw Failure.unsupportedBackend }
        config.environment = environment
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptCE-ClaudeModels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        config.workingDirectory = root.path
        let runner = CLIProcessRunner(config: config)
        // R6: a managed control start — its own sessionless runtime (`--no-session-persistence`, a
        // private temporary directory, so no worktree or conversation key), reserved before the
        // spawn and committed before the initialize write. Nil while registration is off.
        // First-party only (checked above): the standard Claude provider; no permission request.
        let launch = launchAuthority.makeLaunch(AgentRuntimeLaunchContext(
            family: .claudeHeadless,
            provider: .claude(.standard),
            session: .sessionless,
            worktreePath: nil,
            permission: .unavailable
        ))
        do {
            let result = try await runner.run(
                args: arguments, stdin: input, outputMode: .none, timeout: 15,
                // Managed launch boundary: an inherited runtime marker never reaches the child.
                additionalRemovedKeys: ["CLAUDECODE", ProcessLauncher.runtimeMarkerEnvironmentKey],
                cancelChildOnTaskCancellation: true,
                launchOwnership: launch
            )
            await runner.cancelAll()
            try Task.checkCancellation()
            guard !result.timedOut else { throw Failure.timedOut }
            guard result.status == 0 else { throw Failure.unavailable }
            return try decode(result.stdout, executable: result.resolvedCommand)
        } catch {
            await runner.cancelAll()
            throw error
        }
    }

    static func isFirstPartyEnvironment(_ environment: [String: String]) -> Bool {
        if let base = environment["ANTHROPIC_BASE_URL"], !base.isEmpty,
           base != "https://api.anthropic.com", base != "https://api.anthropic.com/"
        { return false }
        return ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
            .allSatisfy { environment[$0] == nil || environment[$0] == "" || environment[$0] == "0" }
    }

    static func decode(_ data: Data, executable: String) throws -> Result {
        // At the capture limit, even a parseable tail cannot prove completeness.
        guard data.count < maximumOutputBytes,
              let text = String(data: data, encoding: .utf8)
        else { throw Failure.invalidResponse }
        var payload: [String: Any]?
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any],
                  response["request_id"] as? String == requestID
            else { continue }
            guard payload == nil, response["subtype"] as? String == "success",
                  let body = response["response"] as? [String: Any]
            else { throw Failure.invalidResponse }
            payload = body
        }
        guard let payload, let account = payload["account"] as? [String: Any],
              let provider = account["apiProvider"] as? String, !provider.isEmpty
        else { throw Failure.invalidResponse }
        guard provider == "firstParty" else { throw Failure.unsupportedBackend }
        let scope = try accountScope(account, executable: executable)
        guard let rows = payload["models"] as? [[String: Any]], rows.count <= 1024
        else { throw Failure.invalidModels(scope: scope) }

        var ids = Set<String>()
        for row in rows {
            guard let value = row["value"] as? String, validIdentifier(value) else {
                throw Failure.invalidModels(scope: scope)
            }
            let identifier: String
            if let resolved = row["resolvedModel"] {
                guard let resolved = resolved as? String, validIdentifier(resolved) else {
                    throw Failure.invalidModels(scope: scope)
                }
                identifier = resolved
            } else {
                identifier = value
            }
            // Never infer concrete IDs from names/descriptions or rescue an unsupported resolved ID.
            if ClaudeModelFamilyCatalog.cliPointRelease(identifier) != nil {
                ids.insert(identifier)
            }
        }

        return Result(modelIDs: ids.sorted(), scope: scope)
    }

    private static func accountScope(_ account: [String: Any], executable: String) throws -> String? {
        let scope: String?
        if let email = account["email"] as? String, !email.isEmpty,
           let organization = account["organization"] as? String, !organization.isEmpty
        {
            let identity = [
                URL(fileURLWithPath: executable).resolvingSymlinksInPath().path,
                email, organization
            ]
            let encoded = try JSONEncoder().encode(identity)
            scope = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        } else {
            // An unidentified account may supply this run's list, but never a durable cache.
            scope = nil
        }
        return scope
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}
