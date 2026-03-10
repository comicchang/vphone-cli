// FirmwarePipeline.swift — Orchestrates full boot-chain firmware patching.
//
// Swift equivalent of scripts/fw_patch.py main().
//
// Pipeline order: AVPBooter → iBSS → iBEC → LLB → TXM → Kernel → DeviceTree
//
// Variant selection (mirrors Makefile targets):
//   .regular — base patchers only
//   .dev     — TXMDevPatcher instead of TXMPatcher
//   .jb      — TXMDevPatcher + IBootJBPatcher (iBSS) + KernelJBPatcher

import Foundation

/// Orchestrates firmware patching for all boot-chain components.
///
/// The pipeline discovers firmware files inside the VM directory (mirroring
/// `find_restore_dir` + `find_file` in the Python source), loads each file,
/// delegates to the appropriate ``Patcher``, and writes the patched data back.
///
/// **IM4P handling:** The Python pipeline loads IM4P containers, extracts
/// payloads, patches them, and repackages. This Swift pipeline is designed to
/// support an identical flow via a pluggable ``FirmwareLoader`` once IM4P
/// support is implemented. Until then, raw-data loading is used directly.
public final class FirmwarePipeline {
    // MARK: - Variant

    public enum Variant: String, Sendable {
        case regular
        case dev
        case jb
    }

    // MARK: - Firmware Loader (pluggable IM4P support)

    /// Abstraction over IM4P vs raw firmware loading.
    ///
    /// When IM4P handling is ready, provide a conforming type that
    /// decompresses/extracts the payload on load and repackages on save.
    /// The default ``RawFirmwareLoader`` reads/writes plain bytes.
    public protocol FirmwareLoader {
        /// Load firmware from `url`, returning the mutable payload data.
        func load(from url: URL) throws -> Data
        /// Save patched `data` back to `url`, repackaging as needed.
        func save(_ data: Data, to url: URL) throws
    }

    /// Default loader: reads and writes raw bytes with no container handling.
    public struct RawFirmwareLoader: FirmwareLoader {
        public init() {}
        public func load(from url: URL) throws -> Data {
            try Data(contentsOf: url)
        }

        public func save(_ data: Data, to url: URL) throws {
            try data.write(to: url)
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
        /// Factory that creates the appropriate ``Patcher`` for the loaded data.
        let patcherFactory: (Data, Bool) -> any Patcher
    }

    // MARK: - Properties

    let vmDirectory: URL
    let variant: Variant
    let verbose: Bool
    let loader: any FirmwareLoader

    // MARK: - Init

    public init(
        vmDirectory: URL,
        variant: Variant = .regular,
        verbose: Bool = true,
        loader: (any FirmwareLoader)? = nil
    ) {
        self.vmDirectory = vmDirectory
        self.variant = variant
        self.verbose = verbose
        self.loader = loader ?? RawFirmwareLoader()
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

        let components = buildComponentList()
        log("[*] Patching \(components.count) boot-chain components ...")

        var allRecords: [PatchRecord] = []

        for component in components {
            let baseDir = component.inRestoreDir ? restoreDir : vmDirectory
            let fileURL = try findFile(in: baseDir, patterns: component.searchPatterns, label: component.name)

            log("\n\(String(repeating: "=", count: 60))")
            log("  \(component.name): \(fileURL.path)")
            log(String(repeating: "=", count: 60))

            // Load
            let rawData = try loader.load(from: fileURL)
            log("  format: \(rawData.count) bytes")

            // Patch
            let patcher = component.patcherFactory(rawData, verbose)
            let records = try patcher.findAll()

            guard !records.isEmpty else {
                throw PatcherError.patchSiteNotFound("\(component.name): no patches found")
            }

            let count = try patcher.apply()
            log("  [+] \(count) \(component.name) patches applied")

            // Save — retrieve the mutated buffer data from the patcher.
            let patchedData = extractPatchedData(from: patcher, fallback: rawData, records: records)
            try loader.save(patchedData, to: fileURL)
            log("  [+] saved")

            allRecords.append(contentsOf: records)
        }

        log("\n\(String(repeating: "=", count: 60))")
        log("  All \(components.count) components patched successfully! (\(allRecords.count) total patches)")
        log(String(repeating: "=", count: 60))

        return allRecords
    }

    // MARK: - Component List Builder

