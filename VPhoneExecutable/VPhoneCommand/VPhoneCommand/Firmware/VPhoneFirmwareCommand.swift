import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCoreKit

struct VPhoneFirmwareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fw",
        abstract: "Firmware pipeline: prepare (download/merge IPSWs) and patch",
        subcommands: [
            VPhoneFirmwareCatalogCommand.self,
            VPhoneFirmwareInspectCommand.self,
            VPhoneFirmwarePrepareCommand.self,
            VPhoneFirmwarePatchCommand.self,
            VPhoneFirmwarePatchesCommand.self,
            VPhoneFirmwareSetPatchesCommand.self,
            VPhoneFirmwareManifestCommand.self,
            VPhoneFirmwareListCommand.self,
            VPhoneFirmwareResolveCommand.self,
            VPhoneFirmwareAEAKeyCommand.self,
            VPhoneFirmwareIM4PCreateCommand.self,
            VPhoneFirmwareIM4PExtractCommand.self,
            VPhoneFirmwareURLsCommand.self,
            VPhoneFirmwareSealToolCommand.self,
        ],
    )
}

/// Check a PCC IPSW's build identities using HTTP ranges before committing
/// space to a full download. The hybrid restore requires both device classes.
struct VPhoneFirmwareInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect a remote IPSW manifest without downloading the archive",
    )

    @Argument(help: "Remote IPSW URL") var source: String

    func run() throws {
        guard let url = URL(string: source), ["https", "http"].contains(url.scheme ?? "") else {
            throw ValidationError("Expected an HTTP(S) IPSW URL")
        }
        let data = try vphoneRunBlocking {
            let zip = try await VPhoneRemoteZip.open(url)
            return try await zip.read(zip.entry(endingWith: "BuildManifest.plist"))
        }
        guard let manifest = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any],
            let identities = manifest["BuildIdentities"] as? [[String: Any]]
        else {
            throw VPhoneRemoteZip.Error.malformed("BuildManifest.plist has no BuildIdentities")
        }
        print("\(manifest["ProductVersion"] ?? "unknown") (\(manifest["ProductBuildVersion"] ?? "unknown"))")
        for deviceClass in ["vresearch101ap", "vphone600ap"] {
            let matches = identities.filter {
                ($0["Info"] as? [String: Any])?["DeviceClass"] as? String == deviceClass
            }
            let variants = matches.compactMap {
                ($0["Info"] as? [String: Any])?["Variant"] as? String
            }
            print("\(deviceClass): \(variants.isEmpty ? "missing" : variants.joined(separator: ", "))")
        }
    }
}

// MARK: - firmware support matrix

/// Lists the available firmware using the URLs supplied by AppleDB.
///
/// Neither writes through `print`: `list` styles stdout and `resolve` styles
/// stderr, and colour is only right if each descriptor is asked separately.
struct VPhoneFirmwareListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Print the downloadable-firmware support matrix for a device",
    )

    @Option(help: "Device identifier, e.g. iPhone17,3") var device: String
    @Option(help: "Compatibility Markdown holding the 'Tested Environments' table") var readme: String

    func run() throws {
        let code = VPhoneFirmwareMatrixCommandLine.list(
            device: device,
            readmePath: readme,
            downloadURLs: ProcessInfo.processInfo.environment["DOWNLOADABLE_IPSW_URLS"] ?? "",
        )
        if code != 0 {
            throw ExitCode(code)
        }
    }
}

struct VPhoneFirmwareResolveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Resolve a version/build selector to a downloadable IPSW URL",
        discussion: """
        Prints version<TAB>build<TAB>url<TAB>status on stdout.

        Exits 2 — not 1 — when a bare version matches more than one build, so a
        caller can tell "pick a build" from "there is no such firmware". An empty
        --version or --build means unconstrained.
        """,
    )

    @Option(help: "Device identifier, e.g. iPhone17,3") var device: String
    @Option(help: "iOS version to match; empty matches any") var version: String = ""
    @Option(help: "Build to match; empty matches any") var build: String = ""
    @Option(help: "Compatibility Markdown holding the 'Tested Environments' table") var readme: String

    func run() throws {
        let code = VPhoneFirmwareMatrixCommandLine.resolve(
            device: device,
            version: version,
            build: build,
            readmePath: readme,
            downloadURLs: ProcessInfo.processInfo.environment["DOWNLOADABLE_IPSW_URLS"] ?? "",
        )
        if code != 0 {
            throw ExitCode(code)
        }
    }
}

