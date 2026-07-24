// AVPBooterPatcher.swift — AVPBooter DGST bypass patcher.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy:
//   1. Search raw bytes for a MOVK instruction encoding 0x4447 (DGST marker)
//      as a 16-bit immediate with LSL #16.
//   2. Disassemble a local region around the hit to find the enclosing function.
//   3. Scan forward (up to 512 instructions) for the nearest RET/RETAA/RETAB.
//   4. Scan backward from RET (up to 32 instructions) for the last `mov x0, ...`
//      or conditional-select instruction writing x0/w0.
//   5. Patch that instruction to `mov x0, #0`.
//
// Note: We search raw bytes rather than disassembling the entire binary because
// AVPBooter may contain data regions that cause Capstone to stop early.

import Foundation

/// Patcher for AVPBooter DGST bypass.
public final class AVPBooterPatcher: Patcher {
    public let component = "avpbooter"
    public let verbose: Bool

    let buffer: BinaryBuffer
    let disasm = ARM64Disassembler()
    var patches: [PatchRecord] = []

    // MARK: - Constants

    /// The hex string fragment Capstone emits when an instruction encodes 0x4447
    /// (lower half of "DGST" / 0x44475354 little-endian).
    private static let dgstSearch = "0x4447"

    /// Mnemonics that write to x0/w0 via conditional selection.
    private static let cselMnemonics: Set<String> = ["cset", "csinc", "csinv", "csneg"]

    /// Mnemonics that terminate a scan region (branch or return).
    private static let stopMnemonics: Set<String> = ["ret", "retaa", "retab", "b", "bl", "br", "blr"]

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        patches = []
        try patchDGSTBypass()
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty {
            let _ = try findAll()
        }
        for record in patches {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) AVPBooter patch(es) applied]")
        }
        return patches.count
    }

    public var patchedData: Data {
        buffer.data
    }

    // MARK: - DGST Bypass
    private func patchDGSTBypass() throws {
        let data = buffer.data
        let count = data.count

        // Step 1 — search raw bytes for MOVK with imm16=0x4447, hw=01 (LSL #16).
        // MOVK <Wd>, #<imm16>, LSL #16 encoding:
        //   bits 31:23 = 011_10010_1, hw=01, imm16, Rd
        //   word & 0xFFE0_0000 == 0x72A0_0000, (word >> 5) & 0xFFFF == 0x4447
        let movkMask: UInt32  = 0xFFE0_0000
        let movkBase: UInt32  = 0x72A0_0000
        let dgstImm:  UInt32  = 0x4447

        var dgstFileOffset: Int?
        var off = 0
        while off + 4 <= count {
            let word = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
            let little = UInt32(littleEndian: word)
            if (little & movkMask) == movkBase && ((little >> 5) & 0xFFFF) == dgstImm {
                dgstFileOffset = off
                break
            }
            off += 4
        }
        guard let dgstOff = dgstFileOffset else {
            throw PatcherError.patchSiteNotFound("AVPBooter DGST: constant 0x4447 not found in binary")
        }

        // Step 2 — disassemble a local region starting from the MOVK hit.
        // We disassemble up to 2048 instructions forward to ensure we reach the RET.
        let regionStart = dgstOff
        let regionData = data[regionStart...]
        let insns = disasm.disassemble(regionData, at: UInt64(regionStart))
        guard !insns.isEmpty else {
            throw PatcherError.invalidFormat("AVPBooter: disassembly produced no instructions around DGST")
        }

        // Step 3 — scan forward from the MOVK for a RET epilogue.
        let scanEnd = min(insns.count, 512)
        guard let retIdx = insns[0 ..< scanEnd].firstIndex(where: { insn in
            insn.mnemonic == "ret" || insn.mnemonic == "retaa" || insn.mnemonic == "retab"
        }) else {
            throw PatcherError.patchSiteNotFound("AVPBooter DGST: epilogue RET not found within 512 instructions")
        }

        // Step 4 — scan backward from RET (up to 32 instructions) for x0/w0 setter.
        let backStart = max(retIdx - 32, 0)
        var x0Idx: Int? = nil

        var i = retIdx - 1
        while i >= backStart {
            let insn = insns[i]
            let mn = insn.mnemonic
            let op = insn.operandString

            if mn == "mov", op.hasPrefix("x0,") || op.hasPrefix("w0,") {
                x0Idx = i
                break
            }
            if Self.cselMnemonics.contains(mn), op.hasPrefix("x0,") || op.hasPrefix("w0,") {
                x0Idx = i
                break
            }
            // Stop if we cross a function boundary or unconditional branch.
            if Self.stopMnemonics.contains(mn) {
                break
            }
            i -= 1
        }

        guard let targetIdx = x0Idx else {
            throw PatcherError.patchSiteNotFound("AVPBooter DGST: x0 setter not found before RET")
        }

        let target = insns[targetIdx]
        let fileOff = Int(target.address)

        let originalBytes = buffer.readBytes(at: fileOff, count: 4)
        let patchedBytes = ARM64.movX0_0

        let beforeStr = "\(target.mnemonic) \(target.operandString)"
        let afterInsn = disasm.disassembleOne(patchedBytes, at: UInt64(fileOff))
        let afterStr = afterInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "mov x0, #0"

        let record = PatchRecord(
            patchID: "avpbooter.dgst_bypass",
            component: component,
            fileOffset: fileOff,
            virtualAddress: nil,
            originalBytes: originalBytes,
            patchedBytes: patchedBytes,
            beforeDisasm: beforeStr,
            afterDisasm: afterStr,
            description: "DGST validation bypass: force x0=0 return value"
        )
        patches.append(record)

        if verbose {
            print(String(format: "  0x%06X: %@ → %@  [avpbooter.dgst_bypass]",
                         fileOff, beforeStr, afterStr))
        }
    }
}