    /// Build the ordered component list based on the variant.
    func buildComponentList() -> [ComponentDescriptor] {
        var components: [ComponentDescriptor] = []

        // 1. AVPBooter — always present, lives in VM root
        components.append(ComponentDescriptor(
            name: "AVPBooter",
            inRestoreDir: false,
            searchPatterns: ["AVPBooter*.bin"],
            patcherFactory: { data, verbose in
                AVPBooterPatcher(data: data, verbose: verbose)
            }
        ))

        // 2. iBSS — JB variant adds nonce-skip via IBootJBPatcher
        components.append(ComponentDescriptor(
            name: "iBSS",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"],
            patcherFactory: { [variant] data, verbose in
                if variant == .jb {
                    return IBootJBPatcher(data: data, mode: .ibss, verbose: verbose)
                }
                return IBootPatcher(data: data, mode: .ibss, verbose: verbose)
            }
        ))

        // 3. iBEC — same for all variants
        components.append(ComponentDescriptor(
            name: "iBEC",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"],
            patcherFactory: { data, verbose in
                IBootPatcher(data: data, mode: .ibec, verbose: verbose)
            }
        ))

        // 4. LLB — same for all variants
        components.append(ComponentDescriptor(
            name: "LLB",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"],
            patcherFactory: { data, verbose in
                IBootPatcher(data: data, mode: .llb, verbose: verbose)
            }
        ))

        // 5. TXM — dev/jb variants use TXMDevPatcher (adds entitlements, debugger, dev-mode)
        components.append(ComponentDescriptor(
            name: "TXM",
            inRestoreDir: true,
            searchPatterns: ["Firmware/txm.iphoneos.research.im4p"],
            patcherFactory: { [variant] data, verbose in
                if variant == .dev || variant == .jb {
                    return TXMDevPatcher(data: data, verbose: verbose)
                }
                return TXMPatcher(data: data, verbose: verbose)
            }
        ))

        // 6. Kernel — JB variant uses KernelJBPatcher (84 patches)
        components.append(ComponentDescriptor(
            name: "kernelcache",
            inRestoreDir: true,
            searchPatterns: ["kernelcache.research.vphone600"],
            patcherFactory: { [variant] data, verbose in
                if variant == .jb {
                    return KernelJBPatcher(data: data, verbose: verbose)
                }
                return KernelPatcher(data: data, verbose: verbose)
            }
        ))

        // 7. DeviceTree — same for all variants (stub patcher for now)
        components.append(ComponentDescriptor(
            name: "DeviceTree",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/DeviceTree.vphone600ap.im4p"],
            patcherFactory: { data, verbose in
                DeviceTreePatcherAdapter(data: data, verbose: verbose)
            }
        ))

        return components
    }

    // MARK: - File Discovery

    /// Find the `*Restore*` subdirectory inside the VM directory.
    /// Mirrors Python `find_restore_dir`.
    func findRestoreDirectory() throws -> URL {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: vmDirectory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.lastPathComponent.contains("Restore") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let restoreDir = contents.first else {
            throw PatcherError.fileNotFound("No *Restore* directory found in \(vmDirectory.path). Run prepare_firmware first.")
        }
        return restoreDir
    }

    /// Find a firmware file by trying glob-style patterns under `baseDir`.
    /// Mirrors Python `find_file`.
    func findFile(in baseDir: URL, patterns: [String], label: String) throws -> URL {
        let fm = FileManager.default
        for pattern in patterns {
            let candidate = baseDir.appendingPathComponent(pattern)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let searched = patterns.map { baseDir.appendingPathComponent($0).path }.joined(separator: "\n    ")
        throw PatcherError.fileNotFound("\(label) not found. Searched:\n    \(searched)")
    }

    // MARK: - Data Extraction

    /// Extract the patched data from a patcher's internal buffer.
    ///
    /// All current patchers own a ``BinaryBuffer`` whose `.data` property
    /// holds the mutated bytes after `apply()`. We use protocol-based
    /// access where possible and fall back to manual patch application.
    func extractPatchedData(from patcher: any Patcher, fallback: Data, records: [PatchRecord]) -> Data {
        // Try known patcher types that expose their buffer.
        if let avp = patcher as? AVPBooterPatcher { return avp.buffer.data }
        if let iboot = patcher as? IBootPatcher { return iboot.buffer.data }
        if let txm = patcher as? TXMPatcher { return txm.buffer.data }
        if let kp = patcher as? KernelPatcher { return kp.buffer.data }
        if let kjb = patcher as? KernelJBPatcher { return kjb.buffer.data }
        if let dt = patcher as? DeviceTreePatcherAdapter { return dt.buffer.data }

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

// MARK: - DeviceTree Patcher Adapter

/// Adapter that wraps DeviceTree patching behind the ``Patcher`` protocol.
///
/// The real ``DeviceTreePatcher`` is currently a stub enum. This adapter
/// provides a conforming type so the pipeline can include DeviceTree in the
/// component list. Replace the body once `DeviceTreePatcher` is implemented.
final class DeviceTreePatcherAdapter: Patcher {
    let component = "devicetree"
    let verbose: Bool
    let buffer: BinaryBuffer

    init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    func findAll() throws -> [PatchRecord] {
        // DeviceTree patching is not yet migrated to Swift.
        // Return an empty array; the pipeline will throw patchSiteNotFound
        // unless the caller skips validation for stubs.
        []
    }

    @discardableResult
    func apply() throws -> Int {
        let records = try findAll()
        for record in records {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        return records.count
    }
}
