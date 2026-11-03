//
//  AgentMessage.swift
//  RepoPrompt
//
//  Minimal message struct for headless agent providers.
//  Unlike AIMessage (legacy chat system with XML formatting, prompt sections, etc.),
//  this contains only what headless agents actually need.
//

import Foundation

/// A minimal message for headless agent providers.
/// Contains just the system prompt channel and user message channel.
public struct AgentMessage: Sendable, Equatable {
    /// System prompt / instructions for the agent
    public var systemPrompt: String

    /// The user's message / task
    public var userMessage: String

    /// Optional provider-specific session ID for resuming conversations
    /// Used by Claude CLI to resume with --resume <session-id> instead of replaying history
    public var resumeSessionID: String?

    /// The managed session (lifecycle and run attempt) this message's provider run serves, or
    /// explicit sessionless work (Context Builder, chat providers). Fail-closed default: a managed
    /// launch for a message that never set it is refused under runtime registration (R6).
    package var runtimeSession: AgentRuntimeSessionScope = .unavailable

    public init(systemPrompt: String = "", userMessage: String, resumeSessionID: String? = nil) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.resumeSessionID = resumeSessionID
    }

    /// The same message bound to `runtimeSession`.
    package func withRuntimeSession(_ runtimeSession: AgentRuntimeSessionScope) -> AgentMessage {
        var message = self
        message.runtimeSession = runtimeSession
        return message
    }
}
