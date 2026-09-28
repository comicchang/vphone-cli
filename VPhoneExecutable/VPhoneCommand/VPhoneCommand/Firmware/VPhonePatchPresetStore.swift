// VPhonePatchPresetStore.swift — Finding presets, and remembering a VM's choice.
//
// Three files matter here.
//
// `VPhone.bundle/Contents/Resources/patches_presets/*.plist` are the presets the
// bundle ships. They are prewritten and reviewed; nothing in the tool writes one.
//
// `<vm>/PatchSelection.plist` is the VM's choice: which preset, and which patches
// the user unchecked. It is written when the VM is created or edited, and read by
// `fw patch`.
//
// `<vm>/PatchPlan.plist` is what `fw patch` actually resolved, written after the
// boot chain is patched. `cfw install` reads it so the guest half of the install
// applies the same selection the boot chain was built with, without resolving the
// preset a second time against versions that may since have changed.

import FirmwarePatcher
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

// MARK: - VM Records

/// A VM's patch choice: a preset, plus the boxes the user changed.
///
/// Only the differences from the preset are stored. A patch nobody touched follows
/// whatever the preset says, so a later preset revision reaches VMs that never
/// overrode it.
public struct VPhoneVirtualMachinePatchSelection: Codable, Sendable, Hashable {
    public var presetIdentifier: String
    /// Patches the user unchecked.
    public var blockedPatches: [String]
    /// Patches the user checked that the preset leaves off. Each still has to pass
    /// its own version gate, so checking a box cannot put a patch on an OS it was
    /// never meant for.
    public var allowedPatches: [String]

    public init(
        presetIdentifier: String = VPhonePatchPreset.standardIdentifier,
        blockedPatches: [String] = [],
        allowedPatches: [String] = [],
    ) {
        self.presetIdentifier = presetIdentifier
        self.blockedPatches = blockedPatches
        self.allowedPatches = allowedPatches
    }

    private enum CodingKeys: String, CodingKey {
        case presetIdentifier = "Preset"
        case blockedPatches = "BlockedPatches"
        case allowedPatches = "AllowedPatches"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetIdentifier = try container.decodeIfPresent(String.self, forKey: .presetIdentifier)
            ?? VPhonePatchPreset.standardIdentifier
        blockedPatches = try container.decodeIfPresent([String].self, forKey: .blockedPatches) ?? []
        allowedPatches = try container.decodeIfPresent([String].self, forKey: .allowedPatches) ?? []
    }
}

/// What `fw patch` resolved, recorded for `cfw install`.
public struct VPhoneVirtualMachinePatchPlan: Codable, Sendable, Hashable {
    public var presetIdentifier: String
    public var patchSets: [String]
    public var enabledPatches: [String]
    public var iOSBaseVersion: String?
    public var cloudOSVersion: String?
    /// The preset's knobs, carried through so `cfw install` reads the same values
    /// the boot chain was built with rather than resolving the preset again.
    public var parameters: [String: String]

    public init(plan: VPhonePatchPlan, iOSBase: VPhoneVersion?, cloudOS: VPhoneVersion?) {
        presetIdentifier = plan.presetIdentifier
        patchSets = plan.patchSets.map(\.identifier)
        enabledPatches = plan.enabled.sorted()
        iOSBaseVersion = iOSBase?.description
        cloudOSVersion = cloudOS?.description
        parameters = plan.parameters
    }

    /// Whether the patch declaring `identifier` was turned on for this VM.
    public func isEnabled(_ identifier: String) -> Bool {
        enabledPatches.contains(identifier)
    }

    private enum CodingKeys: String, CodingKey {
        case presetIdentifier = "Preset"
        case patchSets = "PatchSets"
        case enabledPatches = "EnabledPatches"
        case iOSBaseVersion = "IOSBaseVersion"
        case cloudOSVersion = "CloudOSVersion"
        case parameters = "Parameters"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetIdentifier = try container.decode(String.self, forKey: .presetIdentifier)
        patchSets = try container.decodeIfPresent([String].self, forKey: .patchSets) ?? []
        enabledPatches = try container.decodeIfPresent([String].self, forKey: .enabledPatches) ?? []
        iOSBaseVersion = try container.decodeIfPresent(String.self, forKey: .iOSBaseVersion)
        cloudOSVersion = try container.decodeIfPresent(String.self, forKey: .cloudOSVersion)
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
    }
}

