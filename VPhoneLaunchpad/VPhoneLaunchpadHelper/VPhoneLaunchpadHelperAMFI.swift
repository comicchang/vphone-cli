import Darwin
import Foundation

/// The only AMFI operation exposed by the root helper. The client supplies a
/// version, never a path or command line. Both executables come from the
/// root-owned, receipt-verified bundle store.
enum VPhoneLaunchpadHelperAMFI {
    /// How long the escalator may run before the helper kills it. It normally
    /// finishes in well under a second; this only bounds a hung run.
    private static let escalatorTimeout: TimeInterval = 30

    private static let lock = NSLock()

    static func allow(bundleVersion: String) throws {
        lock.lock()
        defer { lock.unlock() }

        try VPhoneLaunchpadHostPolicy.requireReady()

        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(bundleVersion),
              let receipt = VPhoneLaunchpadBundleReceipt.load(version: bundleVersion)
        else {
            throw VPhoneLaunchpadHelperError("VPhone.bundle \(bundleVersion) is not installed. Reinstall it, then try again.")
        }

        let bundle = VPhoneLaunchpadBundleStore.bundle(version: bundleVersion)
        let vm = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-vm")
        let escalator = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-escalator")
        try VPhoneLaunchpadHelperCodeCheck.requireValidBundle(bundle)
        try VPhoneLaunchpadHelperCodeCheck.requireCDHash(vm, receipt.cdhashes["vphone-vm"])

        var info = stat()
        guard lstat(escalator.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0,
              info.st_mode & 0o022 == 0
        else {
            throw VPhoneLaunchpadHelperError("A required tool in VPhone.bundle is missing or was changed. Reinstall VPhone.bundle.")
        }

        let process = Process()
        process.executableURL = escalator
        process.arguments = ["allow", vm.path]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw VPhoneLaunchpadHelperError("Unable to allow the bundle to run. Try again.")
        }
        // A hung escalator holds the pipe write end, so a plain
        // readDataToEndOfFile would block forever. Poll for exit first; EOF
        // follows exit, so draining afterwards never blocks.
        let deadline = Date().addingTimeInterval(escalatorTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !process.isRunning else {
            process.terminate()
            // The escalator may ignore SIGTERM on its way down; make sure.
            Thread.sleep(forTimeInterval: 1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw VPhoneLaunchpadHelperError(
                "The AMFI escalator did not finish within \(Int(escalatorTimeout)) seconds and was stopped. Try again.",
            )
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw VPhoneLaunchpadHelperError(text.isEmpty ? "Unable to allow the bundle to run. Check the System Integrity Protection settings on this Mac." : text)
        }
    }
}
