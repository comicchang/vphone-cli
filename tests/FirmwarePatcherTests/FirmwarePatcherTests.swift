// FirmwarePatcherTests.swift — Tests for ARM64 constants, encoders, and round-trip verification.

@testable import FirmwarePatcher
import Foundation
import Testing

struct ARM64ConstantTests {
    let disasm = ARM64Disassembler()

    func verifyConstant(_ data: Data, expectedMnemonic: String, file _: String = #file, line _: Int = #line) {
        let insn = disasm.disassembleOne(data, at: 0)
        #expect(insn != nil, "Failed to disassemble constant")
        #expect(insn?.mnemonic == expectedMnemonic,
                "Expected \(expectedMnemonic), got \(insn?.mnemonic ?? "nil")")
    }

    @Test func nop() {
        verifyConstant(ARM64.nop, expectedMnemonic: "nop")
    }

    @Test func ret() {
        verifyConstant(ARM64.ret, expectedMnemonic: "ret")
    }

    @Test func retaa() {
        verifyConstant(ARM64.retaa, expectedMnemonic: "retaa")
    }

    @Test func retab() {
        verifyConstant(ARM64.retab, expectedMnemonic: "retab")
    }

    @Test func pacibsp() {
        // PACIBSP is encoded as HINT #27, capstone may show it as "pacibsp" or "hint"
        let insn = disasm.disassembleOne(ARM64.pacibsp, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "pacibsp" || insn?.mnemonic == "hint")
    }

    @Test func movX0_0() {
        let insn = disasm.disassembleOne(ARM64.movX0_0, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movX0_1() {
        let insn = disasm.disassembleOne(ARM64.movX0_1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movW0_0() {
        let insn = disasm.disassembleOne(ARM64.movW0_0, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movW0_1() {
        let insn = disasm.disassembleOne(ARM64.movW0_1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func cmpW0W0() {
        verifyConstant(ARM64.cmpW0W0, expectedMnemonic: "cmp")
    }

    @Test func cmpX0X0() {
        verifyConstant(ARM64.cmpX0X0, expectedMnemonic: "cmp")
    }

    @Test func movX0X20() {
        let insn = disasm.disassembleOne(ARM64.movX0X20, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "orr")
    }

    @Test func strbW0X20_30() {
        verifyConstant(ARM64.strbW0X20_30, expectedMnemonic: "strb")
    }

    @Test func movW0_0xA1() {
        let insn = disasm.disassembleOne(ARM64.movW0_0xA1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }
}

struct ARM64EncoderTests {
    let disasm = ARM64Disassembler()

    @Test func encodeBForward() throws {
        // B from 0x1000 to 0x2000 (forward 0x1000 bytes)
        let data = ARM64Encoder.encodeB(from: 0x1000, to: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "b")
    }

    @Test func encodeBBackward() throws {
        // B from 0x2000 to 0x1000 (backward 0x1000 bytes)
        let data = ARM64Encoder.encodeB(from: 0x2000, to: 0x1000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x2000)
        #expect(insn?.mnemonic == "b")
    }

    @Test func encodeBLForward() throws {
        let data = ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "bl")
    }

    @Test func decodeBranchTarget() throws {
        // Encode a B, then decode and verify the target matches
        let from: UInt64 = 0x10000
        let to: UInt64 = 0x20000
        let data = try #require(ARM64Encoder.encodeB(from: Int(from), to: Int(to)))
        let insn: UInt32 = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let decoded = ARM64Encoder.decodeBranchTarget(insn: insn, pc: from)
        #expect(decoded == to)
    }

    @Test func encodeBOutOfRange() {
        // Try to encode a branch that's too far (> 128MB)
        let data = ARM64Encoder.encodeB(from: 0, to: 0x1000_0000)
        #expect(data == nil)
    }

    @Test func encodeADRP() throws {
        let data = ARM64Encoder.encodeADRP(rd: 0, pc: 0x1000, target: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "adrp")
    }

    @Test func encodeAddImm12() throws {
        let data = ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0x100)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0)
        #expect(insn?.mnemonic == "add")
    }
}

struct BinaryBufferTests {
    @Test func readWriteU32() {
        let data = Data(repeating: 0, count: 16)
        let buf = BinaryBuffer(data)
        buf.writeU32(at: 4, value: 0xDEAD_BEEF)
        #expect(buf.readU32(at: 4) == 0xDEAD_BEEF)
    }

    @Test func findString() {
        let testStr = "Hello, World!\0Extra"
        let data = Data(testStr.utf8)
        let buf = BinaryBuffer(data)
        let offset = buf.findString("Hello, World!")
        #expect(offset == 0)
    }

    @Test func findAll() {
        var data = Data(repeating: 0, count: 32)
        // Write NOP at offset 8 and 20
        let nop = ARM64.nop
        data.replaceSubrange(8 ..< 12, with: nop)
        data.replaceSubrange(20 ..< 24, with: nop)
        let buf = BinaryBuffer(data)
        let offsets = buf.findAll(nop)
        #expect(offsets.count == 2)
        #expect(offsets.contains(8))
        #expect(offsets.contains(20))
    }
}
