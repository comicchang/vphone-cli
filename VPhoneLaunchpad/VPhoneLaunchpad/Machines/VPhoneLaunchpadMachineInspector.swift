import AppKit
import SwiftUI

// MARK: - State label

/// A machine's run state as the table and the inspector show it.
struct VPhoneLaunchpadMachineStateLabel: View {
    let state: VPhoneLaunchpadMachineLibrary.RunState
    /// An export's progress, shown as a bar in place of the activity text.
    var progress: Double?

    var body: some View {
        let (status, text): (VPhoneLaunchpadStatus, String) = switch state {
        case .running: (.passed, String(localized: "Running"))
        case .stopped: (.pending, String(localized: "Stopped"))
        case let .busy(activity): (.running, activity)
        }
        if let progress {
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .controlSize(.small)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .help(text)
        } else {
            Label {
                Text(text).lineLimit(1)
            } icon: {
                VPhoneLaunchpadStatusIcon(status: status)
            }
        }
    }
}

// MARK: - Inspector

/// The trailing inspector for the selected machine. Values are split into
/// short rows, since the column is narrow, and long ones truncate in the
/// middle.
struct VPhoneLaunchpadMachineInspector: View {
    let machine: VPhoneLaunchpadMachine
    let onShowProgress: (VPhoneLaunchpadMachinePath) -> Void
    let onOpenConsole: (VPhoneLaunchpadMachinePath) -> Void
    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var showsCommands = false

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        Form {
            VPhoneLaunchpadInstallSection()

            Section {
                if let creation = library.creations[machine.path] {
                    creationSummary(creation)
                }
                LabeledContent("State") {
                    VPhoneLaunchpadMachineStateLabel(
                        state: library.state(of: machine.path),
                        progress: library.exports[machine.path]?.fraction,
                    )
                }
                if let started = library.startedAt[machine.path] {
                    LabeledContent("Started", value: started.formatted(date: .omitted, time: .shortened))
                }
                if let variant = machine.restoreInfo?.variant {
                    LabeledContent("Variant", value: variant)
                }
            } header: {
                Text(machine.name)
                    .font(.headline)
            }

            Section("Firmware") {
                if let info = machine.restoreInfo {
                    LabeledContent("iOS", value: "\(info.ios.version) (\(info.ios.build))")
                    LabeledContent("cloudOS", value: "\(info.cloudOS.version) (\(info.cloudOS.build))")
                } else {
                    Text("Not restored").foregroundStyle(.secondary)
                }
            }

            Section("Hardware") {
                LabeledContent("CPU", value: String(localized: "\(machine.cpuCount) cores"))
                LabeledContent("Memory", value: VPhoneLaunchpadMachinesView.memory(machine.memoryMB))
                LabeledContent("Disk", value: VPhoneLaunchpadMachinesView.disk(machine.diskSizeBytes))
                LabeledContent("Network", value: machine.networkDescription)
            }

            Section("Identity") {
                if let udid = machine.udid {
                    value("UDID", udid)
                }
                value(
                    "Location",
                    VPhoneLaunchpadHostSetup.abbreviated(machine.path.url),
                )
            }

            Section("Console") {
                HStack {
                    Button {
                        onOpenConsole(machine.path)
                    } label: {
                        Label("Open Console", systemImage: "arrow.up.right")
                    }
                    Spacer()
                    Button("Recent Commands") { showsCommands = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsCommands) {
            VPhoneLaunchpadCommandHistoryView()
                .environment(model)
        }
    }

    private func value(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    private func creationSummary(_ creation: VPhoneLaunchpadCreationPipeline) -> some View {
        LabeledContent {
            Button(creation.isRunning ? LocalizedStringKey("Show Progress") : LocalizedStringKey("View Details")) {
                onShowProgress(creation.machine)
            }
        } label: {
            if creation.isRunning {
                Label { Text("Creating: \(creation.current?.title ?? "")") } icon: { VPhoneLaunchpadStatusIcon(status: .running) }
            } else if creation.isFinished {
                Label { Text("Created") } icon: { VPhoneLaunchpadStatusIcon(status: .passed) }
            } else {
                Label { Text(creation.failure?.message ?? String(localized: "Creation stopped")) } icon: { VPhoneLaunchpadStatusIcon(status: .failed) }
            }
        }
    }
}
