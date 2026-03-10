// TXMPatcher.swift — TXM (Trusted Execution Monitor) patcher.
//
// Implements the trustcache bypass patch.
// Python source: scripts/patchers/txm.py

import Foundation

/// Patcher for TXM trustcache bypass.
///
/// Patches:
///   1. Trustcache binary-search BL → mov x0, #0
///      (in the AMFI cert verification function identified by the
///       unique constant 0x2446 loaded into w19)
public class TXMPatcher: Patcher {
    public let component = "txm"
    public let verbose: Bool

    let buffer: BinaryBuffer
    let disasm = ARM64Disassembler()
    var patches: [PatchRecord] = []

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    public func findAll() throws -> [PatchRecord] {
        patches = []
        try patchTrustcacheBypass()
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        let _ = try findAll()
        for record in patches {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) TXM patches applied]")
        }
        return patches.count
    }

    public var patchedData: Data {
        buffer.data
    }

    // MARK: - Emit

    func emit(_ offset: Int, _ patchBytes: Data, patchID: String, description: String) {
        let originalBytes = buffer.readBytes(at: offset, count: patchBytes.count)

        let beforeInsn = disasm.disassembleOne(in: buffer.original, at: offset)
        let afterInsn = disasm.disassembleOne(patchBytes, at: UInt64(offset))

        let beforeStr = beforeInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"
        let afterStr = afterInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"

        let record = PatchRecord(
            patchID: patchID,
            component: component,
            fileOffset: offset,
            virtualAddress: nil,
            originalBytes: originalBytes,
            patchedBytes: patchBytes,
            beforeDisasm: beforeStr,
            afterDisasm: afterStr,
            description: description
        )

        patches.append(record)

        if verbose {
            print("  0x\(String(format: "%06X", offset)): \(beforeStr) → \(afterStr)  [\(description)]")
        }
    }
}

// MARK: - Trustcache Bypass

extension TXMPatcher {
    // ═══════════════════════════════════════════════════════════
    //  Trustcache bypass
    //
    //  The AMFI cert verification function has a unique constant:
    //    mov w19, #0x2446  (encoded as 0x528488D3)
    //
    //  Within that function, a binary search calls a hash-compare
    //  function with SHA-1 size:
    //    mov w2, #0x14; bl <hash_cmp>; cbz w0, <match>
    //  followed by:
    //    tbnz w0, #0x1f, <lower_half>   (sign bit = search direction)
    //
    //  Patch: bl <hash_cmp> → mov x0, #0
    //    This makes cbz always branch to <match>, bypassing the
    //    trustcache lookup entirely.
    // ═══════════════════════════════════════════════════════════

    func patchTrustcacheBypass() throws {
        // Step 1: Find the unique function marker (mov w19, #0x2446)
        // Encoding: MOVZ W19, #0x2446 = 0x528488D3
        let markerBytes = ARM64.encodeU32(0x5284_88D3)
        let markerLocs = buffer.findAll(markerBytes)

        guard markerLocs.count == 1 else {
            if verbose {
                print("  [-] TXM: expected 1 'mov w19, #0x2446', found \(markerLocs.count)")
            }
            throw PatcherError.patchSiteNotFound(
                "expected exactly 1 'mov w19, #0x2446' marker, found \(markerLocs.count)"
            )
        }
        let markerOff = markerLocs[0]

        // Step 2: Find the containing function — scan back for PACIBSP
        let funcStart = findFunctionStart(from: markerOff)
        guard let funcStart else {
            if verbose {
                print("  [-] TXM: function start not found")
            }
            throw PatcherError.patchSiteNotFound("PACIBSP not found before marker at 0x\(String(format: "%X", markerOff))")
        }

        // Step 3: Within the function, find: mov w2, #0x14; bl; cbz w0; tbnz w0, #0x1f
        let funcEnd = min(funcStart + 0x2000, buffer.count)
        let funcLen = funcEnd - funcStart
        guard funcLen > 0 else {
            throw PatcherError.patchSiteNotFound("function range is empty")
        }

        let funcData = buffer.readBytes(at: funcStart, count: funcLen)
        let insns = disasm.disassemble(funcData, at: UInt64(funcStart))

        for i in 0 ..< insns.count {
            let ins = insns[i]
            guard ins.mnemonic == "mov", ins.operandString == "w2, #0x14" else { continue }
            guard i + 3 < insns.count else { continue }

            let blIns = insns[i + 1]
            let cbzIns = insns[i + 2]
            let tbnzIns = insns[i + 3]

            guard blIns.mnemonic == "bl" else { continue }
            guard cbzIns.mnemonic == "cbz", cbzIns.operandString.hasPrefix("w0") else { continue }
            guard tbnzIns.mnemonic == "tbnz" || tbnzIns.mnemonic == "tbz",
                  tbnzIns.operandString.contains("#0x1f") else { continue }

            // Found the pattern — patch the BL to mov x0, #0
            let blOffset = Int(blIns.address)
            emit(
                blOffset,
                ARM64.movX0_0,
                patchID: "txm.trustcache_bypass",
                description: "trustcache bypass: bl → mov x0, #0"
            )
            return
        }

        if verbose {
            print("  [-] TXM: binary search pattern not found in function")
        }
        throw PatcherError.patchSiteNotFound("mov w2, #0x14; bl; cbz w0; tbnz w0, #0x1f pattern not found")
    }

    // MARK: - Helpers

    /// Scan backward from `offset` (aligned to 4 bytes) for a PACIBSP instruction.
    /// Searches up to 0x200 bytes back, matching the Python implementation.
    private func findFunctionStart(from offset: Int) -> Int? {
        let pacibspU32 = ARM64.pacibspU32
        var scan = offset & ~3
        let limit = max(0, offset - 0x200)
        while scan >= limit {
            let insn = buffer.readU32(at: scan)
            if insn == pacibspU32 {
                return scan
            }
            if scan == 0 { break }
            scan -= 4
        }
        return nil
    }
}
