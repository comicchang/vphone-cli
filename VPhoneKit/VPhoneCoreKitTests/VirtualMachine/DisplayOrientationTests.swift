import CoreGraphics
import Testing
@testable import VPhoneCoreKit

struct DisplayOrientationTests {
    static let panel = CGSize(width: 393, height: 852)
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)

    // MARK: - Degrees

    @Test func `vphoned degrees map to orientations`() {
        #expect(VPhoneDisplayOrientation(degrees: 0) == .portrait)
        #expect(VPhoneDisplayOrientation(degrees: 90) == .landscapeLeft)
        #expect(VPhoneDisplayOrientation(degrees: 180) == .upsideDown)
        #expect(VPhoneDisplayOrientation(degrees: 270) == .landscapeRight)
        #expect(VPhoneDisplayOrientation(degrees: -90) == .landscapeRight)
        #expect(VPhoneDisplayOrientation(degrees: 450) == .landscapeLeft)
        #expect(VPhoneDisplayOrientation(degrees: 45) == nil)
    }

    /// The Mac repeats the device's clockwise turn; NSView rotation counts
    /// counterclockwise.
    @Test func `the view turns the way the device turned`() {
        #expect(VPhoneDisplayOrientation.portrait.viewRotation == 0)
        #expect(VPhoneDisplayOrientation.landscapeLeft.viewRotation == 270)
        #expect(VPhoneDisplayOrientation.upsideDown.viewRotation == 180)
        #expect(VPhoneDisplayOrientation.landscapeRight.viewRotation == 90)
    }

    @Test func `rotate right turns clockwise and rotate left undoes it`() {
        #expect(VPhoneDisplayOrientation.portrait.turned(clockwise: true) == .landscapeLeft)
        #expect(VPhoneDisplayOrientation.landscapeLeft.turned(clockwise: true) == .upsideDown)
        #expect(VPhoneDisplayOrientation.landscapeRight.turned(clockwise: true) == .portrait)
        #expect(VPhoneDisplayOrientation.portrait.turned(clockwise: false) == .landscapeRight)
        for orientation in VPhoneDisplayOrientation.allCases {
            #expect(orientation.turned(clockwise: true).turned(clockwise: false) == orientation)
        }
    }

    @Test func `only landscape swaps the panel's sides`() {
        #expect(VPhoneDisplayOrientation.portrait.displayedSize(panel: Self.panel) == Self.panel)
        #expect(VPhoneDisplayOrientation.upsideDown.displayedSize(panel: Self.panel) == Self.panel)
        let sideways = CGSize(width: 852, height: 393)
        #expect(VPhoneDisplayOrientation.landscapeLeft.displayedSize(panel: Self.panel) == sideways)
        #expect(VPhoneDisplayOrientation.landscapeRight.displayedSize(panel: Self.panel) == sideways)
    }

    // MARK: - Window

    @Test func `turning keeps the long side and the center`() {
        let portrait = CGRect(x: 400, y: 50, width: 393, height: 852)
        let rect = VPhoneDisplayOrientation.landscapeLeft.contentRect(
            from: portrait, panel: Self.panel, within: Self.screen,
        )
        #expect(rect.size == CGSize(width: 852, height: 393))
        #expect(abs(rect.midX - portrait.midX) <= 0.5 && abs(rect.midY - portrait.midY) <= 0.5)
    }

    @Test func `turning back restores portrait`() {
        let landscape = CGRect(x: 170, y: 280, width: 852, height: 393)
        let rect = VPhoneDisplayOrientation.portrait.contentRect(
            from: landscape, panel: Self.panel, within: Self.screen,
        )
        #expect(rect.size == CGSize(width: 393, height: 852))
    }

    @Test func `a turned window too large for the screen shrinks to fit`() {
        let tall = CGRect(x: 0, y: 0, width: 800, height: 1734)
        let small = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let rect = VPhoneDisplayOrientation.landscapeRight.contentRect(from: tall, panel: Self.panel, within: small)
        #expect(rect.width <= 1200 && rect.height <= 800)
        #expect(abs(rect.width / rect.height - 852.0 / 393.0) < 0.01)
        #expect(small.contains(rect))
    }

    @Test func `a turned window stays on the screen`() {
        let nearEdge = CGRect(x: 0, y: 0, width: 393, height: 852)
        let rect = VPhoneDisplayOrientation.landscapeLeft.contentRect(
            from: nearEdge, panel: Self.panel, within: Self.screen,
        )
        #expect(Self.screen.contains(rect))
    }

    @Test func `a portrait window left portrait is unchanged`() {
        let portrait = CGRect(x: 400, y: 50, width: 393, height: 852)
        let rect = VPhoneDisplayOrientation.portrait.contentRect(from: portrait, panel: Self.panel, within: Self.screen)
        #expect(rect == portrait)
    }
}