// MARK: - manifest

/// Generates the hybrid manifest after both IPSWs are extracted and merged.
struct VPhoneFirmwareManifestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest",
        abstract: "Write the hybrid BuildManifest.plist and Restore.plist into the iPhone directory",
        discussion: """
        Merges the cloudOS boot chain (vresearch101ap, which is what the VM
        identifies as in DFU) with vphone600 runtime components and the iPhone
        OS images into a single DFU erase-install build identity.

        Both files are written into <iphone-dir>, replacing what is there.
        `fw prepare` keeps the original as iPhone-BuildManifest.plist first.
        """,
    )

    @Argument(
        help: "Extracted iPhone IPSW directory — also where the output is written",
        transform: URL.init(fileURLWithPath:),
    )
    var iPhoneDirectory: URL

    @Argument(
        help: "Extracted cloudOS IPSW directory",
        transform: URL.init(fileURLWithPath:),
    )
    var cloudOSDirectory: URL

    @Flag(name: .shortAndLong, help: "Print which identities were selected")
    var verbose = false

    func run() throws {
        try FirmwareManifest.generate(
            iPhoneDir: iPhoneDirectory,
            cloudOSDir: cloudOSDirectory,
            verbose: true,
        )
    }
}

// MARK: - catalog

struct VPhoneFirmwareCatalogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "Show the known iOS ↔ cloudOS firmware pairings (recommended per iOS build)",
    )

    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let report = VPhoneFirmwareCatalog.report
        if json {
            try print(String(decoding: JSONEncoder().encode(report), as: UTF8.self))
            return
        }
        print("Firmware catalog (\(report.device))")
        let width = report.pairings.map(\.ios.name.count).max() ?? 0
        let header = "iOS".padding(toLength: width, withPad: " ", startingAt: 0)
        print("\(header)  recommended cloudOS")
        for e in report.pairings {
            let ios = e.ios.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(ios)  \(e.recommendedCloudOS.name)")
        }
    }
}

// MARK: - prepare

struct VPhoneFirmwarePrepareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Download + merge IPSWs into a VM bundle",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(help: "GPU driver bundle from the same cloudOS build, for offline AEA recovery")
    var gpuDriverBundle: String?
    @Option(help: "Directory for downloaded IPSWs, shared by every VM (default: ~/.vphone/ipsws or $VPHONE_ROOT/ipsws)")
    var ipswCache: String?
    @Option(help: "iPhone version to resolve to an IPSW") var iphoneVersion: String?
    @Option(help: "iPhone build to resolve to an IPSW") var iphoneBuild: String?
    @Flag(help: "List downloadable IPSWs and exit") var list = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let sourceGuide = resources.base.appendingPathComponent("Documents/Guides/compatibility.md")
        let bundleGuide = resources.base.appendingPathComponent("docs/guides/compatibility.md")
        let readme = FileManager.default.fileExists(atPath: sourceGuide.path) ? sourceGuide.path : bundleGuide.path
        let needsCatalog = list || iphoneVersion != nil || iphoneBuild != nil
        let urls = if needsCatalog {
            try vphoneRunBlocking {
                try await VPhoneFirmwareIndex.restoreURLs(forDevice: "iPhone17,3")
            }.joined(separator: "\n")
        } else {
            ""
        }

        if list {
            let code = VPhoneFirmwareMatrixCommandLine.list(
                device: "iPhone17,3",
                readmePath: readme,
                downloadURLs: urls,
            )
            if code != 0 {
                throw ExitCode(code)
            }
            return
        }

        var source = iphoneSource
        if iphoneVersion != nil || iphoneBuild != nil {
            guard source == nil else {
                throw ValidationError("Use either --iphone-source or --iphone-version/--iphone-build.")
            }
            let selection = VPhoneFirmwareMatrix.selection(
                device: "iPhone17,3",
                version: iphoneVersion ?? "",
                build: iphoneBuild ?? "",
                readme: try? String(contentsOfFile: readme, encoding: .utf8),
                downloadURLs: urls,
                style: .forStream(FileHandle.standardError.fileDescriptor),
            )
            switch selection {
            case let .selected(release, _): source = release.url
            case let .ambiguous(message), let .unmatched(message):
                throw ValidationError(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        let selected = try VPhoneFirmwareSourceSelection.resolve(iphone: source, cloudos: cloudosSource)
        guard let phone = selected.iphoneSource, let cloud = selected.cloudosSource else {
            throw ValidationError("Specify both --iphone-source and --cloudos-source when running without a terminal.")
        }
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        defer {
            try? VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        }
        try VPhoneFirmwarePreparer.prepare(
            iPhoneSource: phone,
            cloudOSSource: cloud,
            gpuDriverBundle: gpuDriverBundle.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            ipswCacheDirectory: ipswCache.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
            } ?? VPhoneResources.ipswCacheDirectory(),
            bundle: bundle,
            resources: resources,
        )
        try VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
    }
}

