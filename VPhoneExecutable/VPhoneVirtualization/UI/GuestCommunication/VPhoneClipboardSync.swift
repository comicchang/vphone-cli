import AppKit
import Foundation
import VPhoneCoreKit

// MARK: - Clipboard Sync

/// ⌘C, ⌘X and ⌘V in the VM window carry the clipboard through vphoned.
/// Paste sends a changed Mac clipboard to the guest before the guest pastes;
/// copy and cut bring the guest clipboard back once the guest has written it.
/// Only small text and images are synced (`VPhoneClipboardTransfer`).
@MainActor
final class VPhoneClipboardSync {
    private weak var control: VPhoneGuestControl?
    /// The Mac clipboard as last sent to or written from the guest. An
    /// unchanged Mac clipboard is not sent again, so a guest copy made by
    /// touch is not overwritten by an older Mac one.
    private var syncedMacChangeCount: Int?
    private var copyTask: Task<Void, Never>?

    /// How long copy waits for the guest to write its clipboard.
    private static let copyPolls = 20
    private static let copyPollInterval: Duration = .milliseconds(100)

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    var isAvailable: Bool {
        guard let control else { return false }
        return control.isConnected && control.guestCapabilities.contains("clipboard")
    }

    // MARK: - Actions

    func paste() {
        guard let control else { return }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let payload = changeCount == syncedMacChangeCount ? nil : Self.macPayload(from: pasteboard)
        Task {
            if let payload {
                do {
                    switch payload {
                    case let .text(text): try await control.clipboardSet(text: text)
                    case let .image(data): try await control.clipboardSet(imageData: data)
                    }
                    syncedMacChangeCount = changeCount
                } catch {
                    print("[clipboard] Mac to guest: \(error)")
                }
            }
            Self.sendChord(usage: Self.usageV, to: control)
        }
    }

    func copy(cut: Bool) {
        guard let control else { return }
        copyTask?.cancel()
        copyTask = Task {
            // The count read before the key, so any later change is this copy.
            let before = try? await control.clipboardInfoAfterQueuedInput().changeCount
            Self.sendChord(usage: cut ? Self.usageX : Self.usageC, to: control)
            guard let before else { return }
            for _ in 0 ..< Self.copyPolls {
                try? await Task.sleep(for: Self.copyPollInterval)
                guard !Task.isCancelled else { return }
                guard let info = try? await control.clipboardInfoAfterQueuedInput(),
                      info.changeCount != before
                else { continue }
                await writeToMac(info, control: control)
                return
            }
        }
    }

    // MARK: - Guest to Mac

    private func writeToMac(_ info: VPhoneGuestControl.ClipboardContent, control: VPhoneGuestControl) async {
        let pasteboard = NSPasteboard.general
        switch VPhoneClipboardTransfer.guestKind(text: info.text, hasImage: info.hasImage) {
        case .text:
            guard let text = info.text, VPhoneClipboardTransfer.fits(text: text) else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .image:
            guard let png = try? await control.clipboardImagePNG(),
                  VPhoneClipboardTransfer.fits(image: png)
            else { return }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        case nil:
            return
        }
        syncedMacChangeCount = pasteboard.changeCount
    }

    // MARK: - Mac to Guest

    private enum Payload {
        case text(String)
        case image(Data)
    }

    private static func macPayload(from pasteboard: NSPasteboard) -> Payload? {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        switch VPhoneClipboardTransfer.macKind(types: types) {
        case .text:
            guard let text = pasteboard.string(forType: .string), VPhoneClipboardTransfer.fits(text: text)
            else { return nil }
            return .text(text)
        case let .image(type):
            guard var data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else { return nil }
            if !VPhoneClipboardTransfer.guestImageTypes.contains(type) {
                guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                else { return nil }
                data = png
            }
            return VPhoneClipboardTransfer.fits(image: data) ? .image(data) : nil
        case nil:
            return nil
        }
    }

    // MARK: - Keys

    /// Keyboard page (0x07) usages.
    private static let usageC: UInt32 = 0x06
    private static let usageV: UInt32 = 0x19
    private static let usageX: UInt32 = 0x1B
    private static let usageLeftCommand: UInt32 = 0xE3

    /// ⌘ plus one key, queued behind any input already sent.
    private static func sendChord(usage: UInt32, to control: VPhoneGuestControl) {
        control.sendHIDDown(page: 0x07, usage: usageLeftCommand)
        control.sendHIDPress(page: 0x07, usage: usage)
        control.sendHIDUp(page: 0x07, usage: usageLeftCommand)
    }
}
