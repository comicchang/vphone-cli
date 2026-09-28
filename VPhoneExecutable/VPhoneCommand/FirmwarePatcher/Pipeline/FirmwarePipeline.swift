// FirmwarePipeline.swift — Orchestrates full boot-chain firmware patching.
//
// Historical note: this file replaces the old Python firmware patcher implementation.
//
// Pipeline order: AVPBooter → iBSS → iBEC → LLB → TXM → Kernel → DeviceTree
//
// Internal variant selection:
//   .regular — base patchers only
//   .dev     — TXMDevPatcher instead of TXMPatcher
//   .jb      — TXMDevPatcher + IBootJailbreakPatcher (iBSS) + KernelJailbreakPatcher
//              + former EXP kernel and DeviceTree patches.
//   .exp     — historical internal variant, currently equivalent to JB for
//              the boot-chain patcher catalogue. Only JB is public.
//
// The component catalogue lives in FirmwarePipelineComponents.swift and the
// Restore-directory/firmware-file lookup in FirmwarePipelineDiscovery.swift.

import Darwin
import Foundation
import VPhonePatchKit

/// Orchestrates firmware patching for all boot-chain components.
///
/// The pipeline discovers firmware files inside the VM directory (mirroring
/// `find_restore_dir` + `find_file` in the Python source), loads each file,
/// delegates to the appropriate ``Patcher``, and writes the patched data back.
///
/// The default loader mirrors the Python flow: it loads IM4P containers when
/// present, patches the extracted payload, and re-packages them on save.
public final class FirmwarePipeline {
    // MARK: - Variant

    public enum Variant: String, Sendable {
        case less
        case regular
        case dev
        case jb
        case exp
    }

    // MARK: - Firmware Loader (pluggable IM4P support)

    /// Abstraction over IM4P vs raw firmware loading.
    ///
    /// Provide a conforming type to override the default IM4P/raw handling.
    public protocol FirmwareLoader {
        /// Load firmware from `url`, returning the mutable payload data.
        func load(from url: URL) throws -> Data
        /// Save patched `data` back to `url`, repackaging as needed.
        func save(_ data: Data, to url: URL) throws
    }

    /// Default loader: transparently handles IM4P containers and raw payloads.
    public struct ContainerFirmwareLoader: FirmwareLoader {
        public init() {}
        public func load(from url: URL) throws -> Data {
            try IM4PHandler.load(contentsOf: url).payload
        }

        public func save(_ data: Data, to url: URL) throws {
            let original = try IM4PHandler.load(contentsOf: url).im4p
            try IM4PHandler.save(patchedData: data, originalIM4P: original, to: url)
        }
    }

    // MARK: - Component Descriptor

    /// Describes a single firmware component in the pipeline.
    struct ComponentDescriptor {
        let name: String
        /// If true, search paths are relative to the Restore directory.
        /// If false, relative to the VM directory root.
        let inRestoreDir: Bool
        /// Glob patterns used to locate the file (tried in order).
        let searchPatterns: [String]
        /// Factories that create patchers to run in sequence for the loaded data.
        ///
        /// Throwing, because a loaded `.vphonepatchset` builds its patcher here: a
        /// set that declares a patch for this component but builds no patcher for
        /// it has to say so rather than leave the component untouched.
        let patcherFactories: [(Data, Bool) throws -> any Patcher]

        /// The same descriptor with more patchers appended after the existing ones.
        func appending(_ factories: [(Data, Bool) throws -> any Patcher]) -> ComponentDescriptor {
            guard !factories.isEmpty else { return self }
            return ComponentDescriptor(
                name: name,
                inRestoreDir: inRestoreDir,
                searchPatterns: searchPatterns,
                patcherFactories: patcherFactories + factories,
            )
        }
    }

    // MARK: - Properties

    let vmDirectory: URL
    let variant: Variant
    let verbose: Bool
    let noBinpack: Bool
    let loader: any FirmwareLoader

    /// The preset to resolve, or nil to apply every patch the variant's patchers
    /// find. Nil is what the tests use, and what keeps a directly built pipeline
    /// behaving as it did before presets existed.
    let preset: VPhonePatchPreset?
    /// The manifests `preset` resolves against.
    let patchSets: [VPhonePatchSetManifest]
    /// Per-VM patches to turn off on top of the preset.
    let blockedPatches: Set<String>
    /// Per-VM patches to turn on that the preset leaves off.
    let allowedPatches: Set<String>

    /// The `.vphonepatchset` bundles `resolvePlan` opened for this run. Empty for a
    /// preset that names only bundled sets, which is every shipped preset.
    let loadedPatchSets = FirmwareExternalPatchSets()

