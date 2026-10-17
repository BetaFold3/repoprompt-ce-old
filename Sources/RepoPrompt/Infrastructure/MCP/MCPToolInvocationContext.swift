import Foundation
import MCP
import RepoPromptAgentCore

/// Where one `tools/call` invocation entered the connection's registered handler (plan §6 D3
/// dispatch). Wire calls are `.transport`; in-process `code_mode` children re-enter the same
/// registered closure with `.codeModeChild`. Never derived from arguments or client identity.
enum MCPToolInvocationOrigin: Equatable {
    case transport
    case codeModeChild(parentInvocationID: UUID)

    var isCodeModeChild: Bool {
        if case .codeModeChild = self { return true }
        return false
    }
}

/// Typed result of one in-process child invocation: the provider value captured at the shared
/// handler's final formatting boundary (nil for every denial, lookup failure, or returned error),
/// plus the exact `CallTool.Result` the handler returned. Independent of structured results (D1).
struct MCPInProcessToolResult {
    let value: Value?
    let result: CallTool.Result
    /// Set only when the handler converted a thrown provider error that is a typed POSIX EINTR or
    /// EAGAIN (directly or as a bounded `NSUnderlyingErrorKey` chain) into its error result. Never
    /// derived from error text; never on the wire.
    let transientPOSIXCode: POSIXErrorCode?

    init(value: Value?, result: CallTool.Result, transientPOSIXCode: POSIXErrorCode? = nil) {
        self.value = value
        self.result = result
        self.transientPOSIXCode = transientPOSIXCode
    }

    /// Typed transient classification of a thrown provider error. Cancellation is never transient.
    static func transientPOSIXCode(of error: Error) -> POSIXErrorCode? {
        guard !(error is CancellationError) else { return nil }
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 4 {
            if nsError.domain == NSPOSIXErrorDomain,
               let code = POSIXErrorCode(rawValue: Int32(truncatingIfNeeded: nsError.code)),
               code == .EINTR || code == .EAGAIN
            {
                return code
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}

/// Invocation-owned capture for one in-process child call. Never reused or shared: the re-entry
/// helper creates one per invocation and installs it as a task local.
final class MCPInProcessToolResultSink: @unchecked Sendable {
    enum InvariantError: Error, Equatable {
        case alreadyCaptured
        case alreadyClosed
    }

    private let lock = NSLock()
    private var capturedValue: Value?
    private var didCapture = false
    private var isClosed = false
    private var transientPOSIXCode: POSIXErrorCode?

    /// Records the sanitized successful provider value. A second capture, or a capture after
    /// completion or abandonment, is an invariant failure and never overwrites.
    @discardableResult
    func capture(_ value: Value) -> Result<Void, InvariantError> {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return .failure(.alreadyClosed) }
        guard !didCapture else { return .failure(.alreadyCaptured) }
        didCapture = true
        capturedValue = value
        return .success(())
    }

    /// Records that the handler is returning an error result for a thrown typed transient POSIX
    /// error. Ignored after completion or abandonment.
    func recordTransientFailure(_ code: POSIXErrorCode) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        transientPOSIXCode = code
    }

    /// Combines the capture with the handler's returned result, once, and releases the capture.
    func complete(with result: CallTool.Result) -> Result<MCPInProcessToolResult, InvariantError> {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return .failure(.alreadyClosed) }
        isClosed = true
        let value = capturedValue
        capturedValue = nil
        // Only an error result can carry the transient disposition.
        let transient = result.isError == true ? transientPOSIXCode : nil
        transientPOSIXCode = nil
        return .success(MCPInProcessToolResult(value: value, result: result, transientPOSIXCode: transient))
    }

    /// Releases any capture when the handler threw. Idempotent.
    func abandon() {
        lock.lock()
        isClosed = true
        capturedValue = nil
        transientPOSIXCode = nil
        lock.unlock()
    }
}

/// Child-ingress rules for in-process `code_mode` children (plan §6 D3 allowlist and dispatch).
enum MCPCodeModeChildIngress {
    static let allowedToolNames: Set<String> = [
        MCPWindowToolName.readFile,
        MCPWindowToolName.search,
        MCPWindowToolName.getCodeStructure,
        MCPWindowToolName.getFileTree
    ]

    /// Routing overrides a child may never supply, even as explicit null: the hidden routing
    /// fields and the public `window_id`. Checked at top level here and, after normalization,
    /// through `NormalizedArgs.encounteredRoutingKeys` for wrapped/nested/JSON-string forms.
    static let forbiddenRoutingArgumentKeys = MCPToolArgsNormalizer.routingOverrideKeys

    /// Nil when the child call may proceed; otherwise the denial code and message.
    static func denial(
        canonicalToolName: String,
        admissionClass: MCPToolAdmissionClass?,
        arguments: [String: Value]?
    ) -> (code: String, message: String)? {
        guard allowedToolNames.contains(canonicalToolName) else {
            return ("code_mode_child_tool_not_allowed", "Tool '\(canonicalToolName)' is not available inside code_mode.")
        }
        switch admissionClass {
        case .smallRead?, .fileSearch?:
            break
        default:
            return (
                "code_mode_child_admission_not_allowed",
                "Tool '\(canonicalToolName)' is not classified as a small read or file search."
            )
        }
        if let arguments, !forbiddenRoutingArgumentKeys.isDisjoint(with: arguments.keys) {
            return routingOverrideDenial
        }
        return nil
    }

    static let routingOverrideDenial = (
        code: "code_mode_child_routing_override",
        message: "code_mode children may not override routing (context_id, _tabID, _windowID, window_id)."
    )

    /// The `code_mode` call itself may not carry routing either (null, wrapped, or nested forms
    /// included): the script runs in the connection's bound context, chosen with `bind_context`.
    static let parentRoutingOverrideDenial = (
        code: "code_mode_routing_override",
        message: "code_mode cannot be routed (context_id, _tabID, _windowID, window_id). It runs in this connection's bound context; call bind_context first to choose a different context, then call code_mode without routing arguments."
    )

    /// The value a child hands back: the reserved delegated-question notice field never enters
    /// child data, structured content, or text.
    static func sanitized(_ value: Value) -> Value {
        guard case var .object(object) = value,
              object.removeValue(forKey: AgentDelegatedQuestionNoticeWire.resultKey) != nil
        else {
            return value
        }
        return .object(object)
    }
}
