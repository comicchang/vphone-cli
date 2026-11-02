import Foundation
import Security

// MARK: - VPhoneGuestLaunchError

public enum VPhoneGuestLaunchError: Error, CustomStringConvertible {
    case missingCompanion(name: String, expectedAt: URL)
    /// amfid refused `vphone-vm`. Carries what the advice needs to be concrete:
    /// the binary that was refused and, when it could be read, its cdhash —
    /// plus what the one automatic relief did, when it ran and did not help.
    case blockedByAMFI(guest: URL, cdHash: String?, relief: VPhoneGuestLaunchPlanner.ReliefAttempt?)
    case missingEntitlements(guest: URL)
    case probeFailed(exitCode: Int32, output: String)

    public var description: String {
        switch self {
        case let .missingCompanion(name, url):
            return """
            \(name) not found at \(url.path). The app bundle is incomplete. Rebuild the VPhone scheme in Xcode.
            """

        case let .blockedByAMFI(guest, cdHash, relief):
            let helper = guest.deletingLastPathComponent()
                .appendingPathComponent("vphone-escalator")
            let reliefParagraph = relief.map { attempt in
                """

                The automatic \(attempt.launchpadCLI.path) bundle verify '\(attempt.version)' \
                was tried once and the guest was refused again:
                \(attempt.report)
                """
            } ?? ""
            return """
            AMFI blocked vphone-vm, so the VM could not start.
            \(reliefParagraph)

            Binary: \(guest.path)
            CDHash: \(cdHash ?? "unavailable")

            Allow this build's signed VM binary with the bundled helper:
              sudo '\(helper.path)' allow '\(guest.path)'

            The allowlist is specific to this signature, so repeat after a
            rebuild. See https://github.com/Lakr233/vphone-cli/blob/main/Documents/en/get-started/host-setup.md
            for host settings.
            """

        case let .missingEntitlements(guest):
            return """
            vphone-vm at \(guest.path) is missing required virtualization entitlements.
            Rebuild the VPhone scheme in Xcode to sign this binary, then allow the new signature
            through the host's AMFI policy before launching a VM.
            """

        case let .probeFailed(code, output):
            return """
            vphone-vm could not start (exit code \(code)). AMFI did not block it.
            \(output.isEmpty ? "It produced no output." : output)
            """
        }
    }
}

// MARK: - VPhoneGuestLaunchPlanner

/// Decides, once, whether a guest can be started at all, then hands out the
/// concrete command for each boot.
///
/// The two binaries are split precisely so this indirection can exist:
/// `vphone-vm` carries the private virtualization entitlements and therefore
/// cannot launch unless amfid is willing, while `vphone-cli` carries none and
/// always launches. That makes `vphone-cli` the one process that is still
/// running when the refusal happens, and so the only one that can explain it.
///
/// Explaining is still what it does when nothing else works, but it no longer
/// stops at the first refusal: once per process, when amfid refuses and
/// `vphone-launchpad-cli` is available, it asks a running Launchpad to
/// `bundle verify` this very bundle, which re-applies the allowlist through
/// the app's root helper, and probes once more before giving up. Getting past
/// amfid without Launchpad remains the user's own business, and
/// `VPhoneGuestLaunchError.blockedByAMFI` is what tells them how.
///
/// It is a value rather than a set of static calls because `vm create` boots
/// the guest more than once, and probing amfid once per boot would be wasteful.
public struct VPhoneGuestLaunchPlanner: Sendable {
    /// The guest binary. Host preflight checks this, because this is the
    /// binary that actually has to satisfy amfid.
    public let guestExecutable: URL

    public init() throws {
        let vm = VPhoneResources.siblingExecutable("vphone-vm")
        guard FileManager.default.isExecutableFile(atPath: vm.path) else {
            throw VPhoneGuestLaunchError.missingCompanion(name: "vphone-vm", expectedAt: vm)
        }
        guestExecutable = vm

        // `swift test -c release` can replace a signed release binary with
        // its linker-signed, unentitled build. That binary answers --help, but
        // PV=3 isSupported is false when the VM is created.
        guard try Self.hasRequiredEntitlements(vm) else {
            throw VPhoneGuestLaunchError.missingEntitlements(guest: vm)
        }

        // Probe before doing anything else. Launching straight into a SIGKILL
        // would leave the caller with a bare exit 9 and no explanation — which
        // is the confusing failure this whole path exists to remove.
        if try Self.amfidRefuses(vm) {
            if let refusal = try Self.gate(
                guest: vm,
                environment: .live(),
            ) {
                throw refusal
            }
            // The relief convinced amfid; the boot below proceeds.
        }
    }