// MARK: - patch

struct VPhoneFirmwarePatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch",
        abstract: "Patch the boot chain (native Swift FirmwarePipeline)",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(
        name: .customLong("preset"),
        help: "Patch preset to apply. Defaults to the VM's recorded choice, or standard.",
    )
    var preset: String?
    @Flag(name: .shortAndLong, help: "Suppress per-component progress") var quiet = false

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        defer {
            try? VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        }

        // An explicit --preset wins and is remembered, so `cfw install` and a
        // later re-patch agree without the flag being repeated.
        var selection = VPhonePatchPresetStore.selection(forVM: bundle.url)
        if let preset {
            selection.presetIdentifier = preset
        }
        guard let resolved = VPhonePatchPresetStore.preset(named: selection.presetIdentifier) else {
            let available = VPhonePatchPresetStore.availablePresets().map(\.identifier)
            throw ValidationError(
                "Unknown patch preset '\(selection.presetIdentifier)'. Available: \(available.joined(separator: ", "))",
            )
        }

        let pipeline = FirmwarePipeline(
            vmDirectory: bundle.url,
            variant: .jb,
            verbose: !quiet,
            noBinpack: true,
            preset: resolved,
            blockedPatches: Set(selection.blockedPatches),
            allowedPatches: Set(selection.allowedPatches),
        )
        let records = try pipeline.patchAll()

        if let plan = pipeline.resolvedPlan {
            try VPhonePatchPresetStore.write(selection, forVM: bundle.url)
            try VPhonePatchPresetStore.write(
                VPhoneVirtualMachinePatchPlan(
                    plan: plan,
                    iOSBase: pipeline.baseProductVersion,
                    cloudOS: pipeline.cloudOSProductVersion,
                ),
                forVM: bundle.url,
            )
        }

        try VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        print("[fw patch] applied \(records.count) JB patches"
            + " (preset \(selection.presetIdentifier))")
    }
}

// MARK: - patches

struct VPhoneFirmwarePatchesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patches",
        abstract: "List the patch sets, presets and individual patches this bundle can apply",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name, to report what it is set to") var name: String?
    @Option(name: .customLong("preset"), help: "Report against this preset instead of the VM's choice")
    var preset: String?
    @Flag(name: .customLong("json"), help: "Emit machine-readable output for a UI")
    var json = false

    func run() throws {
        // A VM is optional: without one, this reports what the bundle can do.
        var selection = VPhoneVirtualMachinePatchSelection()
        var vmName: String?
        if let name {
            let resolvedName = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
            vmName = resolvedName
            selection = VPhonePatchPresetStore.selection(forVM: try lib.library.bundle(named: resolvedName).url)
        }
        if let preset {
            selection.presetIdentifier = preset
        }

        let presets = VPhonePatchPresetStore.availablePresets()
        guard let active = presets.first(where: { $0.identifier == selection.presetIdentifier }) else {
            throw ValidationError(
                "Unknown patch preset '\(selection.presetIdentifier)'."
                    + " Available: \(presets.map(\.identifier).joined(separator: ", "))",
            )
        }

        let report = VPhonePatchCatalogReport(
            vmName: vmName,
            selection: selection,
            activePreset: active,
            presets: presets,
        )
        if json {
            print(try report.jsonText())
        } else {
            print(report.text())
        }
    }
}

