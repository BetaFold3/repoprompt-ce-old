//
//  WorkspaceApprovalOverlayView.swift
//  RepoPrompt
//
//  Created by RepoPrompt – Workspace MCP approval integration
//

import SwiftUI

/// A full-screen takeover overlay for workspace operation approval requests.
/// Presents a modern, polished UI that blocks interaction until the user responds.
/// Aligned with MCPApprovalOverlayView for consistent UX.
struct WorkspaceApprovalOverlayView: View {
    @ObservedObject var approvalManager: WorkspaceApprovalManager
    @State private var alwaysAllow = false
    @State private var isAnimating = false
    @State private var pulseScale: CGFloat = 1.0

    let request: WorkspaceApprovalRequest

    var body: some View {
        ZStack {
            // Animated gradient background
            backgroundLayer

            // Content card
            approvalCard
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                isAnimating = true
            }
            // Start pulse animation
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseScale = 1.08
            }
        }
    }

    // MARK: - Background Layer

    private var backgroundLayer: some View {
        ZStack {
            // Dark overlay
            Color.black.opacity(0.5)

            // Subtle radial gradient from center (color based on risk level)
            RadialGradient(
                gradient: Gradient(colors: [
                    riskColor.opacity(0.15),
                    Color.clear
                ]),
                center: .center,
                startRadius: 100,
                endRadius: 400
            )
        }
        .opacity(isAnimating ? 1 : 0)
    }

    // MARK: - Approval Card

    private var approvalCard: some View {
        VStack(spacing: 0) {
            // Header with icon
            headerSection

            Divider()
                .background(Color.primary.opacity(0.1))

            // Main content
            contentSection

            Divider()
                .background(Color.primary.opacity(0.1))

            // Actions
            actionsSection
        }
        .frame(width: 440)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
        .scaleEffect(isAnimating ? 1 : 0.9)
        .opacity(isAnimating ? 1 : 0)
    }

    private var cardBackground: some View {
        ZStack {
            // Base material
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)

            // Subtle border
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Animated operation icon
            ZStack {
                // Outer pulse ring
                Circle()
                    .stroke(riskColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .scaleEffect(pulseScale)

                // Inner circle with icon
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                riskColor,
                                riskColor.opacity(0.8)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: riskColor.opacity(0.4), radius: 10)

                Image(systemName: request.operation.iconName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)

            Text(request.operation == .workspaceSteeringGrant ? "Workspace Steering Request" : "Workspace Operation Request")
                .font(.title2.weight(.semibold))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(spacing: 20) {
            // Client info card
            clientInfoCard

            // Operation details card
            operationDetailsCard

            // Risk warning
            riskWarningView

            // Always allow toggle (never offered for owner-only operations)
            if request.operation.allowsAutoApproval {
                alwaysAllowToggle
            }
        }
        .padding(24)
    }

    private var clientInfoCard: some View {
        HStack(spacing: 16) {
            // Client icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 48, height: 48)

                Image(systemName: clientIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let grant = request.steeringGrant {
                    // App-authored only: no client-reported name or agent text.
                    Text("An Agent Mode session in '\(grant.sourceWorkspaceName)'")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text("wants to \(request.operation.actionVerb) another workspace")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text(request.clientID)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text("wants to \(request.operation.actionVerb) a workspace")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var operationDetailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: request.operation.iconName)
                    .foregroundColor(riskColor)
                Text(request.operation.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
            }

            Text(request.detailedDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Show workspace name
            if let workspaceName = request.workspaceName {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("Workspace:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(workspaceName)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                }
                .padding(.top, 4)
            }

            if let grant = request.steeringGrant {
                steeringGrantRow(label: "From:", name: grant.sourceWorkspaceName, id: grant.sourceWorkspaceID)
                steeringGrantRow(label: "To:", name: grant.targetWorkspaceName, id: grant.targetWorkspaceID)
            }

            // Show folder path if applicable
            if let folderPath = request.folderPath {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text(folderPath)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(riskColor.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(riskColor.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var riskWarningView: some View {
        HStack(spacing: 10) {
            Image(systemName: riskIconName)
                .foregroundColor(riskColor)
                .font(.system(size: 14, weight: .medium))

            Text(request.warningMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func steeringGrantRow(label: String, name: String, id: UUID) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
                Text(id.uuidString)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 2)
    }

    private var clientIcon: String {
        // Fixed for owner-only requests: client-reported names never shape the steering prompt.
        if request.steeringGrant != nil {
            return "lock.shield"
        }
        let lowercased = request.clientID.lowercased()
        if lowercased.contains("claude") {
            return "brain"
        } else if lowercased.contains("cursor") {
            return "cursorarrow.rays"
        } else if lowercased.contains("vscode") || lowercased.contains("code") {
            return "chevron.left.forwardslash.chevron.right"
        } else if lowercased.contains("codex") {
            return "terminal"
        } else if lowercased.contains("gemini") {
            return "sparkles"
        } else {
            return "app.connected.to.app.below.fill"
        }
    }

    private var riskColor: Color {
        switch request.operation.riskLevel {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    private var riskIconName: String {
        switch request.operation.riskLevel {
        case .low: "checkmark.shield"
        case .medium: "exclamationmark.triangle"
        case .high: "exclamationmark.octagon"
        }
    }

    private var alwaysAllowToggle: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $alwaysAllow)
                .toggleStyle(SwitchToggleStyle(tint: riskColor))
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text("Always allow this operation from \(request.clientID)")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("Skip approval for future \(request.operation.displayName.lowercased()) requests")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        HStack(spacing: 12) {
            // Deny button
            Button(action: { Task { await deny() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Deny")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .buttonStyle(WorkspaceApprovalDenyButtonStyle())

            // Allow button
            Button(action: { Task { await allow() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text(allowButtonTitle)
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .buttonStyle(WorkspaceApprovalAllowButtonStyle(riskLevel: request.operation.riskLevel))
            // Owner-only requests need a click: Return never approves them.
            .keyboardShortcut(request.operation.allowsAutoApproval ? .defaultAction : nil)
        }
        .padding(20)
    }

    private var allowButtonTitle: String {
        guard request.operation.allowsAutoApproval else { return "Allow" }
        return alwaysAllow ? "Always Allow" : "Allow Once"
    }

    // MARK: - Actions

    private func allow() async {
        // Bind the answer to the request the owner saw before the animation delay.
        let requestID = request.id
        let alwaysAllow = alwaysAllow && request.operation.allowsAutoApproval
        withAnimation(.easeInOut(duration: 0.2)) {
            isAnimating = false
        }
        // Small delay for animation
        try? await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            approvalManager.resolveApproval(
                allow: true,
                alwaysAllow: alwaysAllow,
                expectedRequestID: requestID
            )
        }
    }

    private func deny() async {
        let requestID = request.id
        withAnimation(.easeInOut(duration: 0.2)) {
            isAnimating = false
        }
        // Small delay for animation
        try? await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            approvalManager.resolveApproval(allow: false, alwaysAllow: false, expectedRequestID: requestID)
        }
    }
}

// MARK: - Custom Button Styles

private struct WorkspaceApprovalAllowButtonStyle: ButtonStyle {
    let riskLevel: WorkspaceApprovalRiskLevel

    private var buttonColor: Color {
        switch riskLevel {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                buttonColor,
                                buttonColor.opacity(0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct WorkspaceApprovalDenyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Preview

#if DEBUG
    struct WorkspaceApprovalOverlayView_Previews: PreviewProvider {
        static var previews: some View {
            let manager = WorkspaceApprovalManager.shared

            WorkspaceApprovalOverlayView(
                approvalManager: manager,
                request: WorkspaceApprovalRequest(
                    clientID: "claude-code",
                    operation: .addFolder,
                    workspaceName: "MyProject",
                    folderPath: "/Users/developer/Projects/MyProject/src"
                )
            )
            .previewDisplayName("Add Folder")

            WorkspaceApprovalOverlayView(
                approvalManager: manager,
                request: WorkspaceApprovalRequest(
                    clientID: "cursor-mcp-client",
                    operation: .deleteWorkspace,
                    workspaceName: "OldProject"
                )
            )
            .previewDisplayName("Delete Workspace")
        }
    }
#endif
