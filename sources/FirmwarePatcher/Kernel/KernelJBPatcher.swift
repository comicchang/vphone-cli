// KernelJBPatcher.swift — JB kernel patcher orchestrator.
//
// Python source: scripts/patchers/kernel_jb.py

import Foundation

/// JB kernel patcher: 84 patches across 3 groups.
///
/// Group A: Core gate-bypass methods (5 patches)
/// Group B: Pattern/string anchored methods (16 patches)
/// Group C: Shellcode/trampoline heavy methods (4 patches)
public final class KernelJBPatcher: KernelJBPatcherBase, Patcher {
    public let component = "kernelcache_jb"

    public func findAll() throws -> [PatchRecord] {
        try parseMachO()
        buildADRPIndex()
        buildBLIndex()
        buildSymbolTable()
        findPanic()

        // Group A
        patchAmfiCdhashInTrustcache()
        patchTaskConversionEvalInternal()
        patchSandboxHooksExtended()
        patchIoucFailedMacf()

        // Group B
        patchPostValidationAdditional()
        patchProcSecurityPolicy()
        patchProcPidinfo()
        patchConvertPortToMap()
        patchBsdInitAuth()
        patchDounmount()
        patchIoSecureBsdRoot()
        patchLoadDylinker()
        patchMacMount()
        patchNvramVerifyPermission()
        patchSharedRegionMap()
        patchSpawnValidatePersona()
        patchTaskForPid()
        patchThidShouldCrash()
        patchVmFaultEnterPrepare()
        patchVmMapProtect()

        // Group C
        patchCredLabelUpdateExecve()
        patchHookCredLabelUpdateExecve()
        patchKcall10()
        patchSyscallmaskApplyToProc()

        return patches
    }

    public func apply() throws -> Int {
        let patches = try findAll()
        for record in patches {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        return patches.count
    }
}
