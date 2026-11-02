import Combine
import Foundation
import RepoPromptAgentCore
#if DEBUG
    import OSLog
#endif

@MainActor
final class AgentComposerUIStore: ObservableObject {
    @Published private(set) var props: AgentComposerProps
    @Published private(set) var focusRequest: AgentComposerFocusRequest?
    @Published private(set) var revision: UInt64 = 0

    init(props: AgentComposerProps = .empty) {
        self.props = props
    }

    func requestFocus(_ request: AgentComposerFocusRequest) {
        #if DEBUG
            Logger(subsystem: "com.repoprompt.app", category: "composer-focus").debug(
                "request token=\(request.id.uuidString, privacy: .public) reason=\(String(describing: request.reason), privacy: .public)"
            )
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            AgentInteractionLatencyProbe.composerFocusRequested(requestID: request.id, tabID: request.tabID)
        #endif
        focusRequest = request
    }

    func consumeFocusRequest(id: UUID) {
        guard focusRequest?.id == id else { return }
        focusRequest = nil
    }

    func update(_ nextProps: AgentComposerProps) {
        guard props != nextProps else {
            #if DEBUG
                AgentModePerfDiagnostics.recordStoreUpdate("composer", published: false)
            #endif
            return
        }
        props = nextProps
        revision &+= 1
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate("composer", published: true, details: ["revision": String(revision)])
        #endif
    }
}