    /// The command to spawn for one boot.
    public func plan(_ arguments: [String]) -> (executable: URL, arguments: [String]) {
        (guestExecutable, arguments)
    }

    /// Run a guest to completion and return its exit status.
    ///
    /// stdio is inherited so the guest's serial output streams straight to the
    /// terminal, and the child is placed in the terminal's foreground group so
    /// that Ctrl-C behaves normally.
    @discardableResult
    public func run(_ arguments: [String], cwd: URL? = nil) throws -> Int32 {
        let (exe, args) = plan(arguments)
        return try VPhoneProcessRunner.runForeground(exe, args, cwd: cwd)
    }

    // MARK: - Probe

    private static func hasRequiredEntitlements(_ vm: URL) throws -> Bool {
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["-d", "--entitlements", "-", "--xml", vm.path],
        )
        guard result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(result.stdout.utf8),
                  format: nil,
              ) as? [String: Any]
        else { return false }
        return plist["com.apple.private.virtualization"] as? Bool == true &&
            plist["com.apple.private.virtualization.security-research"] as? Bool == true
    }

    /// Ask amfid the question cheaply, by running `vphone-vm --help`.
    ///
    /// amfid decides at exec, before any of the target's own code runs, so a
    /// `--help` that never prints is the same refusal the real launch would
    /// hit — and it costs nothing and touches no VM state. A refused process is
    /// killed with SIGKILL, which Foundation reports as termination status 9.
    ///
    /// Anything else non-zero is somebody else's problem, and is raised as
    /// itself rather than being mistaken for an AMFI refusal.
    private static func amfidRefuses(_ vm: URL) throws -> Bool {
        let probe = try VPhoneProcessRunner.runCapturing(vm, ["--help"])
        return try Probe.classify(probe: probe, vm: vm) == .refused
    }

    // MARK: - Probe classification

    /// What one `--help` run says about amfid's willingness, decided as a pure
    /// function so tests can pin the reading without spawning anything.
    enum Probe: Equatable, Sendable {
        /// The guest answered; amfid is content.
        case accepted
        /// The guest was killed at exec; this is the SIGKILL refusal the real
        /// launch would hit.
        case refused
        /// Some other failure; it is raised verbatim as `probeFailed`.
        case other

        static func classify(probe: VPhoneProcessResult, vm: URL) throws -> Self {
            if probe.succeeded {
                return .accepted
            }
            if probe.exitCode == SIGKILL {
                return .refused
            }
            throw VPhoneGuestLaunchError.probeFailed(
                exitCode: probe.exitCode,
                output: (probe.stderr + probe.stdout).trimmingCharacters(in: .whitespacesAndNewlines),
            )
        }
    }

    // MARK: - Automatic relief

    /// What the one automatic relief did, when it ran and did not help. It is
    /// carried on `blockedByAMFI` so the printed advice still shows the sudo
    /// command while also saying what was tried in the user's stead.
    public struct ReliefAttempt: Equatable, Sendable {
        /// The CLI the relief ran through.
        public let launchpadCLI: URL
        /// The store version the relief asked Launchpad to verify.
        public let version: String
        /// What happened, in the wording of the failure the relief ended with.
        public let report: String

        init(launchpadCLI: URL, version: String, report: String) {
            self.launchpadCLI = launchpadCLI
            self.version = version
            self.report = report
        }
    }

    /// The side of the world the relief can touch, all behind closures so the
    /// once-per-process gate is testable without spawning anything.
    struct ReliefEnvironment: Sendable {
        /// Where the `vphone-launchpad-cli` executable is, when it is.
        var locateLaunchpadCLI: @Sendable () -> URL?
        /// The version of the bundle this process runs in, from its receipt.
        var bundleStoreVersion: @Sendable () -> String?
        /// Run the CLI once, with a wall-clock cap.
        var runCLI: @Sendable (_ cli: URL, _ arguments: [String], _ timeout: TimeInterval) throws -> VPhoneProcessResult
        /// Ask amfid again.
        var probe: @Sendable (_ vm: URL) throws -> Probe

        static func live() -> Self {
            Self(
                locateLaunchpadCLI: Self.locateLaunchpadCLI,
                bundleStoreVersion: Self.bundleStoreVersion,
                runCLI: Self.runCLI,
                probe: { vm in
                    try Probe.classify(probe: VPhoneProcessRunner.runCapturing(vm, ["--help"]), vm: vm)
                },
            )
        }

        /// PATH first, then the location `install.md` tells users to symlink
        /// when `~/.local/bin` is not on their PATH.
        static func locateLaunchpadCLI() -> URL? {
            let name = "vphone-launchpad-cli"
            let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0), isDirectory: true) }
            for directory in directories where FileManager.default.isExecutableFile(
                atPath: directory.appendingPathComponent(name).path,
            ) {
                return directory.appendingPathComponent(name)
            }
            let local = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/\(name)")
            return FileManager.default.isExecutableFile(atPath: local.path) ? local : nil
        }

        /// The version the running bundle is installed under, as its receipt
        /// records. Local builds are named `<version>-local.<build>` — the
        /// short version alone does not name a store directory — so the check
        /// is the receipt's cdhash of this very `vphone-vm` against its own
        /// bytes: a receipt names this build only when the hashes match.
        static func bundleStoreVersion() -> String? {
            let vm = VPhoneResources.runningExecutable()
                .deletingLastPathComponent() // …/Contents/MacOS
                .deletingLastPathComponent() // …/Contents
                .deletingLastPathComponent() // …/VPhone.bundle
            guard vm.lastPathComponent == "VPhone.bundle" else { return nil }
            guard let cdHash = codeDirectoryHash(of: vm.appendingPathComponent("Contents/MacOS/vphone-vm")) else {
                return nil
            }
            let root = vm.deletingLastPathComponent()
            for candidate in (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? [] {
                // The receipt the helper writes next to each installed bundle:
                // version, sha256, cdhashes by executable name (ISO-8601
                // dates). Parsed here in the narrow shape it has; there is no
                // shared type, the store belongs to Launchpad.
                struct Receipt: Decodable {
                    let cdhashes: [String: String]
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let data = try? Data(contentsOf: root
                        .appendingPathComponent(candidate, isDirectory: true)
                        .appendingPathComponent("receipt.json")),
                    let receipt = try? decoder.decode(Receipt.self, from: data),
                    receipt.cdhashes["vphone-vm"] == cdHash
                else { continue }
                return candidate
            }
            return nil
        }

        /// One CLI run, capped at `timeout` seconds. The relief must not hang
        /// a boot on a wedged app, so the wait ends when the deadline does and
        /// the child is killed; a timed-out run reports like any other CLI
        /// failure rather than raising.
        static func runCLI(
            _ cli: URL,
            _ arguments: [String],
            timeout: TimeInterval,
        ) throws -> VPhoneProcessResult {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let outBox = DataBox()
            let errBox = DataBox()
            let group = DispatchGroup()
            group.enter()
            group.enter()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    outBox.append(chunk)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    errBox.append(chunk)
                }
            }

            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // A run that reached its deadline must not report a termination
            // status it has not reached yet: stop it here, and settle the
            // status before the result is read below.
            if process.isRunning {
                process.terminate()
                _ = group.wait(timeout: .now() + 2)
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            } else {
                group.wait()
            }

            func text(_ box: DataBox) -> String {
                String(decoding: box.take(), as: UTF8.self)
            }
            return VPhoneProcessResult(
                exitCode: process.terminationStatus,
                stdout: text(outBox),
                stderr: text(errBox),
            )
        }
    }

    /// The one decision every refusal goes through, in order: probe, and if
    /// amfid refused and no relief has run in this process yet and Launchpad's
    /// CLI is reachable and this bundle is installed in Launchpad's store, ask
    /// Launchpad to verify the bundle and probe again.
    ///
    /// Returns nil when amfid now accepts the guest — a relief that worked, so
    /// the caller's boot simply proceeds — and the refusal to raise when it
    /// did not, with what the relief did attached when it ran. A probe that
    /// failed on its own terms is raised, not returned.
    ///
    /// Once per process, ever: the relief asks for an administrator credential
    /// through the helper on the first privileged operation of the login
    /// session, and retrying it on every boot would nag or, worse, loop.
    static func gate(
        guest vm: URL,
        environment: ReliefEnvironment,
    ) throws -> VPhoneGuestLaunchError? {
        Self.reliefOnce.lock()
        defer { Self.reliefOnce.unlock() }
        let probe = try environment.probe(vm)
        guard probe == .refused else {
            throw try refusalOrUnexpected(probe: probe, vm: vm)
        }
        guard !Self.reliefWasAttempted else {
            return refusal(vm: vm, relief: nil)
        }
        Self.reliefWasAttempted = true
        guard let cli = environment.locateLaunchpadCLI() else {
            return refusal(vm: vm, relief: nil)
        }
        guard let version = environment.bundleStoreVersion() else {
            return refusal(vm: vm, relief: nil)
        }
        var runResult: VPhoneProcessResult?
        var runFailure: Error?
        do {
            runResult = try environment.runCLI(cli, ["bundle", "verify", version], 60)
        } catch {
            runFailure = error
        }
        // Ask amfid once more whatever the CLI did: a timed-out CLI may still
        // have finished the re-verify, and a launch failure cannot have, but
        // one second probe keeps the outcome decided by amfid either way.
        guard try environment.probe(vm) == .accepted else {
            let report: String
            if let runFailure {
                report = runFailure.localizedDescription
            } else if let runResult, runResult.succeeded {
                report = "the CLI reported success but the guest was refused again."
            } else {
                report = "the CLI exited \(runResult?.exitCode ?? -1)."
            }
            return refusal(vm: vm, relief: ReliefAttempt(
                launchpadCLI: cli,
                version: version,
                report: report,
            ))
        }
        // The relief worked; this boot proceeds. That a later boot finds amfid
        // unwilling again is what the once-per-process flag deliberately keeps
        // a second relief from retrying.
        return nil
    }

    /// The error a non-refusal probe raises. A guest that failed on its own is
    /// `probeFailed`; an `.accepted` reaching this point means the caller saw
    /// a refusal the probe no longer reproduces, which no live path does, so
    /// it is reported as the refusal shape the switch must still handle.
    private static func refusalOrUnexpected(probe: Probe, vm: URL) throws -> VPhoneGuestLaunchError {
        if probe == .refused {
            return refusal(vm: vm, relief: nil)
        }
        throw VPhoneGuestLaunchError.probeFailed(
            exitCode: 0,
            output: "the guest reported \(probe), which is not a launchable state here.",
        )
    }

    private static func refusal(vm: URL, relief: ReliefAttempt?) -> VPhoneGuestLaunchError {
        .blockedByAMFI(
            guest: vm,
            cdHash: codeDirectoryHash(of: vm),
            relief: relief,
        )
    }

    /// `runCapturing`'s accumulator, shared so the capped CLI run reads its
    /// pipes the same way.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func take() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private static let reliefOnce = NSLock()
    private nonisolated(unsafe) static var reliefWasAttempted = false

    /// Test seam: clears the once-per-process flag so a suite can exercise
    /// the gate from scratch. Nothing in production calls this.
    static func resetReliefForTesting() {
        reliefOnce.lock()
        defer { reliefOnce.unlock() }
        reliefWasAttempted = false
    }

    /// A binary's code-directory hash, in the hex form amfidont's `--cdhash`
    /// wants and `codesign -dv --verbose=4` prints.
    ///
    /// Read in-process through the Security framework rather than by spawning
    /// `codesign`: `kSecCodeInfoUnique` *is* the cdhash, straight from the
    /// code-signing machinery instead of scraped out of another tool's output.
    /// That means no subprocess on a path that is already failing, and no
    /// chance of picking up some other `codesign` from `PATH`. The two agree
    /// byte for byte — checked against `codesign -dv --verbose=4`.
    ///
    /// `nil` means the binary could not be read or is unsigned; the caller
    /// then tells the user how to obtain the hash instead of inventing one.
    static func codeDirectoryHash(of binary: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess,
              let code
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let entries = information as? [String: Any],
              let hash = entries[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
