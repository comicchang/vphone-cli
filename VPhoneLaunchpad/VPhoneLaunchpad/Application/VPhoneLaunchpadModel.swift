import Foundation
import Observation

/// Owns the host checks, the installed bundles and the machine library. The
/// window always shows the machines; Host Setup and Core Bundle are sheets
/// over it. On launch the first stage that is not ready opens by itself, and
/// a toolbar button marks a stage that regresses later.
@MainActor
@Observable
final class VPhoneLaunchpadModel {
    enum Panel: String, Identifiable {
        case hostSetup
        case coreBundle

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .hostSetup: String(localized: "Host Setup")
            case .coreBundle: String(localized: "Core Bundle")
            }
        }
    }

    let history = VPhoneLaunchpadCommandHistory()
    let helper = VPhoneLaunchpadHelperClient()
    let libraryRoot: URL
    let host: VPhoneLaunchpadHostSetup
    let bundles: VPhoneLaunchpadCoreBundle
    let machines: VPhoneLaunchpadMachineLibrary

    var panel: Panel?
    private(set) var isStarted = false

    init() {
        libraryRoot = URL(fileURLWithPath: VPhoneLaunchpadMachineLocations.defaultRoot, isDirectory: true)
        host = VPhoneLaunchpadHostSetup(helper: helper, libraryRoot: libraryRoot)
        bundles = VPhoneLaunchpadCoreBundle(helper: helper, history: history)
        machines = VPhoneLaunchpadMachineLibrary(bundles: bundles, helper: helper)
    }

    // MARK: - Attention

    var hostNeedsAttention: Bool {
        !host.isChecking && !host.requiredPassed
    }

    var bundleNeedsAttention: Bool {
        host.requiredPassed && !bundles.isReady && !bundles.isInstalling && bundles.progress?.canSkip != true
    }

    /// Installing a bundle needs the helper (root-owned store) and Developer
    /// Tools access (the execution policy exception).
    var canInstallBundles: Bool {
        guard case .ready = helper.state else {
            return false
        }
        return host.isDeveloperToolAuthorized && !bundles.isInstalling
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isStarted else {
            return
        }
        isStarted = true
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                await VPhoneLaunchpadPreview.run(self)
                return
            }
        #endif
        // Host checks, installed bundles and the helper state were read at
        // init. These confirm them without holding up the machine list; the
        // network probe and the GitHub lists come last.
        machines.startMonitoring()
        async let listed: Void = machines.refresh()
        async let hostChecked: Void = host.refresh()
        await bundles.checkActive()
        await hostChecked
        if case .outdated = helper.state {
            await host.installHelper()
            await host.refresh()
            await bundles.checkActive()
        }
        await listed
        // An unfinished install is picked up in the inspector instead.
        if panel == nil, bundles.progress == nil || bundles.progress?.isFinished == true {
            panel = !host.requiredPassed ? .hostSetup : !bundles.isReady ? .coreBundle : nil
        }
        await bundles.fetchReleases()
        await bundles.fetchArtifacts()
    }

    func refreshHost() async {
        await host.refresh()
    }

    // MARK: - Bundle install

    /// An install runs in the inspector, not in the sheet it started from,
    /// so the sheet closes and the inspector opens on its progress.
    func installBundle(_ release: VPhoneLaunchpadRelease) async {
        revealInstall()
        await bundles.install(release)
        await machines.refresh()
    }

    func installArtifact(_ artifact: VPhoneLaunchpadArtifact) async {
        revealInstall()
        await bundles.installArtifact(artifact)
        await machines.refresh()
    }

    func installLocalBundle(_ source: URL) async {
        revealInstall()
        await bundles.installLocal(source)
        await machines.refresh()
    }

    func retryInstall() async {
        await bundles.retry()
        await machines.refresh()
    }

    private func revealInstall() {
        panel = nil
        showsInspector = true
        isInstallExpanded = true
    }

    // MARK: - Inspector

    var showsInspector = true
    var isInstallExpanded = true

    func removeBundle(_ version: String) async {
        await bundles.remove(version)
        if let active = bundles.activeVersion, bundles.active?.preflight == .pending {
            await bundles.verify(active)
        }
    }
}
