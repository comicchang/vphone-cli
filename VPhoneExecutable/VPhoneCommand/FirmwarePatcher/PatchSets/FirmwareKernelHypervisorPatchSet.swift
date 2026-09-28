// FirmwareKernelHypervisorPatchSet.swift — Manifest for the hv_vmm rename.
//
// The guest runs under a hypervisor and the research kernel says so through an
// `hv_vmm_present` sysctl. Renaming the OID and mangling its internal caller
// hides that from the userland checks that would otherwise refuse to run, which
// is what lets stock apps start at all.
//
// Its own set because it is the one kernel change that is about hiding the
// hypervisor rather than about jailbreaking, and a preset studying VM detection
// wants it off without giving up the rest.

import Foundation
import VPhonePatchKit

public enum FirmwareKernelHypervisorPatchSet {
    public static let identifier = "com.vphone.patchset.kernel.hypervisor"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Hypervisor Concealment",
        summary: "Renames the hv_vmm_present sysctl so userland does not see the hypervisor",
        patches: [
            VPhonePatchDeclaration(
                identifier: "kernelcache_exp.hv_vmm",
                title: "hv_vmm_present sysctl",
                summary: """
                Renames the hv_vmm_present OID and mangles its internal caller, so a userland \
                check for the hypervisor finds nothing.
                """,
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
        ],
        requires: ["vphone.kernel.base"],
        provides: ["vphone.kernel.hypervisor"],
        after: ["vphone.kernel.jailbreak"],
    )
}