// MARK: - set-patches

/// Records what a VM applies, without patching anything.
///
/// This is the write half of `fw patches`: the Launchpad's patch editor reads the
/// JSON, composes the checkmarks onto the preset, and hands the difference back
/// here. Keeping it a verb of its own means the app never writes into a VM bundle
/// itself, and a person can make the same edit from a terminal.
struct VPhoneFirmwareSetPatchesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-patches",
        abstract: "Record which patches a VM applies, for the next fw patch",
        discussion: """
        Replaces the VM's PatchSelection.plist. Every run writes the whole record:
        --block and --allow name the complete lists, so a run naming neither drops
        the VM's overrides and it follows its preset again.

        Only differences from the preset are stored. An identifier the preset
        already agrees with is dropped, so a later preset revision still reaches a
        VM whose boxes were never touched.

        Nothing is patched here. The choice applies the next time `fw patch` runs
        for the VM, and `cfw install` follows the plan that run records.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(
        name: .customLong("preset"),
        help: "Preset the choice composes onto. Defaults to the VM's recorded preset.",
    )
    var preset: String?
    @Option(
        name: .customLong("block"),
        help: ArgumentHelp("A patch the preset turns on that this VM leaves off", valueName: "patch"),
    )
    var block: [String] = []
    @Option(
        name: .customLong("allow"),
        help: ArgumentHelp("A patch the preset leaves off that this VM turns on", valueName: "patch"),
    )
    var allow: [String] = []

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)

        var selection = VPhonePatchPresetStore.selection(forVM: bundle.url)
        if let preset {
            selection.presetIdentifier = preset
        }
        guard let resolved = VPhonePatchPresetStore.preset(named: selection.presetIdentifier) else {
            let available = VPhonePatchPresetStore.availablePresets().map(\.identifier)
            throw ValidationError(
                "Unknown patch preset '\(selection.presetIdentifier)'. Available: \(available.joined(separator: ", "))",
            )
        }

        let declarations = FirmwarePatchSetCatalog.allDeclarations
        let declared = Set(declarations.map(\.identifier))
        // A typo would otherwise write a list that turns nothing on or off.
        let unknown = Set(block + allow).subtracting(declared).sorted()
        guard unknown.isEmpty else {
            throw ValidationError(
                "No patch declares \(unknown.joined(separator: ", ")). Run `fw patches` for the identifiers.",
            )
        }
        let contradictory = Set(block).intersection(allow).sorted()
        guard contradictory.isEmpty else {
            throw ValidationError(
                "\(contradictory.joined(separator: ", ")) cannot be both blocked and allowed.",
            )
        }

        // Only differences reach the plist, whatever the caller passed.
        let included = VPhonePatchCatalogReport.patchesInPreset(resolved)
        selection.blockedPatches = Set(block).intersection(included).sorted()
        selection.allowedPatches = Set(allow).subtracting(included).sorted()

        let essential = Set(declarations.filter(\.bootEssential).map(\.identifier))
        let essentialOff = Set(selection.blockedPatches).intersection(essential).sorted()
        if !essentialOff.isEmpty {
            FileHandle.standardError.write(Data(
                ("warning: \(essentialOff.count) boot-essential patch(es) are off — the VM may not boot: "
                    + "\(essentialOff.joined(separator: ", "))\n").utf8,
            ))
        }

        try VPhonePatchPresetStore.write(selection, forVM: bundle.url)
        try VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        print("[fw set-patches] \(name): preset \(selection.presetIdentifier)"
            + ", \(selection.blockedPatches.count) off, \(selection.allowedPatches.count) on")
    }
}
