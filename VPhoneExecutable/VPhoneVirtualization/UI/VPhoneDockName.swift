import AppKit
import Foundation

/// Names this process after the VM in the Dock, the app switcher and Force
/// Quit, instead of "VPhone.bundle" for every guest.
///
/// Launch Services keeps the display name per running application and only
/// exposes the setter privately; it is looked up at run time, and a missing
/// symbol leaves the bundle name in place.
enum VPhoneDockName {
    private typealias CurrentASN = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias SetInformationItem = @convention(c) (
        Int32, CFTypeRef, CFString, CFTypeRef, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?,
    ) -> OSStatus

    /// `kLSDefaultSessionID`.
    private static let defaultSession: Int32 = -2

    /// Call after the application has checked in with Launch Services, that
    /// is from `applicationDidFinishLaunching` on.
    @MainActor
    static func set(_ name: String) {
        guard !name.isEmpty,
              let handle = dlopen(nil, RTLD_NOW),
              let currentASN = dlsym(handle, "_LSGetCurrentApplicationASN"),
              let setItem = dlsym(handle, "_LSSetApplicationInformationItem"),
              let displayNameKey = dlsym(handle, "_kLSDisplayNameKey")
        else { return }
        let asn = unsafeBitCast(currentASN, to: CurrentASN.self)()?.takeUnretainedValue()
        guard let asn else { return }
        let key = displayNameKey.assumingMemoryBound(to: CFString.self).pointee
        _ = unsafeBitCast(setItem, to: SetInformationItem.self)(defaultSession, asn, key, name as CFString, nil)
    }

    /// The VM's name is its folder in the library, the one holding config.plist.
    static func name(forConfig config: URL) -> String {
        config.deletingLastPathComponent().lastPathComponent
    }
}