// MARK: - Store

public enum VPhonePatchPresetStore {
    public static let selectionFileName = "PatchSelection.plist"
    public static let planFileName = "PatchPlan.plist"

    // MARK: Presets

    /// Every preset available, shipped ones first.
    ///
    /// A staged bundle has `Contents/Resources/patches_presets` beside the
    /// executable. A plain Xcode build of `vphone-cli` has no such directory, so
    /// the built-in copies stand in and `fw patch` still runs.
    ///
    /// `~/.vphone/patches_presets` is added after those. It is the only place a
    /// preset naming an external `.vphonepatchset` can live: the shipped directory
    /// is inside a sealed bundle, and a shipped preset never references a set from
    /// outside it. A user preset cannot shadow a shipped one — an identifier
    /// already claimed is ignored, so nothing can redefine `standard`.
    public static func availablePresets() -> [VPhonePatchPreset] {
        var presets: [VPhonePatchPreset] = []
        if let directory = presetsDirectory(),
           let shipped = try? VPhonePatchPreset.readAll(fromDirectory: directory),
           !shipped.isEmpty
        {
            presets = shipped
        } else {
            presets = FirmwarePatchSetCatalog.builtInPresets
        }
        let claimed = Set(presets.map(\.identifier))
        if let user = try? VPhonePatchPreset.readAll(fromDirectory: userPresetsDirectory()) {
            presets.append(contentsOf: user.filter { !claimed.contains($0.identifier) })
        }
        return presets
    }

    /// `~/.vphone/patches_presets`, where a researcher's own presets go.
    public static func userPresetsDirectory() -> URL {
        VPhoneResources.userDataRoot()
            .appendingPathComponent(VPhonePatchPreset.resourceDirectoryName, isDirectory: true)
    }

    /// The preset with this identifier, or nil.
    public static func preset(named identifier: String) -> VPhonePatchPreset? {
        availablePresets().first { $0.identifier == identifier }
    }

    /// `Contents/Resources/patches_presets` beside the running executable.
    static func presetsDirectory() -> URL? {
        // Not argv[0]: a `vphone-cli` found on PATH gets a bare name there, which
        // would resolve the presets directory against the working directory.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let resources = executable
            .deletingLastPathComponent() // Contents/MacOS
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(VPhonePatchPreset.resourceDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resources.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return resources
    }

    // MARK: VM Selection

    /// The VM's recorded choice, or the standard preset when it has none.
    ///
    /// A VM created before presets existed reads as standard, which is what it was
    /// built with.
    public static func selection(forVM directory: URL) -> VPhoneVirtualMachinePatchSelection {
        let url = directory.appendingPathComponent(selectionFileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? PropertyListDecoder().decode(
                  VPhoneVirtualMachinePatchSelection.self,
                  from: data,
              )
        else {
            return VPhoneVirtualMachinePatchSelection()
        }
        return decoded
    }

    public static func write(
        _ selection: VPhoneVirtualMachinePatchSelection,
        forVM directory: URL,
    ) throws {
        try write(selection, to: directory.appendingPathComponent(selectionFileName))
    }

    // MARK: VM Plan

    /// What the last `fw patch` resolved for this VM, or nil if it never ran with
    /// a preset.
    public static func plan(forVM directory: URL) -> VPhoneVirtualMachinePatchPlan? {
        let url = directory.appendingPathComponent(planFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(VPhoneVirtualMachinePatchPlan.self, from: data)
    }

    public static func write(_ plan: VPhoneVirtualMachinePatchPlan, forVM directory: URL) throws {
        try write(plan, to: directory.appendingPathComponent(planFileName))
    }

    private static func write(_ value: some Encodable, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