    /// The plan `patchAll()` resolved, once the OS versions were known. Nil until
    /// then, and nil for the whole run when no preset was given.
    public private(set) var resolvedPlan: VPhonePatchPlan?

    /// The iPhone base `ProductVersion` `patchAll()` read, if it found one.
    public private(set) var baseProductVersion: VPhoneVersion?

    /// The cloudOS `ProductVersion` `patchAll()` read, if it found one.
    public private(set) var cloudOSProductVersion: VPhoneVersion?

    // MARK: - Init

    public init(
        vmDirectory: URL,
        variant: Variant = .regular,
        verbose: Bool = true,
        noBinpack: Bool = false,
        preset: VPhonePatchPreset? = nil,
        patchSets: [VPhonePatchSetManifest] = FirmwarePatchSetCatalog.bundled,
        blockedPatches: Set<String> = [],
        allowedPatches: Set<String> = [],
        loader: (any FirmwareLoader)? = nil,
    ) {
        self.vmDirectory = vmDirectory
        self.variant = variant
        self.verbose = verbose
        self.noBinpack = noBinpack
        self.preset = preset
        self.patchSets = patchSets
        self.blockedPatches = blockedPatches
        self.allowedPatches = allowedPatches
        self.loader = loader ?? ContainerFirmwareLoader()
    }

    // MARK: - Pipeline Execution

    /// Run the full patching pipeline.
    ///
    /// Returns combined ``PatchRecord`` arrays from every component, in order.
    /// Throws on the first component that fails to patch.
    public func patchAll() throws -> [PatchRecord] {
        let restoreDir = try findRestoreDirectory()

        log("[*] VM directory:      \(vmDirectory.path)")
        log("[*] Restore directory: \(restoreDir.path)")

        // Detect the iPhone base iOS version (from the pre-hybrid manifest that
        // fw_prepare preserves — the live BuildManifest.plist reads the cloudOS
        // version, not the base). iOS 18 bases need the skywalk-netagent boot-arg.
        let baseVersion = VPhoneVersion(Self.readBaseProductVersion(restoreDir))
        baseProductVersion = baseVersion
        log("[*] iPhone base iOS:   \(baseVersion?.description ?? "unknown")")

        // Frida Stalker kernel patches only apply on cloudOS 26.4+ (where the shapes
        // were validated); older kernels are left untouched. The Frida deb install is
        // separate and version-independent.
        let cloudOSVersion = VPhoneVersion(Self.readCloudOSProductVersion(restoreDir))
        cloudOSProductVersion = cloudOSVersion
        log("[*] cloudOS kernel:    \(cloudOSVersion?.description ?? "unknown")")

        // The preset resolves here rather than in init: its version gates need the
        // two ProductVersions that were just read, and a conflict or a misnamed
        // patch must stop the run before a single byte is written.
        let plan = try resolvePlan(iOSBase: baseVersion, cloudOS: cloudOSVersion)
        resolvedPlan = plan
        let gate = plan.map { VPhonePatchGate(plan: $0) } ?? .unrestricted

        let components = buildComponentList(
            restoreDir: restoreDir,
            iOSBase: baseVersion,
            plan: plan,
            gate: gate,
        )
        log("[*] Patching \(components.count) boot-chain components ...")

        var allRecords: [PatchRecord] = []

        for component in components {
            guard !component.patcherFactories.isEmpty else {
                log("  [=] \(component.name): no patches for \(variant.rawValue)")
                continue
            }
            let baseDir = component.inRestoreDir ? restoreDir : vmDirectory
            let fileURL = try findFile(in: baseDir, patterns: component.searchPatterns, label: component.name)

            log("\n\(String(repeating: "=", count: 60))")
            log("  \(component.name): \(fileURL.path)")
            log(String(repeating: "=", count: 60))

            // Load
            let rawData = try loader.load(from: fileURL)
            log("  format: \(rawData.count) bytes")

            let (currentData, componentRecords) = try patchData(
                rawData,
                componentName: component.name,
                patcherFactories: component.patcherFactories,
                expectsPatches: expectsPatches(for: component.name, plan: plan),
            )

            // A component whose every patch the preset turned off is left exactly
            // as it was found. Re-sealing an unmodified payload would rewrite a
            // signed image for no reason.
            if componentRecords.isEmpty {
                log("  [=] unchanged, not rewritten")
            } else {
                try loader.save(currentData, to: fileURL)
                log("  [+] saved")
            }

            allRecords.append(contentsOf: componentRecords)
        }

        log("\n\(String(repeating: "=", count: 60))")
        log("  All \(components.count) components processed successfully! (\(allRecords.count) total patches)")
        log(String(repeating: "=", count: 60))

        return allRecords
    }

