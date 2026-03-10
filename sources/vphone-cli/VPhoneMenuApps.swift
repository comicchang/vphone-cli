import AppKit
import Foundation

// MARK: - Apps Menu

extension VPhoneMenuController {
    func buildAppsMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Apps")
        menu.autoenablesItems = false

        let browse = makeItem("App Browser", action: #selector(openAppBrowser))
        browse.isEnabled = false
        appsListItem = browse
        menu.addItem(browse)

        menu.addItem(NSMenuItem.separator())

        let openURL = makeItem("Open URL...", action: #selector(openURL))
        openURL.isEnabled = false
        appsOpenURLItem = openURL
        menu.addItem(openURL)

        menu.addItem(NSMenuItem.separator())

        let install = makeItem("Install IPA/TIPA...", action: #selector(installIPAFromDisk))
        install.isEnabled = false
        installPackageItem = install
        menu.addItem(install)

        item.submenu = menu
        return item
    }

    func updateAppsAvailability(available: Bool) {
        appsListItem?.isEnabled = available
        appsOpenURLItem?.isEnabled = available
    }

    func updateInstallAvailability(available: Bool) {
        installPackageItem?.isEnabled = available
    }

    @objc func openAppBrowser() {
        onAppsPressed?()
    }

    @objc func installIPAFromDisk() {
        guard control.isConnected else {
            showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VPhoneInstallPackage.allowedContentTypes
        panel.prompt = "Install"
        panel.message = "Choose an IPA or TIPA package to install in the guest."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        Task {
            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
                showAlert(
                    title: "Install App Package",
                    message: VPhoneInstallPackage.successMessage(
                        for: url.lastPathComponent,
                        detail: result
                    ),
                    style: .informational
                )
            } catch {
                showAlert(title: "Install App Package", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func openURL() {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Enter URL to open on the guest:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        input.placeholderString = "https://example.com"
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = input.stringValue
        guard !url.isEmpty else { return }

        Task {
            do {
                try await control.openURL(url)
                showAlert(title: "Open URL", message: "Opened \(url)", style: .informational)
            } catch {
                showAlert(title: "Open URL", message: "\(error)", style: .warning)
            }
        }
    }
}
