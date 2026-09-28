// VPhonePatchCatalogReport.swift — The full patch set, as text or as JSON.
//
// One report serves two readers. `vphone-cli fw patches` prints it for a person,
// and `--json` hands the same content to the Launchpad's patch editor, which
// renders it as the checkmark list. The UI is therefore never a second copy of
// the catalogue: it shows whatever this bundle declares, including patches from a
// set the app has never heard of.
//
// The report says what each patch *is*, not whether it would land on some VM: a
// version gate is evaluated at patch time against the two OS versions, which the
// editor does not know. `applicability` is carried through so the UI can say
// "iOS 27 only" beside the box.

import FirmwarePatcher
import Foundation
import VPhonePatchKit

public struct VPhonePatchCatalogReport: Sendable {
    public let vmName: String?
    public let selection: VPhoneVirtualMachinePatchSelection
    public let activePreset: VPhonePatchPreset
    public let presets: [VPhonePatchPreset]

    public init(
        vmName: String?,
        selection: VPhoneVirtualMachinePatchSelection,
        activePreset: VPhonePatchPreset,
        presets: [VPhonePatchPreset],
    ) {
        self.vmName = vmName
        self.selection = selection
        self.activePreset = activePreset
        self.presets = presets
    }

    // MARK: - JSON

    /// One patch as the editor sees it.
    struct PatchEntry: Codable, Sendable {
        let identifier: String
        let title: String
        let summary: String
        let patchSet: String
        let patchSetName: String
        let target: String
        let applicability: String
        let bootEssential: Bool
        /// Whether the preset turns it on, before any version gate.
        let inPreset: Bool
        /// Whether this VM's own choice leaves it on.
        let enabled: Bool
    }

    struct PresetEntry: Codable, Sendable {
        let identifier: String
        let title: String
        let summary: String
        let patchSets: [String]
    }

    struct Payload: Codable, Sendable {
        let vmName: String?
        let activePreset: String
        let blockedPatches: [String]
        let allowedPatches: [String]
        let presets: [PresetEntry]
        let patches: [PatchEntry]
    }

    /// The patches a preset turns on, before any version gate.
    ///
    /// `fw set-patches` normalises a VM's record against this, so both readers of
    /// "is this patch in the preset" answer from one rule.
    public static func patchesInPreset(_ preset: VPhonePatchPreset) -> Set<String> {
        let presetSets = Set(preset.patchSets.map(\.identifier))
        var result: Set<String> = []
        for set in FirmwarePatchSetCatalog.bundled where presetSets.contains(set.identifier) {
            for patch in set.patches where preset.selection.includes(patch.identifier) {
                result.insert(patch.identifier)
            }
        }
        return result
    }

    /// Every patch every bundled set declares, not just the active preset's.
    ///
    /// The editor needs the whole catalogue to show a patch that switching preset
    /// would bring in, so `inPreset` carries the distinction rather than the list
    /// being filtered.
    func entries() -> [PatchEntry] {
        let blocked = Set(selection.blockedPatches)
        let allowed = Set(selection.allowedPatches)
        let presetSets = Set(activePreset.patchSets.map(\.identifier))
        let included = Self.patchesInPreset(activePreset)
        var result: [PatchEntry] = []
        for set in FirmwarePatchSetCatalog.bundled {
            let setIsInPreset = presetSets.contains(set.identifier)
            for patch in set.patches {
                let inPreset = included.contains(patch.identifier)
                result.append(PatchEntry(
                    identifier: patch.identifier,
                    title: patch.title,
                    summary: patch.summary,
                    patchSet: set.identifier,
                    patchSetName: set.name,
                    target: patch.target.description,
                    applicability: patch.applicability.description,
                    bootEssential: patch.bootEssential,
                    inPreset: inPreset,
                    enabled: setIsInPreset
                        && (inPreset || allowed.contains(patch.identifier))
                        && !blocked.contains(patch.identifier),
                ))
            }
        }
        return result
    }

    public func jsonText() throws -> String {
        let payload = Payload(
            vmName: vmName,
            activePreset: activePreset.identifier,
            blockedPatches: selection.blockedPatches.sorted(),
            allowedPatches: selection.allowedPatches.sorted(),
            presets: presets.map {
                PresetEntry(
                    identifier: $0.identifier,
                    title: $0.title,
                    summary: $0.summary,
                    patchSets: $0.patchSets.map(\.identifier),
                )
            },
            patches: entries(),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Text

    public func text() -> String {
        var lines: [String] = []
        if let vmName {
            lines.append("VM:     \(vmName)")
        }
        lines.append("Preset: \(activePreset.identifier) — \(activePreset.title)")
        if !activePreset.summary.isEmpty {
            lines.append("        \(activePreset.summary)")
        }
        if !selection.blockedPatches.isEmpty {
            lines.append("Off:    \(selection.blockedPatches.sorted().joined(separator: ", "))")
        }
        if !selection.allowedPatches.isEmpty {
            lines.append("On:     \(selection.allowedPatches.sorted().joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Presets:")
        for preset in presets {
            let marker = preset.identifier == activePreset.identifier ? "*" : " "
            lines.append("  \(marker) \(preset.identifier.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + " \(preset.title)")
        }

        let entries = entries()
        lines.append("")
        lines.append("Patches (\(entries.filter(\.enabled).count) of \(entries.count) on):")
        var lastSet = ""
        for entry in entries {
            if entry.patchSet != lastSet {
                lines.append("")
                lines.append("  \(entry.patchSetName)  [\(entry.patchSet)]")
                lastSet = entry.patchSet
            }
            let box = entry.enabled ? "[x]" : "[ ]"
            var notes: [String] = []
            if entry.applicability != "any" { notes.append(entry.applicability) }
            if entry.bootEssential { notes.append("boot-essential") }
            let suffix = notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"
            lines.append("    \(box) \(entry.identifier)\(suffix)")
        }
        return lines.joined(separator: "\n")
    }
}