    func patchData(
        _ rawData: Data,
        componentName: String,
        patcherFactories: [(Data, Bool) throws -> any Patcher],
        expectsPatches: Bool = true,
    ) throws -> (Data, [PatchRecord]) {
        var currentData = rawData
        var componentRecords: [PatchRecord] = []

        for makePatcher in patcherFactories {
            let patcher = try makePatcher(currentData, verbose)
            let records = try patcher.findAll()

            guard !records.isEmpty else {
                // A patcher that found nothing is a failure — unless the preset
                // turned this component's patches off, in which case finding
                // nothing is the whole point.
                guard !expectsPatches else {
                    throw PatcherError.patchSiteNotFound("\(componentName): no patches found")
                }
                log("  [=] \(componentName): every patch is off in this preset")
                continue
            }

            let count = try patcher.apply()
            log("  [+] \(count) \(componentName) patches applied")

            componentRecords.append(contentsOf: records)
            currentData = extractPatchedData(from: patcher, fallback: currentData, records: records)
        }

        return (currentData, componentRecords)
    }

    // MARK: - Preset Resolution

    /// Resolve the preset against the versions just read, and report what it did.
    ///
    /// Returns nil when no preset was given, which leaves every patcher
    /// unrestricted.
    ///
    /// Every `.vphonepatchset` the preset names is opened here, before the plan is
    /// resolved and so before a byte is written. Opening one means reading and
    /// checking its manifest, then mapping its executable — in that order, so a set
    /// that conflicts with another or needs a newer PatchKit is refused without its
    /// code ever running.
    ///
    /// Internal rather than private so the tests can resolve a preset naming an
    /// external set without a restore tree to patch.
    func resolvePlan(iOSBase: VPhoneVersion?, cloudOS: VPhoneVersion?) throws -> VPhonePatchPlan? {
        guard let preset else { return nil }

        var available = patchSets
        for reference in preset.patchSets {
            guard case let .external(identifier, path) = reference else { continue }
            let set = try VPhonePatchSetBundle.inspect(at: URL(fileURLWithPath: path))
            try set.validate(expecting: identifier)
            try loadedPatchSets.add(set)
            available.append(set.manifest)
            log("[*] External set:      \(set.manifest.identifier) \(set.manifest.version)"
                + " (\(set.manifest.patches.count) patches) from \(set.url.path)")
        }

        let plan = try VPhonePatchPlan.resolve(
            preset: preset,
            patchSets: available,
            iOSBase: iOSBase,
            cloudOS: cloudOS,
            blocked: blockedPatches,
            allowed: allowedPatches,
        )

        log("[*] Patch preset:      \(preset.identifier)"
            + "  (\(plan.patchSets.count) sets, \(plan.enabled.count) patches on)")
        if !plan.skippedByVersion.isEmpty {
            log("[*] Not applicable:    \(plan.skippedByVersion.count) patches for other OS versions")
        }
        let blocked: [String] = plan.declarations
            .filter { !plan.enabled.contains($0.identifier) && !plan.skippedByVersion.contains($0.identifier) }
            .map(\.identifier)
            .sorted()
        if !blocked.isEmpty {
            log("[*] Turned off:        \(blocked.joined(separator: ", "))")
        }
        if !plan.droppedBootEssentials.isEmpty {
            // Allowed — an external set may be replacing them — but never quiet.
            log("[!] Boot-essential patches are off: "
                + plan.droppedBootEssentials.joined(separator: ", "))
        }
        return plan
    }

    /// Whether `componentName` should still produce at least one patch record.
    private func expectsPatches(for componentName: String, plan: VPhonePatchPlan?) -> Bool {
        guard let plan else { return true }
        guard let component = VPhoneFirmwareComponent(rawValue: componentName) else { return true }
        return plan.hasEnabledPatches(target: .firmware(component))
    }

    // MARK: - Data Extraction

    /// Extract the patched data from a patcher's internal buffer.
    ///
    /// Every patcher in this project conforms to ``BufferedPatcher`` and hands its
    /// bytes back through it. Asking through the protocol rather than downcasting
    /// to each known type is also the only way a patcher from a loaded
    /// `.vphonepatchset` can contribute anything: the pipeline has never heard of
    /// its type, and bytes it could not read would be silently dropped.
    func extractPatchedData(from patcher: any Patcher, fallback: Data, records: [PatchRecord]) -> Data {
        if let buffered = patcher as? any BufferedPatcher {
            return buffered.patchedData
        }

        // Fallback: apply records manually to a copy of the original data.
        var data = fallback
        for record in records {
            let range = record.fileOffset ..< record.fileOffset + record.patchedBytes.count
            data.replaceSubrange(range, with: record.patchedBytes)
        }
        return data
    }

    // MARK: - Logging

    func log(_ message: String) {
        if verbose {
            print(message)
        }
    }
}
