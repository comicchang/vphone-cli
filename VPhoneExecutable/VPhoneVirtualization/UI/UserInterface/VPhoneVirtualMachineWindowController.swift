import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneVirtualMachineWindowController: NSObject {
    private var windowController: NSWindowController?
    private weak var control: VPhoneGuestControl?
    private weak var virtualMachineView: VPhoneVirtualMachineView?
    private(set) var touchIDMonitor: VPhoneTouchIDMonitor?
    private var menuKeyMonitor: Any?
    private var homeButton: NSButton?

    var captureView: VPhoneVirtualMachineView? {
        virtualMachineView
    }

    func showWindow(
        for vm: VZVirtualMachine,
        screenWidth: Int,
        screenHeight: Int,
        screenScale: Double,
        keySender: VPhoneVirtualMachineKeySender,
        control: VPhoneGuestControl,
        name: String,
        sceneIdentifier: String,
    ) {
        self.control = control

        let view = VPhoneVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keySender = keySender
        view.control = control
        virtualMachineView = view
        let vmView: NSView = view

        let scale = CGFloat(screenScale)
        let windowSize = NSSize(
            width: CGFloat(screenWidth) / scale,
            height: CGFloat(screenHeight) / scale,
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )

        window.isReleasedWhenClosed = false
        window.level = .normal
        VPhoneAlert.hostWindow = window
        window.contentAspectRatio = windowSize
        window.title = name
        window.contentView = vmView

        // The scene belongs to the VM, not to the app: every VM directory keeps
        // its own window frame, and a newly created VM opens centered instead
        // of inheriting the last frame another VM saved.
        let sceneName = "vphone-scene-\(sceneIdentifier)"
        window.identifier = NSUserInterfaceItemIdentifier(sceneName)
        if !window.setFrameUsingName(sceneName) {
            window.center()
        }
        window.setFrameAutosaveName(sceneName)

        // An empty unified toolbar gives the title bar its full height. The Home
        // button is a titlebar accessory rather than a toolbar item so that a
        // narrow window truncates the title instead of moving it to overflow.
        let toolbar = NSToolbar(identifier: "vphone-toolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.addTitlebarAccessoryViewController(makeHomeAccessory())
        updateHomeButton(connected: false)

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        // capturesSystemKeys lets the VM view take every shortcut before the menu
        // bar sees it. Offer each key press to the menu first; the guest gets
        // only what no enabled menu item handles.
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            let handledByMenu = MainActor.assumeIsolated {
                guard let window, event.window === window else { return false }
                return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            }
            return handledByMenu ? nil : event
        }

        keySender.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        let monitor = VPhoneTouchIDMonitor()
        monitor.start(control: control, window: window)
        touchIDMonitor = monitor

        // Poll vphoned status for the Home button
        _ = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let control = self.control else { return }
                self.updateHomeButton(connected: control.isConnected)
            }
        }
    }

    // MARK: - Home Button

    private func makeHomeAccessory() -> NSTitlebarAccessoryViewController {
        let button = NSButton(image: NSImage(), target: self, action: #selector(homePressed))
        button.bezelStyle = .toolbar
        button.toolTip = VPhoneLocalization.text("Home Button")
        button.translatesAutoresizingMaskIntoConstraints = false
        homeButton = button

        let container = NSView()
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        return accessory
    }

    /// The button presses Home through vphoned, so it is disabled and slashed
    /// while vphoned is not connected.
    private func updateHomeButton(connected: Bool) {
        guard let homeButton else { return }
        homeButton.isEnabled = connected
        homeButton.image = NSImage(
            systemSymbolName: connected ? "circle.circle" : "circle.slash",
            accessibilityDescription: VPhoneLocalization.text("Home"),
        )
    }

    // MARK: - Actions

    @objc private func homePressed() {
        control?.sendHIDPress(page: 0x0C, usage: 0x40)
    }
}
