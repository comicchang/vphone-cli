import CoreGraphics

// MARK: - Display Orientation

/// The guest interface orientation, and how the window shows it.
///
/// The guest frame buffer is always the portrait panel; a rotated interface
/// is drawn sideways into it, as on a real iPhone. The window turns the panel
/// the way the device was turned so the interface reads upright, and takes
/// the turned panel's aspect ratio.
public enum VPhoneDisplayOrientation: Int, CaseIterable, Sendable {
    case portrait = 0
    /// Interface landscape-left: the device turned clockwise.
    case landscapeLeft = 90
    case upsideDown = 180
    /// Interface landscape-right: the device turned counterclockwise.
    case landscapeRight = 270

    /// `degrees` as vphoned's `display.orientation` and `display.rotation`
    /// report it, clockwise from portrait. Any other value is nil.
    public init?(degrees: Int) {
        let normalized = ((degrees % 360) + 360) % 360
        self.init(rawValue: normalized)
    }

    /// The panel's rotation on the Mac, counterclockwise in degrees, as
    /// `NSView.frameCenterRotation` takes it: the device's clockwise turn.
    public var viewRotation: CGFloat {
        CGFloat((360 - rawValue) % 360)
    }

    /// The orientation after turning the device a quarter turn, as the
    /// Simulator's Rotate Left (⌘←) and Rotate Right (⌘→) do.
    public func turned(clockwise: Bool) -> VPhoneDisplayOrientation {
        VPhoneDisplayOrientation(degrees: rawValue + (clockwise ? 90 : -90)) ?? .portrait
    }

    public var isSideways: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }

    /// The panel's size as the window shows it.
    public func displayedSize(panel: CGSize) -> CGSize {
        isSideways ? CGSize(width: panel.height, height: panel.width) : panel
    }

    /// The window content rect after turning to this orientation: the current
    /// rect's long side becomes the side this orientation makes long, around
    /// the same center, scaled down to fit `visible` when it would not.
    public func contentRect(from current: CGRect, panel: CGSize, within visible: CGRect) -> CGRect {
        let target = displayedSize(panel: panel)
        guard target.width > 0, target.height > 0 else { return current }
        let longSide = max(current.width, current.height)
        var scale = longSide / max(target.width, target.height)
        if visible.width > 0, visible.height > 0 {
            scale = min(scale, visible.width / target.width, visible.height / target.height)
        }
        let size = CGSize(width: (target.width * scale).rounded(), height: (target.height * scale).rounded())
        var rect = CGRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2, width: size.width, height: size.height)
        if visible.width > 0, visible.height > 0 {
            rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        }
        return rect
    }
}
