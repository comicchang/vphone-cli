import ExecutionPolicy
import Foundation
import Observation

/// The second stage: installed VPhone.bundle versions, the one in use, and
/// installing new ones from GitHub releases.
@MainActor
@Observable
final class VPhoneLaunchpadCoreBundle {
    // MARK: - Installed versions

    struct Installed: Identifiable {
        let receipt: VPhoneLaunchpadBundleReceipt
        var policy: VPhoneLaunchpadStatus = .pending
        var policyDetail = ""
        var preflight: VPhoneLaunchpadStatus = .pending
        var preflightDetail = ""

        var id: String {
            receipt.version
        }

        var version: String {
            receipt.version
        }
    }

    // MARK: - Install progress

    enum InstallStep: String, CaseIterable, Identifiable, Codable {
        case prepare
        case download
        case verify
        case install
        case policy
        case preflight

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .prepare: String(localized: "Prepare bundle")
            case .download: String(localized: "Download")
            case .verify: String(localized: "Verify SHA-256")
            case .install: String(localized: "Install as root")
            case .policy: String(localized: "Allow bundle to run")
            case .preflight: String(localized: "Host preflight")
            }
        }
    }

    /// Where an install came from, kept so Retry can start it again after a
    /// relaunch, when the downloaded files are gone.
    enum InstallSource: Codable {
        case release(VPhoneLaunchpadRelease)
        case artifact(VPhoneLaunchpadArtifact)
        case local(path: String)
    }

    /// The last install and how far it got. It is written to disk on every
    /// change, so it survives quitting Launchpad; a step that was running
    /// then comes back as failed and can be retried.
    struct InstallProgress: Codable {
        /// The store version, once known. A local build's comes from its
        /// Info.plist in the prepare step.
        var version: String?
        let source: InstallSource
        let name: String
        let size: Int64
        let plan: [InstallStep]
        var steps: [InstallStep: VPhoneLaunchpadStatus] = [:]
        var received: Int64 = 0
        var errorMessage: String?
        var errorDetail: String?
        var startedAt = Date()

        init(release: VPhoneLaunchpadRelease) {
            version = release.version
            source = .release(release)
            name = release.assetName
            size = release.size
            plan = [.download, .verify, .install, .policy, .preflight]
        }

        init(local: URL) {
            source = .local(path: local.path)
            name = local.lastPathComponent
            size = 0
            plan = [.prepare, .install, .policy, .preflight]
        }

        /// The version is read from the bundle once the artifact is unpacked.
        init(artifact: VPhoneLaunchpadArtifact) {
            source = .artifact(artifact)
            name = artifact.name
            size = artifact.size
            plan = [.download, .verify, .prepare, .install, .policy, .preflight]
        }

        func status(_ step: InstallStep) -> VPhoneLaunchpadStatus {
            steps[step] ?? .pending
        }

        var error: VPhoneLaunchpadError? {
            get { errorMessage.map { VPhoneLaunchpadError($0, detail: errorDetail) } }
            set {
                errorMessage = newValue?.message
                errorDetail = newValue?.detail
            }
        }

        /// Every step passed, or was skipped.
        var isFinished: Bool {
            plan.allSatisfy { status($0) == .passed || status($0) == .warning }
        }

        /// Once the bundle is in the store, only the checks after it failed,
        /// and those may be skipped.
        var canSkip: Bool {
            error != nil && status(.install) == .passed
        }

        var overall: VPhoneLaunchpadStatus {
            if error != nil {
                return .failed
            }
            if !isFinished {
                return .running
            }
            return plan.contains { status($0) == .warning } ? .warning : .passed
        }
    }

    private(set) var installed: [Installed] = []
    private(set) var releases: [VPhoneLaunchpadRelease] = []
    private(set) var releasesError: String?
    private(set) var artifacts: [VPhoneLaunchpadArtifact] = []
    private(set) var artifactsError: String?
    private(set) var hasGitHubToken = VPhoneLaunchpadGitHubToken.load() != nil
    private(set) var progress: InstallProgress? {
        didSet { Self.saveProgress(progress) }
    }

    var actionError: VPhoneLaunchpadError?

    private let helper: VPhoneLaunchpadHelperClient
    private let history: VPhoneLaunchpadCommandHistory
    private static let activeVersionKey = "VPhoneLaunchpadActiveBundleVersion"
    private static let acceptedVersionsKey = "VPhoneLaunchpadAcceptedBundleVersions"
    /// Version → receipt SHA-256 of bundles whose last check passed.
    private static let passedVersionsKey = "VPhoneLaunchpadPassedBundleVersions"

    /// Lists the store at once, showing each bundle as its last check left
    /// it, so the window opens ready. The launch check confirms it later.
    init(helper: VPhoneLaunchpadHelperClient, history: VPhoneLaunchpadCommandHistory) {
        self.helper = helper
        self.history = history
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return
            }
        #endif
        progress = Self.loadProgress()
        loadInstalled()
        let passed = UserDefaults.standard.dictionary(forKey: Self.passedVersionsKey) as? [String: String] ?? [:]
        for index in installed.indices
            where VPhoneLaunchpadNames.isCompatibleBundleVersion(installed[index].version)
            && passed[installed[index].version] == installed[index].receipt.sha256
        {
            installed[index].policy = .passed
            installed[index].policyDetail = "exception"
            installed[index].preflight = .passed
            installed[index].preflightDetail = String(localized: "Passed")
        }
    }

    private func recordCheck(_ version: String) {
        var passed = UserDefaults.standard.dictionary(forKey: Self.passedVersionsKey) as? [String: String] ?? [:]
        let item = installed.first { $0.version == version }
        if let item, item.policy == .passed, item.preflight == .passed {
            passed[version] = item.receipt.sha256
        } else {
            passed[version] = nil
        }
        UserDefaults.standard.set(passed, forKey: Self.passedVersionsKey)
    }

    // MARK: - Active version

    var activeVersion: String? {
        get {
            access(keyPath: \.activeVersion)
            let stored = UserDefaults.standard.string(forKey: Self.activeVersionKey)
            if let stored, installed.contains(where: { $0.version == stored && VPhoneLaunchpadNames.isCompatibleBundleVersion($0.version) }) {
                return stored
            }
            return installed.first { VPhoneLaunchpadNames.isCompatibleBundleVersion($0.version) }?.version
        }
        set {
            withMutation(keyPath: \.activeVersion) {
                UserDefaults.standard.set(newValue, forKey: Self.activeVersionKey)
            }
        }
    }

    var active: Installed? {
        installed.first { $0.version == activeVersion }
    }

    /// The active bundle passed host preflight, or the user chose to use it
    /// without.
    var isReady: Bool {
        guard let active else {
            return false
        }
        return active.preflight == .passed || isAccepted(active.version)
    }

    var isInstalling: Bool {
        guard let progress else {
            return false
        }
        return progress.error == nil && !progress.isFinished
    }

    // MARK: - Accepted versions

    /// Versions whose failed preflight the user chose to skip.
    private var acceptedVersions: Set<String> {
        get {
            access(keyPath: \.acceptedVersions)
            return Set(UserDefaults.standard.stringArray(forKey: Self.acceptedVersionsKey) ?? [])
        }
        set {
            withMutation(keyPath: \.acceptedVersions) {
                UserDefaults.standard.set(newValue.sorted(), forKey: Self.acceptedVersionsKey)
            }
        }
    }

    func isAccepted(_ version: String) -> Bool {
        acceptedVersions.contains(version)
    }

    func setAccepted(_ version: String, _ isAccepted: Bool) {
        if isAccepted {
            acceptedVersions.insert(version)
        } else {
            acceptedVersions.remove(version)
        }
    }

    /// The newest release that is not installed yet, if it is newer than
    /// everything installed.
    var availableUpdate: VPhoneLaunchpadRelease? {
        guard let latest = releases.first, !installed.contains(where: { $0.version == latest.version }) else {
            return nil
        }
        return latest
    }

    func commandLine() -> VPhoneLaunchpadCommandLine? {
        guard let version = activeVersion else {
            return nil
        }
        return VPhoneLaunchpadCommandLine(
            executable: VPhoneLaunchpadBundleStore.executable(version: version, named: "vphone-cli"),
            history: history,
        )
    }

    // MARK: - Refresh

    func refresh() async {
        await checkActive()
        await fetchReleases()
        await fetchArtifacts()
    }

    /// Rereads the store and checks the active bundle again. A bundle that
    /// passed keeps showing so while the check runs.
    func checkActive() async {
        loadInstalled()
        if let version = activeVersion {
            await verify(version, showsProgress: false)
        }
    }

    func fetchReleases() async {
        do {
            releases = try await VPhoneLaunchpadRelease.fetch()
            releasesError = nil
        } catch {
            releasesError = error.localizedDescription
        }
    }

    func fetchArtifacts() async {
        do {
            artifacts = try await VPhoneLaunchpadArtifact.fetch(token: VPhoneLaunchpadGitHubToken.load())
            artifactsError = nil
        } catch {
            artifactsError = error.localizedDescription
        }
    }

    /// An empty token removes the saved one.
    func setGitHubToken(_ token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if token.isEmpty {
                VPhoneLaunchpadGitHubToken.delete()
            } else {
                try VPhoneLaunchpadGitHubToken.save(token)
            }
        } catch {
            actionError = error as? VPhoneLaunchpadError
                ?? VPhoneLaunchpadError(String(localized: "Unable to save the token in the keychain."), detail: error.localizedDescription)
        }
        hasGitHubToken = VPhoneLaunchpadGitHubToken.load() != nil
    }

    private func loadInstalled() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: VPhoneLaunchpadBundleStore.root.path)) ?? []
        let receipts = names
            .filter(VPhoneLaunchpadNames.isValidVersion)
            .compactMap(VPhoneLaunchpadBundleReceipt.load)
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        installed = receipts.map { receipt in
            var item = installed.first { $0.version == receipt.version && $0.receipt == receipt }
                ?? Installed(receipt: receipt)
            if !VPhoneLaunchpadNames.isCompatibleBundleVersion(receipt.version) {
                item.policy = .failed
                item.preflight = .failed
                item.preflightDetail = String(localized: "Requires VPhone.bundle \(VPhoneLaunchpadNames.minimumBundleVersion) or newer.")
            }
            return item
        }
    }

    /// Adds the execution policy exception, allows an AMFI-refused VM through
    /// the root helper, and runs host preflight again for confirmation.
    /// Without `showsProgress`, a bundle that passed before is not marked
    /// running meanwhile.
    func verify(_ version: String, showsProgress: Bool = true) async {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else {
            update(version) {
                $0.policy = .failed
                $0.preflight = .failed
                $0.preflightDetail = String(localized: "Requires VPhone.bundle \(VPhoneLaunchpadNames.minimumBundleVersion) or newer.")
            }
            return
        }
        defer { recordCheck(version) }
        update(version) {
            if showsProgress || $0.policy != .passed || $0.preflight != .passed {
                $0.policy = .running
                $0.preflight = .running
            }
        }
        let bundle = VPhoneLaunchpadBundleStore.bundle(version: version)
        do {
            try EPExecutionPolicy().addException(for: bundle)
            update(version) {
                $0.policy = .passed
                $0.policyDetail = "exception"
            }
        } catch {
            update(version) {
                $0.policy = .failed
                $0.policyDetail = "no exception"
            }
        }

        let commandLine = VPhoneLaunchpadCommandLine(
            executable: VPhoneLaunchpadBundleStore.executable(version: version, named: "vphone-cli"),
            history: history,
        )
        do {
            try await Task.detached { try VPhoneLaunchpadHostPolicy.requireReady() }.value
            var result = try await commandLine.run(["host", "preflight", "--quiet"])
            if result.lines.contains(where: { $0.hasPrefix("Error: AMFI blocked vphone-vm") }) {
                try await helper.allowVirtualMachine(bundleVersion: version)
                result = try await commandLine.run(["host", "preflight", "--quiet"])
            }
            let failure = result.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            update(version) {
                $0.preflight = result.succeeded ? .passed : .failed
                $0.preflightDetail = result.succeeded
                    ? String(localized: "Passed")
                    : (failure.isEmpty ? String(localized: "Preflight failed") : failure)
                    .replacingOccurrences(of: "Error: ", with: "")
            }
        } catch {
            update(version) {
                $0.preflight = .failed
                $0.preflightDetail = error.localizedDescription
            }
        }
    }

    private func update(_ version: String, _ change: (inout Installed) -> Void) {
        if let index = installed.firstIndex(where: { $0.version == version }) {
            change(&installed[index])
        }
    }

    // MARK: - Install

    func install(_ release: VPhoneLaunchpadRelease) async {
        progress = InstallProgress(release: release)
        var archive: URL?
        defer {
            if let archive {
                try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            }
        }
        do {
            set(.download, .running)
            let (file, digest) = try await release.download { received in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.progress?.received = received }
                }
            }
            archive = file
            set(.download, .passed)

            set(.verify, .running)
            guard digest == release.sha256.lowercased() else {
                throw VPhoneLaunchpadError(
                    String(localized: "The download could not be verified. Try again."),
                    detail: String(localized: "Expected \(release.sha256)\nReceived \(digest)"),
                )
            }
            set(.verify, .passed)

            try await installAndVerify(version: release.version, archive: file, sha256: release.sha256)
        } catch {
            fail(error)
        }
    }

    /// Installs a VPhone.bundle folder or .zip built on this Mac as
    /// `<version>-local`.
    func installLocal(_ source: URL) async {
        progress = InstallProgress(local: source)
        var work: URL?
        defer {
            if let work {
                try? FileManager.default.removeItem(at: work)
            }
        }
        do {
            set(.prepare, .running)
            let local = try await VPhoneLaunchpadLocalBundle.prepare(source)
            work = local.workDirectory
            progress?.version = local.version
            set(.prepare, .passed)

            try await installAndVerify(version: local.version, archive: local.archive, sha256: local.sha256)
        } catch {
            fail(error)
        }
    }

    /// Installs the bundle inside a GitHub Actions artifact as
    /// `<version>-ci.<commit>`. The artifact is checked against the digest
    /// GitHub published; the bundle zip inside it is then handed over like a
    /// local build.
    func installArtifact(_ artifact: VPhoneLaunchpadArtifact) async {
        progress = InstallProgress(artifact: artifact)
        var archive: URL?
        var work: URL?
        defer {
            if let archive {
                try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
            }
            if let work {
                try? FileManager.default.removeItem(at: work)
            }
        }
        do {
            guard let token = VPhoneLaunchpadGitHubToken.load() else {
                throw VPhoneLaunchpadError(String(localized: "Add a GitHub token to download builds from GitHub Actions."))
            }
            set(.download, .running)
            let (file, digest) = try await artifact.download(token: token) { received in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.progress?.received = received }
                }
            }
            archive = file
            set(.download, .passed)

            set(.verify, .running)
            guard digest == artifact.sha256.lowercased() else {
                throw VPhoneLaunchpadError(
                    String(localized: "The download could not be verified. Try again."),
                    detail: String(localized: "Expected \(artifact.sha256)\nReceived \(digest)"),
                )
            }
            set(.verify, .passed)

            set(.prepare, .running)
            let bundleArchive = try await VPhoneLaunchpadArtifact.bundleArchive(in: file)
            let local = try await VPhoneLaunchpadLocalBundle.prepare(bundleArchive, suffix: artifact.versionSuffix)
            work = local.workDirectory
            progress?.version = local.version
            set(.prepare, .passed)

            try await installAndVerify(version: local.version, archive: local.archive, sha256: local.sha256)
        } catch {
            fail(error)
        }
    }

    /// The steps every source shares: the helper installs the
    /// archive as root, then the new version becomes active and is checked.
    private func installAndVerify(version: String, archive: URL, sha256: String) async throws {
        set(.install, .running)
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        try await helper.installBundle(version: version, archive: handle, sha256: sha256)
        set(.install, .passed)

        loadInstalled()
        activeVersion = version
        try await checkInstalled(version)
    }

    /// The policy exception and host preflight for a bundle already in the
    /// store.
    private func checkInstalled(_ version: String) async throws {
        set(.policy, .running)
        set(.preflight, .running)
        await verify(version)
        let installed = installed.first { $0.version == version }
        set(.policy, installed?.policy ?? .failed)
        set(.preflight, installed?.preflight ?? .failed)
        if installed?.preflight != .passed {
            throw VPhoneLaunchpadError(
                String(localized: "Host preflight failed. Fix the issue and retry, or skip to use this version anyway."),
                detail: installed?.preflightDetail,
            )
        }
    }

    private func fail(_ error: Error) {
        for step in InstallStep.allCases where progress?.status(step) == .running {
            set(step, .failed)
        }
        progress?.error = error as? VPhoneLaunchpadError
            ?? VPhoneLaunchpadError(String(localized: "Unable to install the bundle. Try again."), detail: error.localizedDescription)
    }

    // MARK: - Retry and skip

    /// Runs the failed install again. Once the bundle is in the store only
    /// the checks after it run again; before that the whole install starts
    /// over, since a download does not outlive the attempt.
    func retry() async {
        guard let progress, !isInstalling else {
            return
        }
        if progress.status(.install) == .passed, let version = progress.version,
           installed.contains(where: { $0.version == version })
        {
            self.progress?.error = nil
            do {
                try await checkInstalled(version)
            } catch {
                fail(error)
            }
            return
        }
        switch progress.source {
        case let .release(release):
            await install(release)
        case let .artifact(artifact):
            await installArtifact(artifact)
        case let .local(path):
            await installLocal(URL(fileURLWithPath: path))
        }
    }

    /// Accepts a bundle whose policy exception or preflight failed, so it can
    /// be used anyway. The choice is remembered for that version.
    func skipFailedChecks() {
        guard let current = progress, current.canSkip, let version = current.version else {
            return
        }
        for step in current.plan where current.status(step) != .passed {
            set(step, .warning)
        }
        progress?.error = nil
        setAccepted(version, true)
    }

    func dismissProgress() {
        progress = nil
    }

    // MARK: - Persistence

    private static var progressFile: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("vphone-launchpad", isDirectory: true)
            .appendingPathComponent("bundle-install.json")
    }

    private static func saveProgress(_ progress: InstallProgress?) {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return
            }
        #endif
        let file = progressFile
        guard let progress else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? VPhoneLaunchpadBundleReceipt.encoder.encode(progress).write(to: file, options: .atomic)
    }

    /// A step still marked running belonged to a Launchpad that quit.
    private static func loadProgress() -> InstallProgress? {
        guard let data = try? Data(contentsOf: progressFile),
              var progress = try? VPhoneLaunchpadBundleReceipt.decoder.decode(InstallProgress.self, from: data)
        else {
            return nil
        }
        let interrupted = progress.plan.filter { progress.status($0) == .running }
        guard !interrupted.isEmpty else {
            return progress
        }
        for step in interrupted {
            progress.steps[step] = .failed
        }
        progress.error = VPhoneLaunchpadError(String(localized: "Launchpad quit before the install finished. Retry to continue."))
        return progress
    }

    private func set(_ step: InstallStep, _ status: VPhoneLaunchpadStatus) {
        progress?.steps[step] = status
    }

    // MARK: - Use and remove

    func use(_ version: String) async {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(version) else { return }
        activeVersion = version
        await verify(version)
    }

    func remove(_ version: String) async {
        do {
            try await helper.removeBundle(version: version)
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Remove VPhone.bundle \(version)"), detail: error.localizedDescription)
        }
        loadInstalled()
        if !installed.contains(where: { $0.version == version }) {
            setAccepted(version, false)
        }
    }
}

