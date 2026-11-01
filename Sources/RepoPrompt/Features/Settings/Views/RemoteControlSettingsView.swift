import AppKit
import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

struct RemoteControlSettingsView: View {
    var showFeedback: (String, Bool) -> Void

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @ObservedObject private var gatewayStatus = RemoteGatewayStatusStore.shared
    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var passkeyCoordinator = RemotePasskeyCoordinator.shared
    @State private var hostFingerprint = ""
    @State private var pairedDevices: [PairedDeviceRecord] = []
    @State private var storeError: String?
    @State private var browserPortDraft = ""
    @State private var browserPortError: String?
    @State private var pendingPasskeyDisable: PairedDeviceRecord?

    private let buildIdentity = RemoteControlBuildIdentity.current
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var remoteGatewayEnabledBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpRemoteGatewayEnabled() },
            set: { enabled in
                globalSettings.setMCPRemoteGatewayEnabled(enabled)
                Task { await ServerController.shared.applyRemoteGatewaySettings() }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            gatewaySection
            Divider()
            browserLinkSection
            Divider()
            identitySection
            Divider()
            devicesSection
        }
        .onAppear(perform: refreshAll)
        .confirmationDialog(
            "Turn off the passkey requirement?",
            isPresented: Binding(get: { pendingPasskeyDisable != nil }, set: { if !$0 { pendingPasskeyDisable = nil } }),
            presenting: pendingPasskeyDisable
        ) { device in
            Button("Turn Off Passkey", role: .destructive) { disablePasskey(device) }
            Button("Cancel", role: .cancel) { pendingPasskeyDisable = nil }
        } message: { device in
            Text("Browser access for \(device.displayName) will no longer require a passkey. Any enrolled credential is cleared. You can require a passkey again later.")
        }
    }

    private var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote Control").font(fontPreset.font)
                    Text("Advertise this Mac as a signed RepoPrompt host directly on its Tailscale IPv4 address.")
                        .font(fontPreset.captionFont).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: remoteGatewayEnabledBinding)
                    .toggleStyle(SwitchToggleStyle())
                    .hoverTooltip("Start the packaged gateway on the current Tailscale address")
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                factRow("Build channel", buildIdentity.channel.rawValue.capitalized)
                factRow("Fixed port", String(buildIdentity.fixedPort))
                factRow("Status", gatewayStatus.status.summary)
                if let origin = gatewayStatus.status.origin {
                    factRow("Tailnet origin", origin.string, monospaced: true)
                }
            }
            detailsDisclosure([
                "Tailscale must be installed, signed in, and running. The gateway listens on this Mac's Tailscale address and never falls back to loopback, LAN, or wildcard binding. It also listens on 127.0.0.1 only while a browser origin is set below, for Tailscale Serve."
            ])
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Refresh Status") {
                Task { await ServerController.shared.applyRemoteGatewaySettings() }
            }
            .buttonStyle(CustomButtonStyle())
            .disabled(!globalSettings.mcpRemoteGatewayEnabled())
        }
    }

    private var suggestedBrowserPort: Int {
        GlobalScalarPreferences.MCPSettings.suggestedBrowserHTTPSPort
    }

    /// Paired-browser HTTPS link: an owner-run `tailscale serve` listener on a non-443 port that
    /// forwards to this build's gateway on 127.0.0.1. A saved port also makes the gateway listen on
    /// 127.0.0.1 for that forwarding. The app never changes Tailscale configuration.
    private var browserLinkSection: some View {
        let configuredOrSuggestedPort = globalSettings.mcpRemoteGatewayBrowserHTTPSPort() ?? suggestedBrowserPort
        return VStack(alignment: .leading, spacing: 8) {
            Text("Browser link (HTTPS)").font(fontPreset.font)
            Text("Set a port (not 443) to add an Open session button for your paired phone browser to Telegram alerts while Remote Control is running, or leave it blank for text-only alerts.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("HTTPS port").font(fontPreset.captionFont).foregroundColor(.secondary)
                // String titles: an Int inside a LocalizedStringKey literal would render with
                // locale digit grouping (for example "8.443").
                TextField(String(suggestedBrowserPort), text: $browserPortDraft)
                    .onSubmit(saveBrowserPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                Button("Save Port", action: saveBrowserPort).buttonStyle(CustomButtonStyle())
                Button("Use " + String(suggestedBrowserPort)) {
                    browserPortDraft = String(suggestedBrowserPort)
                    saveBrowserPort()
                }
                .buttonStyle(CustomButtonStyle())
                Spacer()
            }
            if let browserPortError {
                Text(browserPortError).font(fontPreset.captionFont).foregroundColor(.red)
            }
            if let browserOrigin = gatewayStatus.browserOrigin {
                copyableField("Browser origin", browserOrigin.string) { EmptyView() }
            } else if globalSettings.mcpRemoteGatewayBrowserHTTPSPort() != nil, gatewayStatus.status.origin != nil {
                Text("Tailscale reported no MagicDNS name for this Mac, so there is no browser origin. Enable MagicDNS, then click Refresh Status.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let gatewayOrigin = gatewayStatus.status.origin {
                let command = RemoteGatewayBrowserOrigin.serveCommand(
                    browserPort: configuredOrSuggestedPort,
                    gatewayOrigin: gatewayOrigin
                )
                copyableField("Run once in Terminal (\(buildIdentity.channel.rawValue.capitalized) build)", command) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        showFeedback("Copied tailscale serve command", false)
                    }
                    .buttonStyle(CustomButtonStyle())
                }
            } else {
                Text("Turn on Remote Control to see the exact tailscale serve command for this build.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
            }
            detailsDisclosure([
                "Requires MagicDNS and HTTPS certificates in Tailscale. Run the command after saving a port. While a browser origin is shown, this build's gateway also listens on 127.0.0.1 for that Tailscale Serve command.",
                "One Serve port forwards to one build's gateway: after switching between the release and Dev builds, run the command shown in the build you use. It replaces the earlier target; until then, links fail.",
                "Clearing the port stops the 127.0.0.1 listener and returns alerts to text only, but leaves your Serve setup in place; remove it with tailscale serve --https=\(String(configuredOrSuggestedPort)) off. Serve's port 443 is never changed."
            ])
        }
    }

    /// Blank clears the port; otherwise a whole number 1–65535 other than 443. Only a saved
    /// change is reported and relaunches the gateway with the new browser origin; a failed save
    /// keeps the draft and changes nothing.
    private func saveBrowserPort() {
        let trimmed = browserPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: Int?
        if trimmed.isEmpty {
            port = nil
        } else if trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber), let value = Int(trimmed),
                  GlobalScalarPreferences.MCPSettings.isValidBrowserHTTPSPort(value)
        {
            port = value
        } else {
            browserPortError = "Enter a port from 1 to 65535 other than 443, or leave it blank. Nothing was changed."
            return
        }
        guard port != globalSettings.mcpRemoteGatewayBrowserHTTPSPort() else {
            browserPortError = nil
            browserPortDraft = port.map(String.init) ?? ""
            return
        }
        guard globalSettings.setMCPRemoteGatewayBrowserHTTPSPort(port) else {
            browserPortError = "Couldn't save the browser HTTPS port. Nothing was changed."
            showFeedback("Couldn't save the browser HTTPS port", true)
            return
        }
        browserPortError = nil
        browserPortDraft = port.map(String.init) ?? ""
        showFeedback(port.map { "Browser HTTPS port set to \($0)" } ?? "Browser HTTPS port cleared", false)
        Task { await ServerController.shared.applyRemoteGatewaySettings() }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signed host identity").font(fontPreset.font)
            Text("Clients verify this app-owned key before showing a host or requesting access.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
            if let storeError {
                Text(storeError).font(fontPreset.captionFont).foregroundColor(.red)
            }
            copyableField("Host fingerprint", hostFingerprint.isEmpty ? "Unavailable" : hostFingerprint) { EmptyView() }
            detailsDisclosure([
                "Pairing requests are approved in the host app and are bound to a short-lived, single-use discovery context. No pairing payload or editable endpoint is required."
            ])
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Paired devices").font(fontPreset.font)
                Spacer()
                Button("Refresh") { refreshDevices() }.buttonStyle(CustomButtonStyle())
            }
            if pairedDevices.isEmpty {
                Text("No paired devices yet.").font(fontPreset.captionFont).foregroundColor(.secondary)
            } else {
                ForEach(pairedDevices) { deviceRow($0) }
            }
        }
    }

    private func deviceRow(_ device: PairedDeviceRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: device.isRevoked ? "iphone.slash" : "iphone")
                .foregroundColor(device.isRevoked ? .secondary : .accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.displayName).font(fontPreset.font)
                    if device.isRevoked {
                        Text("Revoked").font(fontPreset.captionFont)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(verbatim: device.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: device.scopes.sorted().map(\.rawValue).joined(separator: ", "))
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                passkeyBlock(device)
            }
            Spacer()
            Button("Revoke") { revoke(device) }.buttonStyle(CustomButtonStyle()).disabled(device.isRevoked)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func passkeyBlock(_ device: PairedDeviceRecord) -> some View {
        // Recomputed whenever the coordinator's `revision` OR the gateway status (origin/lifecycle)
        // changes — both are observed objects. The saved policy state and the observed enforcement
        // state are shown as separate lines. A failed read (malformed/fenced store) is surfaced as
        // "unavailable" with actions disabled — never silently presented as "off".
        let result = Result { try passkeyCoordinator.status(for: device.id) }
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 2)
            switch result {
            case let .success(status):
                HStack(spacing: 6) {
                    Image(systemName: "key.horizontal").foregroundColor(.secondary).frame(width: 14)
                    Text("Passkey: \(passkeyPersistedLabel(status.persisted))").font(fontPreset.captionFont)
                }
                // A policy-off device keeps ordinary browser access, so it has no passkey
                // enforcement requirement and shows no enforcement line.
                if showsEnforcementLine(status.persisted) {
                    Text(passkeyEnforcementLabel(status.enforcement))
                        .font(fontPreset.captionFont).foregroundColor(.secondary)
                }
                if let reason = status.enableBlockedReason {
                    Text(reason).font(fontPreset.captionFont).foregroundColor(.secondary)
                }
                if let openUntil = status.enrollmentOpenUntil {
                    Text("Enrollment open until \(openUntil, style: .time)")
                        .font(fontPreset.captionFont).foregroundColor(.secondary)
                }
                passkeyControls(device, status: status)
            case .failure:
                HStack(spacing: 6) {
                    Image(systemName: "key.horizontal").foregroundColor(.secondary).frame(width: 14)
                    Text("Passkey: status unavailable").font(fontPreset.captionFont)
                }
                Text("The passkey policy could not be read. Reload or restart RepoPrompt to manage it.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
                passkeyControls(device, status: nil)
            }
        }
    }

    @ViewBuilder
    private func passkeyControls(_ device: PairedDeviceRecord, status: RemotePasskeyDeviceStatus?) -> some View {
        // A nil status means the read failed: disable every action, since each one needs a store read.
        let unavailable = status == nil
        let blocked = unavailable || status?.enableBlockedReason != nil
        HStack(spacing: 8) {
            switch status?.persisted {
            case .off, .none:
                Button("Require Passkey") { runPasskeyAction(device, "Passkey required for") { try await passkeyCoordinator.enable(deviceID: device.id) } }
                    .buttonStyle(CustomButtonStyle()).disabled(blocked || device.isRevoked)
            case .requiredNotEnrolled:
                Button("Open Enrollment") { runPasskeyAction(device, "Enrollment opened for") { try await passkeyCoordinator.openEnrollment(deviceID: device.id) } }
                    .buttonStyle(CustomButtonStyle()).disabled(blocked || device.isRevoked)
                // Trusted local recovery: available even when the origin is unavailable, but not when
                // the policy itself could not be read.
                Button("Turn Off") { pendingPasskeyDisable = device }.buttonStyle(CustomButtonStyle()).disabled(unavailable)
            case .requiredEnrolled, .requiredNeedsReenrollment:
                Button("Reset") { runPasskeyAction(device, "Passkey reset for") { try passkeyCoordinator.reset(deviceID: device.id) } }
                    .buttonStyle(CustomButtonStyle()).disabled(unavailable)
                Button("Turn Off") { pendingPasskeyDisable = device }.buttonStyle(CustomButtonStyle()).disabled(unavailable)
            }
        }
    }

    private func passkeyPersistedLabel(_ persisted: RemotePasskeyDeviceStatus.Persisted?) -> String {
        switch persisted {
        case .off, .none: "Not required"
        case .requiredNotEnrolled: "Required · not enrolled"
        case .requiredEnrolled: "Required · enrolled"
        case .requiredNeedsReenrollment: "Required · re-enrollment needed"
        }
    }

    /// A policy-off device has no passkey enforcement requirement; only a device that requires a
    /// passkey shows an enforcement line.
    private func showsEnforcementLine(_ persisted: RemotePasskeyDeviceStatus.Persisted) -> Bool {
        if case .off = persisted { return false }
        return true
    }

    private func passkeyEnforcementLabel(_ enforcement: RemotePasskeyDeviceStatus.Enforcement?) -> String {
        switch enforcement {
        case .gatewayUnavailable, .none: "Enforcement: Remote Control not active"
        case .gatewayLacksSupport: "Enforcement: gateway update required"
        case .pending: "Enforcement: pending gateway acknowledgment"
        case .applied: "Enforcement: active"
        }
    }

    private func runPasskeyAction(_ device: PairedDeviceRecord, _ success: String, _ action: @escaping () async throws -> Void) {
        // enable/openEnrollment are async (they live-check the gateway principal before activating
        // policy); reset/disable are synchronous but satisfy the async closure trivially. The view
        // is @MainActor, so the Task runs on the main actor and UI updates stay ordered.
        Task { @MainActor in
            do {
                try await action()
                refreshDevices()
                showFeedback("\(success) \(device.displayName)", false)
            } catch let failure as RemotePasskeyFailure {
                showFeedback("Passkey action failed: \(failure.code)", true)
            } catch {
                showFeedback("Passkey action failed: \(error.localizedDescription)", true)
            }
        }
    }

    /// One gateway fact as a label/value grid row; monospaced values are selectable.
    private func factRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).font(fontPreset.captionFont).foregroundColor(.secondary)
            Text(verbatim: value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : fontPreset.captionFont)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Label above a monospaced, selectable value, with an optional trailing action aligned to
    /// the value's first line.
    private func copyableField(
        _ label: String,
        _ value: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(fontPreset.captionFont).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: value)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing()
            }
        }
    }

    /// Collapsed operational detail: available on demand without a wall of captions.
    private func detailsDisclosure(_ paragraphs: [String]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(paragraphs, id: \.self) { paragraph in
                    Text(verbatim: paragraph)
                        .font(fontPreset.captionFont).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Details").font(fontPreset.captionFont).foregroundColor(.secondary)
        }
    }

    private func refreshAll() {
        browserPortDraft = globalSettings.mcpRemoteGatewayBrowserHTTPSPort().map(String.init) ?? ""
        refreshHostIdentity()
        refreshDevices()
    }

    private func refreshHostIdentity() {
        do {
            hostFingerprint = try RemotePairingIdentityStore.shared.hostPublicKeyInfo().fingerprint
            storeError = nil
        } catch {
            hostFingerprint = ""
            storeError = "Remote pairing host key unavailable: \(error.localizedDescription)"
        }
    }

    private func refreshDevices() {
        do {
            pairedDevices = try RemotePairingIdentityStore.shared.listDevices(includeRevoked: true)
            storeError = nil
        } catch {
            pairedDevices = []
            storeError = "Remote pairing store unavailable: \(error.localizedDescription)"
        }
    }

    private func disablePasskey(_ device: PairedDeviceRecord) {
        pendingPasskeyDisable = nil
        runPasskeyAction(device, "Passkey requirement turned off for") { try passkeyCoordinator.disable(deviceID: device.id) }
    }

    private func revoke(_ device: PairedDeviceRecord) {
        do {
            _ = try RemotePairingIdentityStore.shared.revokeDevice(id: device.id)
            refreshDevices()
            showFeedback("Revoked \(device.displayName)", false)
        } catch {
            showFeedback("Failed to revoke device: \(error.localizedDescription)", true)
        }
    }
}
