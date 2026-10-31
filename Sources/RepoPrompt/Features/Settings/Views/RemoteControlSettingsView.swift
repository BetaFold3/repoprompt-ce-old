import AppKit
import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

struct RemoteControlSettingsView: View {
    var showFeedback: (String, Bool) -> Void

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @ObservedObject private var gatewayStatus = RemoteGatewayStatusStore.shared
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var hostFingerprint = ""
    @State private var pairedDevices: [PairedDeviceRecord] = []
    @State private var storeError: String?
    @State private var browserPortDraft = ""
    @State private var browserPortError: String?

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

            HStack(spacing: 16) {
                labeledValue("Build channel", buildIdentity.channel.rawValue.capitalized)
                labeledValue("Fixed port", String(buildIdentity.fixedPort))
                labeledValue("Status", gatewayStatus.status.summary)
            }
            if let origin = gatewayStatus.status.origin {
                labeledMonospace("Tailnet origin", origin.string)
            }
            Text("Tailscale must be installed, signed in, and running. The gateway listens on this Mac's Tailscale address and never falls back to loopback, LAN, or wildcard binding. It also listens on 127.0.0.1 only while a browser origin is set below, for Tailscale Serve.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh Status") {
                    Task { await ServerController.shared.applyRemoteGatewaySettings() }
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(!globalSettings.mcpRemoteGatewayEnabled())
                Spacer()
            }
        }
    }

    private var suggestedBrowserPort: Int {
        GlobalScalarPreferences.MCPSettings.suggestedBrowserHTTPSPort
    }

    /// Paired-browser HTTPS link: an owner-run `tailscale serve` listener on a non-443 port that
    /// forwards to this build's gateway on 127.0.0.1. A saved port also makes the gateway listen on
    /// 127.0.0.1 for that forwarding. The app never changes Tailscale configuration.
    private var browserLinkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Browser link (HTTPS)").font(fontPreset.font)
            Text("Telegram alerts get an Open session button for your paired phone browser when this port is set and Remote Control is running. While a browser origin is shown, this build's gateway also listens on 127.0.0.1 for the Tailscale Serve command below. Leave it blank for text-only alerts. Port 443 is not allowed.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("\(suggestedBrowserPort)", text: $browserPortDraft)
                    .onSubmit(saveBrowserPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                Button("Save Port", action: saveBrowserPort).buttonStyle(CustomButtonStyle())
                Button("Use \(suggestedBrowserPort)") {
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
                labeledMonospace("Browser origin", browserOrigin.string)
            } else if globalSettings.mcpRemoteGatewayBrowserHTTPSPort() != nil, gatewayStatus.status.origin != nil {
                Text("Tailscale reported no MagicDNS name for this Mac, so there is no browser origin. Enable MagicDNS, then click Refresh Status.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let gatewayOrigin = gatewayStatus.status.origin {
                let command = RemoteGatewayBrowserOrigin.serveCommand(
                    browserPort: globalSettings.mcpRemoteGatewayBrowserHTTPSPort() ?? suggestedBrowserPort,
                    gatewayOrigin: gatewayOrigin
                )
                HStack(alignment: .bottom, spacing: 8) {
                    labeledMonospace("Run once in Terminal (\(buildIdentity.channel.rawValue.capitalized) build)", command)
                    Spacer()
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
            Text("Requires MagicDNS and HTTPS certificates in Tailscale. Run the command after saving a port. One Serve port forwards to one build's gateway: after switching between the release and Dev builds, run the command shown in the build you use. It replaces the earlier target; until then, links fail. Clearing the port stops the 127.0.0.1 listener and returns alerts to text only, but leaves your Serve setup in place; remove it with tailscale serve --https=\(globalSettings.mcpRemoteGatewayBrowserHTTPSPort() ?? suggestedBrowserPort) off. Serve's port 443 is never changed.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            labeledMonospace("Host fingerprint", hostFingerprint.isEmpty ? "Unavailable" : hostFingerprint)
            Text("Pairing requests are approved in the host app and are bound to a short-lived, single-use discovery context. No pairing payload or editable endpoint is required.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: device.isRevoked ? "iphone.slash" : "iphone")
                .foregroundColor(device.isRevoked ? .secondary : .accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.displayName).font(fontPreset.font)
                    if device.isRevoked {
                        Text("Revoked").font(fontPreset.captionFont)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(device.id).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Text(device.scopes.sorted().map(\.rawValue).joined(separator: ", "))
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
            }
            Spacer()
            Button("Revoke") { revoke(device) }.buttonStyle(CustomButtonStyle()).disabled(device.isRevoked)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(fontPreset.captionFont).foregroundColor(.secondary)
            Text(value).font(fontPreset.captionFont)
        }
    }

    private func labeledMonospace(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(fontPreset.captionFont).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
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
