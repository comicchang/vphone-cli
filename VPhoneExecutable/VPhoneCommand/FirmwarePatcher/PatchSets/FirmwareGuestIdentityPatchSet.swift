// FirmwareGuestIdentityPatchSet.swift — Manifest for what the guest sees of itself.
//
// The shared-cache half of the hypervisor concealment that the kernel set starts,
// plus the camera symbols the virtual camera is published through. These pair with
// `com.vphone.patchset.kernel.hypervisor` and the device tree's camera nodes: on
// their own, each half leaves the guest inconsistent with itself.
//
// `hv_vmm_dsc` is therefore off in `standard` for exactly the reason its kernel
// half is — see `FirmwareKernelHypervisorPatchSet` for what a 26.4 guest does when
// the OID is renamed. The watchdogd patch beside it is not part of that pair and
// stays on: it stops watchdogd acting on a cached positive answer, which is
// harmless when the sysctl still reads true.

import Foundation
import VPhonePatchKit

public enum FirmwareGuestIdentityPatchSet {
    public static let identifier = "com.vphone.patchset.guest.identity"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Guest Identity",
        summary: "Hypervisor concealment in the shared cache and watchdog, plus the virtual camera symbols",
        patches: [
            VPhonePatchDeclaration(
                identifier: "hv_vmm_dsc",
                title: "Shared cache hypervisor strings",
                summary: """
                Mangles the hv_vmm_present references in the shared cache, so a userland check \
                finds nothing where the kernel set renamed the sysctl. Off by default, and \
                pointless without kernelcache_exp.hv_vmm: enable the two together or neither.
                """,
                target: .dyldSharedCache,
            ),
            VPhonePatchDeclaration(
                identifier: "watchdogd.hv_vmm_cache",
                title: "watchdogd hypervisor cache",
                summary: "Stops watchdogd caching a positive hypervisor answer and acting on it.",
                target: .guestExecutable(path: "/usr/libexec/watchdogd"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "camera_dsc",
                title: "Camera shared cache symbols",
                summary: "Redirects the camera symbols the virtual camera publishes frames through.",
                target: .dyldSharedCache,
            ),
        ],
        requires: ["vphone.guest.system"],
        provides: ["vphone.guest.identity"],
        after: ["vphone.guest.system"],
    )
}
