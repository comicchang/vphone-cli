import Foundation
import Testing
@testable import VPhoneCoreKit

/// The AMFI refusal gate in `VPhoneGuestLaunchPlanner`: what one automatic
/// Launchpad relief is allowed to do, and what the advice says when it cannot
/// help. Every side effect stands behind `ReliefEnvironment`'s closures, so
/// these tests spawn nothing and touch no amfid, socket or store. The
/// once-per-process flag is shared, so the suite runs serialized and each
/// test starts with it cleared.
@Suite("Guest launch relief", .serialized)
struct GuestLaunchReliefTests {
    init() {
        VPhoneGuestLaunchPlanner.resetReliefForTesting()
    }

    /// A guest binary that only has to exist for URLs; the closures decide
    /// what every probe "runs", and no code reads these paths.
    private static let guest = URL(fileURLWithPath: "/tmp/guest/VPhone.bundle/Contents/MacOS/vphone-vm")
    private static let cli = URL(fileURLWithPath: "/tmp/bin/vphone-launchpad-cli")
    private static let version = "2.15.0-local.0123abcd"

    /// Probes return `refusal` until `acceptsAfter` runs have happened, then
    /// `accepted`. `probes` counts every run the gate made.
    private final class ProbeScript: @unchecked Sendable {
        private let lock = NSLock()
        private let sequence: [VPhoneGuestLaunchPlanner.Probe]
        private(set) var index = 0

        init(_ sequence: [VPhoneGuestLaunchPlanner.Probe]) {
            self.sequence = sequence
        }

        var next: VPhoneGuestLaunchPlanner.Probe {
            lock.lock()
            defer { lock.unlock() }
            guard index < sequence.count else { return sequence.last ?? .accepted }
            let probe = sequence[index]
            index += 1
            return probe
        }

        var runs: Int {
            lock.lock()
            defer { lock.unlock() }
            return index
        }
    }

    /// An environment whose probes follow `script`; every other side records
    /// what the gate asked of it. The CLI run ends with `cliExit` (and its
    /// output on stderr), or throws when `cliExit` is nil.
    private final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []
        func append(_ arguments: [String]) {
            lock.lock()
            commands.append(arguments)
            lock.unlock()
        }

