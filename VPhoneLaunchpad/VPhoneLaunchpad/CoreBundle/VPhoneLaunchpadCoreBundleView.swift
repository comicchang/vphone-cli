import SwiftUI
import UniformTypeIdentifiers

struct VPhoneLaunchpadCoreBundleView: View {
    enum Source: Hashable {
        case releases
        case actions
    }

    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removal: String?
    @State private var source = Source.releases
    @State private var token = ""

    private var bundles: VPhoneLaunchpadCoreBundle {
        model.bundles
    }

    private var notInstalled: [VPhoneLaunchpadRelease] {
        bundles.releases.filter { release in !bundles.installed.contains { $0.version == release.version } }
    }

    var body: some View {
        @Bindable var bundles = bundles
        Form {
            if bundles.isInstalling {
                Section {
                    Text("An install is in progress. Follow it in the inspector.")
                        .foregroundStyle(.secondary)
                }
            }
            if !bundles.installed.isEmpty {
                installedSection
            }
            availableSection
        }
        .formStyle(.grouped)
        .navigationTitle("Core Bundle")
        .frame(width: 640, height: 480)
        .errorAlert($bundles.actionError)
        #if DEBUG
            .onAppear {
                if VPhoneLaunchpadPreview.isActive {
                    source = VPhoneLaunchpadPreview.coreBundleSource
                }
            }
        #endif
            .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Install Local Build…") {
                    chooseLocalBuild()
                }
                .help(model.canInstallBundles
                    ? "Install a VPhone.bundle folder or .zip built on this Mac."
                    : "Installing needs the privileged helper and Developer Tools access.")
                .disabled(!model.canInstallBundles)
            }
            ToolbarItem(placement: .automatic) {
                Button("Check for Updates") {
                    Task { await bundles.refresh() }
                }
                .help("Reload releases and builds, and run host preflight again.")
                .disabled(bundles.isInstalling)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Remove VPhone.bundle \(removal ?? "")?",
            isPresented: Binding(get: { removal != nil }, set: {
                if !$0 {
                    removal = nil
                }
            }),
        ) {
            Button("Remove", role: .destructive) {
                if let version = removal {
                    Task { await model.removeBundle(version) }
                }
            }
        } message: {
            Text("Machines are not affected. You can install this version again later.")
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        Section {
            ForEach(bundles.installed) { bundle in
                installedRow(bundle)
            }
        } header: {
            Text("Installed")
        } footer: {
            Text("Stored in \(VPhoneLaunchpadBundleStore.root.path), owned by root and written only by the helper.")
                .foregroundStyle(.secondary)
        }
    }

    private func installedRow(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> some View {
        let isActive = bundle.version == bundles.activeVersion
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // The version in use is the one with the green title.
                Text(verbatim: "VPhone.bundle \(bundle.version)")
                    .foregroundStyle(isActive ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    .accessibilityValue(isActive ? "In use" : "")
                    .help(isActive ? "In use" : "")
                Group {
                    if VPhoneLaunchpadLocalBundle.isLocal(version: bundle.version) {
                        Text("Local build · Installed \(bundle.receipt.installedAt.formatted(date: .abbreviated, time: .shortened)) · SHA-256 \(Self.shortDigest(bundle.receipt.sha256))")
                    } else if bundle.version != VPhoneLaunchpadNames.bundleVersion(of: bundle.version) {
                        Text("GitHub Actions build · Installed \(bundle.receipt.installedAt.formatted(date: .abbreviated, time: .shortened)) · SHA-256 \(Self.shortDigest(bundle.receipt.sha256))")
                    } else {
                        Text("Installed \(bundle.receipt.installedAt.formatted(date: .abbreviated, time: .omitted)) · SHA-256 \(Self.shortDigest(bundle.receipt.sha256))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Label {
                Text(checkSummary(bundle))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                VPhoneLaunchpadStatusIcon(status: checkStatus(bundle))
            }
            .font(.callout)
            .help(checkHelp(bundle))
            Menu {
                Button("Use This Version") { Task { await bundles.use(bundle.version) } }
                    .disabled(isActive || !VPhoneLaunchpadNames.isCompatibleBundleVersion(bundle.version))
                Button("Run Preflight Again") { Task { await bundles.verify(bundle.version) } }
                    .disabled(!VPhoneLaunchpadNames.isCompatibleBundleVersion(bundle.version))
                if bundles.isAccepted(bundle.version) {
                    Button("Require Preflight") { bundles.setAccepted(bundle.version, false) }
                } else if bundle.preflight == .failed, VPhoneLaunchpadNames.isCompatibleBundleVersion(bundle.version) {
                    Button("Use Without Preflight") { bundles.setAccepted(bundle.version, true) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([VPhoneLaunchpadBundleStore.bundle(version: bundle.version)])
                }
                Divider()
                Button("Remove…", role: .destructive) { removal = bundle.version }
                    .disabled(bundles.isInstalling)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Policy exception and preflight folded into one status: the worst of
    /// the two, with a skipped preflight shown as a warning.
    private func checkStatus(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> VPhoneLaunchpadStatus {
        if bundle.policy == .running || bundle.preflight == .running {
            return .running
        }
        if bundle.policy == .passed, bundle.preflight == .passed {
            return .passed
        }
        if bundles.isAccepted(bundle.version) {
            return .warning
        }
        return bundle.policy == .pending && bundle.preflight == .pending ? .pending : .failed
    }

    private func checkSummary(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> String {
        switch checkStatus(bundle) {
        case .running: String(localized: "Checking…")
        case .passed: String(localized: "Preflight passed")
        case .warning: String(localized: "Preflight skipped")
        case .pending: String(localized: "Not checked")
        case .failed: bundle.policy != .passed ? String(localized: "Not allowed to run") : String(localized: "Preflight failed")
        }
    }

    private func checkHelp(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> String {
        let policy = bundle.policy == .passed ? String(localized: "Allowed to run.") : String(localized: "Not allowed to run.")
        return bundle.preflightDetail.isEmpty ? policy : "\(policy)\n\(bundle.preflightDetail)"
    }

    // MARK: - Available

    private var availableSection: some View {
        Section {
            Picker("Source", selection: $source) {
                Text("Releases").tag(Source.releases)
                Text("GitHub Actions").tag(Source.actions)
            }
            .pickerStyle(.segmented)
            switch source {
            case .releases:
                if let error = bundles.releasesError, bundles.releases.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if bundles.releases.isEmpty {
                    loadingRow("Loading releases…")
                } else if notInstalled.isEmpty {
                    Text("Every release is installed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notInstalled) { release in
                        releaseRow(release, prominent: release == bundles.availableUpdate)
                    }
                }
            case .actions:
                tokenRow
                if let error = bundles.artifactsError, bundles.artifacts.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if bundles.artifacts.isEmpty {
                    Text("No GitHub Actions builds are available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bundles.artifacts) { artifact in
                        artifactRow(artifact)
                    }
                }
            }
        } header: {
            Text("Available")
        } footer: {
            if source == .actions {
                Text("Builds from GitHub Actions, kept for 7 days. To download them, add a token that can read Actions for Lakr233/vphone-cli. The token is stored in your keychain.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadingRow(_ title: LocalizedStringKey) -> some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
    }

    // MARK: - GitHub Actions

    @ViewBuilder
    private var tokenRow: some View {
        if bundles.hasGitHubToken {
            LabeledContent("GitHub Token") {
                HStack {
                    Text("Saved in the keychain")
                        .foregroundStyle(.secondary)
                    Button("Remove") {
                        bundles.setGitHubToken("")
                    }
                }
            }
        } else {
            LabeledContent("GitHub Token") {
                HStack {
                    SecureField("GitHub Token", text: $token, prompt: Text(verbatim: "github_pat_…"))
                        .labelsHidden()
                        .onSubmit(saveToken)
                    Button("Save", action: saveToken)
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func saveToken() {
        bundles.setGitHubToken(token)
        token = ""
        Task { await bundles.fetchArtifacts() }
    }

    private func artifactRow(_ artifact: VPhoneLaunchpadArtifact) -> some View {
        let isInstalled = bundles.installed.contains { $0.version.hasSuffix(artifact.versionSuffix) }
        let canInstall = model.canInstallBundles && bundles.hasGitHubToken
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "VPhone.bundle")
                    Link(destination: artifact.runURL) {
                        Text(verbatim: artifact.branch.isEmpty ? artifact.shortCommit : "\(artifact.branch) @ \(artifact.shortCommit)")
                            .monospaced()
                    }
                    .help("Open the workflow run on GitHub")
                }
                Text("\(artifact.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Self.size(artifact.size)) · Expires \(artifact.expiresAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isInstalled {
                Text("Installed")
                    .foregroundStyle(.secondary)
            } else {
                Button("Download and Install") { Task { await model.installArtifact(artifact) } }
                    .disabled(!canInstall)
            }
        }
        .help(canInstall || isInstalled ? ""
            : model.canInstallBundles ? "Add a GitHub token to download builds from GitHub Actions."
            : "Installing needs the privileged helper and Developer Tools access.")
    }

    private func releaseRow(_ release: VPhoneLaunchpadRelease, prominent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "VPhone.bundle \(release.version)")
                    if release.isPrerelease {
                        Text("Pre-release")
                            .foregroundStyle(.orange)
                    }
                }
                Text(verbatim: "\(release.publishedAt.formatted(date: .abbreviated, time: .omitted)) · \(Self.size(release.size)) · SHA-256 \(Self.shortDigest(release.sha256))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if prominent {
                Button("Download and Install") { Task { await model.installBundle(release) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canInstallBundles)
            } else {
                Button("Download and Install") { Task { await model.installBundle(release) } }
                    .disabled(!model.canInstallBundles)
            }
        }
        .help(model.canInstallBundles ? "" : "Installing needs the privileged helper and Developer Tools access.")
    }

    // MARK: - Local build

    private func chooseLocalBuild() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Install Local Build")
        panel.message = String(localized: "Choose a VPhone.bundle folder or a .zip that contains one.")
        panel.prompt = String(localized: "Install")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .bundle]
        panel.present { url in
            Task { await model.installLocalBundle(url) }
        }
    }

    // MARK: - Formatting

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func shortDigest(_ digest: String) -> String {
        "\(digest.prefix(8))…"
    }
}
