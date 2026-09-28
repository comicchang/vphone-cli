import SwiftUI

struct VPhoneLaunchpadHostSetupView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VPhoneLaunchpadMenuBar.key) private var showsInMenuBar = false

    private var host: VPhoneLaunchpadHostSetup {
        model.host
    }

    var body: some View {
        @Bindable var host = host
        VPhoneLaunchpadSheet(Text("Host Setup")) {
            form
        } accessory: {
            Button("Check Again") {
                Task { await model.refreshHost() }
            }
            .help("Run every check again")
            .disabled(host.isChecking)
        } actions: {
            // Straight on to the next stage while it is not ready.
            if host.requiredPassed, !model.bundles.isReady {
                Button("Continue") { model.panel = .coreBundle }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 600, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            host.refreshDeveloperTools()
        }
        .errorAlert($host.actionError)
    }

    private var form: some View {
        Form {
            Section {
                ForEach(host.required) { check in
                    row(check)
                }
            } header: {
                HStack {
                    Text("Required")
                    Spacer()
                    Text("\(host.passedRequiredCount) of \(host.required.count) passed")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if !host.requiredPassed {
                    VStack(alignment: .leading, spacing: 4) {
                        if host.checks.contains(where: { $0.kind == .developerTools && $0.status != .passed }) {
                            Text("Allow vphone-launchpad in Privacy & Security → Developer Tools, then click Reopen.")
                        }
                        Text("A Core Bundle can be installed once every required check passes.")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(host.advisory) { check in
                    row(check)
                }
            } header: {
                Text("Advisory")
            } footer: {
                Text("Advisory checks do not block setup.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep in Menu Bar", isOn: $showsInMenuBar)
            } footer: {
                Text("Closing the window keeps Launchpad in the menu bar, where you can start and stop machines. The Dock icon appears only while a window or the menu is open.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Icon, title, then detail and any action pinned to the trailing edge.
    /// A plain HStack rather than LabeledContent: LabeledContent splits the
    /// row into columns and truncated the detail while leaving the button
    /// short of the edge.
    private func row(_ check: VPhoneLaunchpadHostCheck) -> some View {
        let isSkipped = host.isSkipped(check)
        return HStack(spacing: 8) {
            VPhoneLaunchpadStatusIcon(status: isSkipped ? .warning : check.status)
            Text(check.title)
                .layoutPriority(1)
            Spacer(minLength: 16)
            Text(isSkipped ? String(localized: "Skipped · \(check.detail)") : check.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(check.detail)
            action(for: check)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func action(for check: VPhoneLaunchpadHostCheck) -> some View {
        switch check.kind {
        case .developerTools where check.status != .passed:
            HStack(spacing: 8) {
                if host.canRequestDeveloperTools {
                    Button("Open Settings") {
                        Task { await host.requestDeveloperTools() }
                    }
                }
                if host.needsRelaunch {
                    Button("Reopen") {
                        host.relaunch()
                    }
                }
            }
        case .helper where check.status == .pending:
            Button(host.helper.state == .notInstalled ? "Install…" : "Update…") {
                Task {
                    await host.installHelper()
                    await model.refreshHost()
                }
            }
        default:
            if host.isSkipped(check) {
                Button("Don’t Skip") { host.setSkipped(check.kind, false) }
            } else if host.canSkip(check) {
                Button("Skip") { host.setSkipped(check.kind, true) }
                    .help("Continue without this check. The Core Bundle still runs its own checks.")
            }
        }
    }
}