        func snapshot() -> [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }
    }

    private static func environment(
        script: ProbeScript,
        cliFound: Bool = true,
        versionFound: String? = Self.version,
        cliExit: Int32? = 0,
    ) -> (VPhoneGuestLaunchPlanner.ReliefEnvironment, ProbeScript, CommandLog) {
        let log = CommandLog()
        let cliURL = cliFound ? cli : nil
        let storeVersion = versionFound
        let exit = cliExit
        let environment = VPhoneGuestLaunchPlanner.ReliefEnvironment(
            locateLaunchpadCLI: { cliURL },
            bundleStoreVersion: { storeVersion },
            runCLI: { _, arguments, timeout in
                #expect(timeout == 60)
                log.append(arguments)
                guard let exit else {
                    struct LaunchFailure: LocalizedError {
                        let errorDescription: String? = "the CLI could not be launched."
                    }
                    throw LaunchFailure()
                }
                return VPhoneProcessResult(
                    exitCode: exit,
                    stdout: "",
                    stderr: exit == 0 ? "" : "error: VPhone.bundle \(Self.version) did not pass its checks.",
                )
            },
            probe: { _ in script.next },
        )
        return (environment, script, log)
    }

    /// The gate's refusal outcome: nil means the relief worked and the boot
    /// proceeds; an error is the refusal to raise. Extracted so each test
    /// reads only the fields it pins.
    private static func outcome(
        _ result: VPhoneGuestLaunchError?,
    ) -> (guest: URL, relief: VPhoneGuestLaunchPlanner.ReliefAttempt?)? {
        guard let error = result,
              case let .blockedByAMFI(guest, _, relief) = error
        else { return nil }
        return (guest, relief)
    }

    @Test func `refusal runs the relief once and then the advice reports what it did`() throws {
        let probeScript = ProbeScript([.refused, .refused])
        let (environment, script, log) = Self.environment(script: probeScript, cliExit: 1)
        let result = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)

        let refusal = try #require(Self.outcome(result))
        #expect(refusal.guest == Self.guest)
        let relief = try #require(refusal.relief)
        #expect(relief.launchpadCLI == Self.cli)
        #expect(relief.version == Self.version)
        #expect(relief.report == "the CLI exited 1.")
        #expect(log.snapshot() == [["bundle", "verify", Self.version]])
        #expect(script.runs == 2)
    }

    @Test func `a relief that convinces amfid lets the boot proceed`() throws {
        // The gate asks amfid again after the CLI; amfid now answers. That is
        // the one outcome where the gate says go on: nil, no error raised.
        let probeScript = ProbeScript([.refused, .accepted])
        let (environment, script, log) = Self.environment(script: probeScript)
        let result = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)

        #expect(result == nil)
        #expect(log.snapshot().count == 1)
        #expect(script.runs == 2)
    }

    @Test func `a relief the CLI cannot run falls back to the sudo advice`() throws {
        let probeScript = ProbeScript([.refused, .refused])
        let (environment, script, log) = Self.environment(script: probeScript, cliExit: nil)
        let result = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)

        let refusal = try #require(Self.outcome(result))
        let relief = try #require(refusal.relief)
        #expect(relief.report == "the CLI could not be launched.")
        #expect(log.snapshot().count == 1)
        #expect(script.runs == 2)
    }

    @Test func `no launchpad CLI means no relief and no probe after the first`() throws {
        let probeScript = ProbeScript([.refused])
        let (environment, script, log) = Self.environment(script: probeScript, cliFound: false)
        let result = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)

        let refusal = try #require(Self.outcome(result))
        #expect(refusal.relief == nil)
        #expect(log.snapshot().isEmpty)
        #expect(script.runs == 1)
    }

    @Test func `no store receipt for this build means no relief`() throws {
        let probeScript = ProbeScript([.refused])
        let (environment, script, log) = Self.environment(script: probeScript, versionFound: nil)
        let result = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)

        let refusal = try #require(Self.outcome(result))
        #expect(refusal.relief == nil)
        #expect(log.snapshot().isEmpty)
        #expect(script.runs == 1)
    }

    @Test func `a guest amfid accepts is never relieved`() throws {
        let probeScript = ProbeScript([.accepted])
        let (environment, script, log) = Self.environment(script: probeScript)
        #expect(throws: VPhoneGuestLaunchError.self) {
            _ = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)
        }
        #expect(log.snapshot().isEmpty)
        #expect(script.runs == 1)
    }

    @Test func `a second refusal in the same process is not relieved again`() throws {
        // First gate: relief runs and fails to help. Second gate: straight to
        // the advice, no CLI run, no probe after the refusal.
        let probeScript = ProbeScript([.refused, .refused, .refused])
        let (environment, script, log) = Self.environment(script: probeScript, cliExit: 1)

        let first = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)
        #expect(Self.outcome(first)?.relief != nil)
        #expect(log.snapshot().count == 1)

        let second = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)
        let refusal = try #require(Self.outcome(second))
        #expect(refusal.relief == nil)
        #expect(log.snapshot().count == 1, "the relief runs once per process, not once per gate")
        #expect(script.runs == 3)
    }

    @Test func `a probe that fails on its own is raised as probeFailed`() throws {
        let probeScript = ProbeScript([.other])
        let (environment, script, log) = Self.environment(script: probeScript)
        do {
            _ = try VPhoneGuestLaunchPlanner.gate(guest: Self.guest, environment: environment)
            Issue.record("the gate should have raised the probe's own failure")
        } catch let error as VPhoneGuestLaunchError {
            guard case .probeFailed = error else {
                Issue.record("expected probeFailed, got \(error)")
                return
            }
        }
        #expect(log.snapshot().isEmpty)
        #expect(script.runs == 1)
    }

    @Test func `probe classification reads the exit codes amfid produces`() throws {
        #expect(try VPhoneGuestLaunchPlanner.Probe.classify(
            probe: VPhoneProcessResult(exitCode: 0, stdout: "usage: vphone-vm", stderr: ""),
            vm: Self.guest,
        ) == .accepted)
        #expect(try VPhoneGuestLaunchPlanner.Probe.classify(
            probe: VPhoneProcessResult(exitCode: SIGKILL, stdout: "", stderr: ""),
            vm: Self.guest,
        ) == .refused)
        #expect(throws: VPhoneGuestLaunchError.self) {
            _ = try VPhoneGuestLaunchPlanner.Probe.classify(
                probe: VPhoneProcessResult(exitCode: 1, stdout: "", stderr: "no such machine"),
                vm: Self.guest,
            )
        }
    }

    @Test func `the printed advice keeps the sudo command and names the relief`() {
        let error = VPhoneGuestLaunchError.blockedByAMFI(
            guest: Self.guest,
            cdHash: "aabbccdd",
            relief: VPhoneGuestLaunchPlanner.ReliefAttempt(
                launchpadCLI: Self.cli,
                version: Self.version,
                report: "the CLI exited 1.",
            ),
        )
        let text = error.description
        #expect(text.contains("sudo '/tmp/guest/VPhone.bundle/Contents/MacOS/vphone-escalator' allow"))
        #expect(text.contains("bundle verify '\(Self.version)'"))
        #expect(text.contains("the CLI exited 1."))
        #expect(text.contains("CDHash: aabbccdd"))

        let withoutRelief = VPhoneGuestLaunchError.blockedByAMFI(
            guest: Self.guest,
            cdHash: nil,
            relief: nil,
        ).description
        #expect(withoutRelief.contains("CDHash: unavailable"))
        #expect(!withoutRelief.contains("bundle verify"))
    }
}