#if DEBUG
    extension VPhoneLaunchpadCoreBundle {
        func applyPreview(installing: Bool) {
            releases = VPhoneLaunchpadPreview.releases
            artifacts = VPhoneLaunchpadPreview.artifacts
            hasGitHubToken = false
            if installing {
                installed = []
                var progress = InstallProgress(release: releases[0])
                progress.steps = [.download: .running]
                progress.received = 9_400_000
                self.progress = progress
                return
            }
            var progress = InstallProgress(release: releases[1])
            progress.steps = [.download: .passed, .verify: .passed, .install: .passed, .policy: .passed, .preflight: .failed]
            progress.error = VPhoneLaunchpadError(
                String(localized: "Host preflight failed. Fix the issue and retry, or skip to use this version anyway."),
                detail: "AMFI blocked vphone-vm",
            )
            self.progress = progress
            installed = VPhoneLaunchpadPreview.releases.dropFirst().map { release in
                var bundle = Installed(receipt: VPhoneLaunchpadBundleReceipt(
                    version: release.version,
                    sha256: release.sha256,
                    installedAt: release.publishedAt.addingTimeInterval(3600),
                    cdhashes: [:],
                ))
                bundle.policy = .passed
                bundle.policyDetail = "exception"
                bundle.preflight = .passed
                bundle.preflightDetail = String(localized: "Passed")
                return bundle
            }
        }
    }
#endif
