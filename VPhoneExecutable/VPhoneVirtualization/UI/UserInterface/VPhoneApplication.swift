import AppKit

// MARK: - Application

/// Offers each key press in the VM window to the main menu before the VM view
/// can take it.
///
/// `capturesSystemKeys` makes `VZVirtualMachineView` install a local event
/// monitor that sends every key to the guest and swallows it. AppKit runs
/// local monitors in the order they were added, and the view adds its own
/// again each time it becomes first responder or its window becomes key, so
/// a monitor of ours always runs after it. `sendEvent(_:)` runs before any
/// local monitor, so the menu is asked here instead.
final class VPhoneApplication: NSApplication {
    /// Keys whose key-down a menu item took. Their key-up is dropped too, so
    /// the guest never sees a release without a press.
    private var menuKeyCodes = Set<UInt16>()

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp,
              event.window?.firstResponder is VPhoneVirtualMachineView
        else {
            super.sendEvent(event)
            return
        }
        if event.type == .keyUp {
            if menuKeyCodes.remove(event.keyCode) == nil {
                super.sendEvent(event)
            }
            return
        }
        if mainMenu?.performKeyEquivalent(with: event) == true {
            menuKeyCodes.insert(event.keyCode)
            return
        }
        super.sendEvent(event)
    }
}
