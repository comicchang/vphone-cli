import AppKit
import VPhoneCoreKit

// MARK: - Display Container

/// The window's content view. It holds the VM view turned to the guest's
/// interface orientation and fills itself with it.
///
/// The VM view keeps its portrait bounds under the turn, so touch mapping,
/// which converts window points into those bounds, needs no change: AppKit's
/// conversion undoes the rotation.
final class VPhoneDisplayContainerView: NSView {
    let displayView: NSView

    var orientation: VPhoneDisplayOrientation = .portrait {
        didSet {
            guard orientation != oldValue else { return }
            needsLayout = true
        }
    }

    init(displayView: NSView) {
        self.displayView = displayView
        super.init(frame: .zero)
        wantsLayer = true
        displayView.autoresizingMask = []
        addSubview(displayView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        // Sized unturned, then turned about its center: a quarter turn swaps
        // the frame's sides, so the turned view fills the container.
        let size = orientation.isSideways ? NSSize(width: bounds.height, height: bounds.width) : bounds.size
        displayView.frameCenterRotation = 0
        displayView.frame = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
        displayView.frameCenterRotation = orientation.viewRotation
    }
}
