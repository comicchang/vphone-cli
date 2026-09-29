import AppKit

// MARK: - Features Menu

/// Sensors the host simulates for the guest: location, battery and camera.
extension VPhoneMenuController {
    func buildFeaturesMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Features", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Features")
        menu.autoenablesItems = false
        menu.addItem(buildLocationSubmenu())
        menu.addItem(buildBatterySubmenu())
        menu.addItem(buildCameraSubmenu())
        item.submenu = menu
        return item
    }
}
