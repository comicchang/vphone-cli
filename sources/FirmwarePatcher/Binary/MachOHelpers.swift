// MachOHelpers.swift — Mach-O parsing utilities for firmware patching.

import Foundation
import MachOKit

// MARK: - Segment/Section Info

/// Minimal segment info extracted from a Mach-O binary.
public struct MachOSegmentInfo: Sendable {
    public let name: String
    public let vmAddr: UInt64
    public let vmSize: UInt64
    public let fileOffset: UInt64
    public let fileSize: UInt64
}

/// Minimal section info extracted from a Mach-O binary.
public struct MachOSectionInfo: Sendable {
    public let segmentName: String
    public let sectionName: String
    public let address: UInt64
    public let size: UInt64
    public let fileOffset: UInt32
}

// MARK: - MachO Parser

/// Mach-O parsing utilities for kernel/firmware binary analysis.
public enum MachOParser {
    /// Parse all segments from a Mach-O binary in a Data buffer.
    public static func parseSegments(from data: Data) -> [MachOSegmentInfo] {
        var segments: [MachOSegmentInfo] = []
        guard data.count > 32 else { return segments }

        let magic: UInt32 = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard magic == 0xFEED_FACF else { return segments } // MH_MAGIC_64

        let ncmds: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        var offset = 32 // sizeof(mach_header_64)

        for _ in 0 ..< ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            let cmdsize: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }

            if cmd == 0x19 { // LC_SEGMENT_64
                let nameData = data[offset + 8 ..< offset + 24]
                let name = String(data: nameData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                let vmAddr: UInt64 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 24, as: UInt64.self) }
                let vmSize: UInt64 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 32, as: UInt64.self) }
                let fileOff: UInt64 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 40, as: UInt64.self) }
                let fileSize: UInt64 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 48, as: UInt64.self) }

                segments.append(MachOSegmentInfo(
                    name: name, vmAddr: vmAddr, vmSize: vmSize,
                    fileOffset: fileOff, fileSize: fileSize
                ))
            }
            offset += Int(cmdsize)
        }
        return segments
    }

    /// Parse all sections from a Mach-O binary.
    /// Returns a dictionary keyed by "segment,section".
    public static func parseSections(from data: Data) -> [String: MachOSectionInfo] {
        var sections: [String: MachOSectionInfo] = [:]
        guard data.count > 32 else { return sections }

        let magic: UInt32 = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard magic == 0xFEED_FACF else { return sections }

        let ncmds: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        var offset = 32

        for _ in 0 ..< ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            let cmdsize: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }

            if cmd == 0x19 { // LC_SEGMENT_64
                let segNameData = data[offset + 8 ..< offset + 24]
                let segName = String(data: segNameData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                let nsects: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 64, as: UInt32.self) }

                var sectOff = offset + 72 // sizeof(segment_command_64) header
                for _ in 0 ..< nsects {
                    guard sectOff + 80 <= data.count else { break }
                    let sectNameData = data[sectOff ..< sectOff + 16]
                    let sectName = String(data: sectNameData, encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                    let addr: UInt64 = data.withUnsafeBytes { $0.load(fromByteOffset: sectOff + 32, as: UInt64.self) }
                    let size: UInt64 = data.withUnsafeBytes { $0.load(fromByteOffset: sectOff + 40, as: UInt64.self) }
                    let fileOff: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: sectOff + 48, as: UInt32.self) }

                    let key = "\(segName),\(sectName)"
                    sections[key] = MachOSectionInfo(
                        segmentName: segName, sectionName: sectName,
                        address: addr, size: size, fileOffset: fileOff
                    )
                    sectOff += 80
                }
            }
            offset += Int(cmdsize)
        }
        return sections
    }

    /// Convert a virtual address to a file offset using segment mappings.
    public static func vaToFileOffset(_ va: UInt64, segments: [MachOSegmentInfo]) -> Int? {
        for seg in segments {
            if va >= seg.vmAddr, va < seg.vmAddr + seg.vmSize {
                return Int(seg.fileOffset + (va - seg.vmAddr))
            }
        }
        return nil
    }

    /// Convert a virtual address to a file offset by parsing segments from data.
    public static func vaToFileOffset(_ va: UInt64, in data: Data) -> Int? {
        let segments = parseSegments(from: data)
        return vaToFileOffset(va, segments: segments)
    }

    /// Parse LC_SYMTAB information.
    /// Returns (symoff, nsyms, stroff, strsize) or nil.
    public static func parseSymtab(from data: Data) -> (symoff: Int, nsyms: Int, stroff: Int, strsize: Int)? {
        guard data.count > 32 else { return nil }

        let ncmds: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        var offset = 32

        for _ in 0 ..< ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            let cmdsize: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }

            if cmd == 0x02 { // LC_SYMTAB
                let symoff: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 8, as: UInt32.self) }
                let nsyms: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: UInt32.self) }
                let stroff: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 16, as: UInt32.self) }
                let strsize: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 20, as: UInt32.self) }
                return (Int(symoff), Int(nsyms), Int(stroff), Int(strsize))
            }
            offset += Int(cmdsize)
        }
        return nil
    }

    /// Find a symbol containing the given name fragment. Returns its virtual address.
    public static func findSymbol(containing fragment: String, in data: Data) -> UInt64? {
        guard let symtab = parseSymtab(from: data) else { return nil }

        for i in 0 ..< symtab.nsyms {
            let entryOff = symtab.symoff + i * 16 // sizeof(nlist_64)
            guard entryOff + 16 <= data.count else { break }

            let nStrx: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: entryOff, as: UInt32.self) }
            let nValue: UInt64 = data.withUnsafeBytes { $0.load(fromByteOffset: entryOff + 8, as: UInt64.self) }

            guard nStrx < symtab.strsize, nValue != 0 else { continue }

            let strStart = symtab.stroff + Int(nStrx)
            guard strStart < data.count else { continue }

            // Read null-terminated string
            var strEnd = strStart
            while strEnd < data.count, strEnd < symtab.stroff + symtab.strsize {
                if data[strEnd] == 0 { break }
                strEnd += 1
            }

            if let name = String(data: data[strStart ..< strEnd], encoding: .ascii),
               name.contains(fragment)
            {
                return nValue
            }
        }
        return nil
    }
}
