import Foundation
import IcliKit
import IcliSystem

// MARK: - Device, Display, Audio, Network

extension GuestAPI {
    static func executeDevice(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "device.info":
            var info = try collectDeviceSnapshot()
            info["jailbreak"] = jailbreakInfo()
            info["network"] = networkInfo()
            info["screen"] = screenInfo()
            info["rotation"] = rotationInfo()
            info["brightness"] = brightnessState()
            info["volume"] = volume()
            info["low_power_mode"] = (try? lowPowerMode()) ?? [:]
            info["developer_mode"] = (try? developerModeStatus()) ?? [:]
            info["agent"] = ["binary_hash": binaryHash, "pid": getpid()]
            return info
        case "device.network":
            return networkInfo()
        case "device.ioreg":
            return try ioregistry(plane: optionalString(params, "plane") ?? "IOService")
        case "device.environment":
            return try environmentReport()
        case "device.basebin":
            return try compareBaseBin(bundled: optionalString(params, "archive"))
        case "display.brightness":
            if params["value"] != nil {
                try setBrightness(requiredNumber(params, "value"))
            }
            return brightnessState()
        case "display.rotation":
            if let orientation = optionalString(params, "orientation") {
                return try setRotation(orientation)
            }
            return rotationInfo()
        case "display.orientation":
            return interfaceOrientation()
        case "display.rotation_lock":
            guard let locked = params["locked"] as? Bool else {
                throw GuestAPIError.invalidRequest("locked must be true or false")
            }
            return try setRotationLock(locked)
        case "audio.volume":
            let category = optionalString(params, "category") ?? "Audio/Video"
            if params["value"] != nil {
                return try setVolume(requiredNumber(params, "value"), category: category)
            }
            return ["volume": volume(category), "category": category]
        case "audio.state":
            return try audioState()
        case "network.capture":
            let seconds = number(params, "seconds", default: 5)
            return try capturePackets(
                seconds: seconds,
                interface: optionalString(params, "interface") ?? "en0",
                filter: optionalString(params, "filter"),
            )
        case "security.ssl_killswitch":
            return sslKillswitchStatus()
        case "diagnostics.self_test":
            return try runSelfTests()
        case "notify.post":
            let state = try params["state"].map(notificationState)
            return try postDarwinNotification(string(params, "name"), state: state)
        case "notify.state":
            return try darwinNotificationState(string(params, "name"))
        default:
            return nil
        }
    }

    /// The interface orientation in `display.rotation`'s degrees, cheap
    /// enough for the host to ask every second. SpringBoard is asked
    /// directly; `rotationInfo()` captures the screen, and is only the
    /// fallback when SpringBoard does not answer.
    private static func interfaceOrientation() -> [String: Any] {
        if let degrees = springBoardInterfaceDegrees() {
            return ["degrees": degrees, "source": "springboard"]
        }
        let degrees = (rotationInfo()["degrees"] as? NSNumber)?.intValue ?? 0
        return ["degrees": degrees, "source": "screen"]
    }

    /// AXSpringBoardServer's activeInterfaceOrientation, a
    /// UIInterfaceOrientation, in degrees clockwise from portrait.
    private static func springBoardInterfaceDegrees() -> Int? {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
            RTLD_NOW,
        )
        let serverSelector = NSSelectorFromString("server")
        let orientationSelector = NSSelectorFromString("activeInterfaceOrientation")
        guard let serverClass = NSClassFromString("AXSpringBoardServer") as? NSObject.Type,
              serverClass.responds(to: serverSelector),
              let server = serverClass.perform(serverSelector)?.takeUnretainedValue() as? NSObject,
              server.responds(to: orientationSelector)
        else { return nil }
        typealias Getter = @convention(c) (NSObject, Selector) -> Int
        let getter = unsafeBitCast(server.method(for: orientationSelector), to: Getter.self)
        switch getter(server, orientationSelector) {
        case 1: return 0
        case 2: return 180
        case 3: return 270
        case 4: return 90
        default: return nil
        }
    }

    private static func brightnessState() -> [String: Any] {
        ["value": brightness(), "auto": autoBrightness().map { $0 as Any } ?? NSNull()]
    }

    /// A notify(3) state is a full UInt64, beyond what a JSON double holds
    /// exactly, so a decimal string is accepted as well as a number. A JSON
    /// boolean also decodes as NSNumber and is refused.
    private static func notificationState(_ value: Any) throws -> UInt64 {
        let number = (value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0 }
        let text = (value as? String) ?? number?.stringValue
        guard let text, let state = UInt64(text) else {
            throw GuestAPIError.invalidRequest("state must be an unsigned 64-bit integer")
        }
        return state
    }
}
