import Foundation
import MCP
import RepoPromptAgentCore

/// `present_rich` execution (docs/context/specs/2026-11-04-rich-presentation-spec.md, Step 4).
///
/// trusted request metadata → exact attempt authority (`RichPresentationMCPAuthorityResolver`)
/// → the D2 storage agreement (refused before anything is saved or written) → the exact owner's
/// persistence authority (`ensureRichPublicationPersistence`) →
/// `RichPresentationPublicationService.publish` → the canonical `{"presentation": Reference}`
/// text result. Tool arguments never establish the window, tab, workspace, session or storage.
///
/// Admission: `present_rich` runs on the connection's control lane and holds no window-wide
/// mutation lease (`MCPToolAdmissionPolicy`). The exact owner's save runs before publication
/// admission, so it is not bounded by the two publication slots. Safety comes from the
/// transaction itself: the exact-attempt authority above, `publish` re-resolution and its
/// app-wide two-slot admission, the session persistence gate and rich-artifact filesystem fence,
/// and the final MainActor attempt/root check with the install. A valid save that completes
/// before a later root or attempt change stays saved; publication then refuses.
@MainActor
struct RichPresentationMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata

    let captureRequestMetadata: @MainActor () async -> RequestMetadata
    var resolver: RichPresentationMCPAuthorityResolver = .live
    var publicationService: @MainActor () -> RichPresentationPublicationService = { .shared }

    func execute(args: [String: Value]) async throws -> Value {
        let metadata = await captureRequestMetadata()
        do {
            let authority = try await resolver.resolve(metadata: metadata).get()
            guard let window = resolver.windows().first(where: { $0.windowID == authority.windowID }),
                  let workspace = window.workspaceManager.workspaces.first(where: { $0.id == authority.workspaceID })
            else {
                throw RichPresentationMCPAuthorityResolver.Denial.invalidContext(
                    RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage
                )
            }
            let viewModel = window.agentModeViewModel
            // D2 refuses before the owner save, so a refused call saves and writes nothing.
            _ = try RichPresentationPublicationService.currentAgreedStorageRoot(
                workspaceID: workspace.id, dataService: viewModel.dataService, workspaceManager: window.workspaceManager
            )
            let state = try await viewModel.ensureRichPublicationPersistence(authority: authority, resolver: resolver)
            let data = try JSONEncoder().encode(Value.object(args))
            let reference = try await publicationService().publish(
                data: data,
                metadata: metadata,
                resolver: resolver,
                dataService: viewModel.dataService,
                workspace: workspace,
                state: state,
                workspaceManager: window.workspaceManager
            )
            return try Value(RichPresentationResult(presentation: reference))
        } catch let error as CancellationError {
            throw error
        } catch let error as MCPError {
            throw error
        } catch let denial as RichPresentationMCPAuthorityResolver.Denial {
            throw MCPError.invalidParams(denial.message)
        } catch let error as RichPresentationValidationError {
            throw MCPError.invalidParams("present_rich input is invalid: \(error.description) Nothing was created.")
        } catch let error as AgentRichArtifactError {
            // Each case names its cause and the correction (retry, settings, reopen or text).
            throw MCPError.invalidParams(error.errorDescription ?? Self.unexpectedFailureMessage(String(describing: error)))
        } catch let error as LocalizedError {
            throw MCPError.invalidParams(Self.unexpectedFailureMessage(error.errorDescription ?? String(describing: error)))
        } catch {
            throw MCPError.invalidParams(Self.unexpectedFailureMessage(String(describing: error)))
        }
    }

    /// A failure without a rich-presentation cause (for example a local file error). The existing
    /// MCP error envelope is kept; the text names the cause and says not to resend blindly.
    static func unexpectedFailureMessage(_ cause: String) -> String {
        "present_rich could not finish: \(cause) No presentation was shown for this call. "
            + "Check this transcript before calling present_rich again instead of resending the same call, "
            + "and continue in text if the cause persists."
    }
}
