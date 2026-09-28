import AppKit
import SwiftUI

// MARK: - Settings

/// Hardware and network for one machine, or for several at once. The fields
/// start from the first machine; only the ones edited are written, to every
/// machine, so values the machines do not share are left alone.
struct VPhoneLaunchpadMachineSettingsView: View {
    private enum Field {
        case cpu, memory, network
    }

    let machines: [VPhoneLaunchpadMachine]
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cpu: Int
    @State private var memoryMB: Int
    @State private var network: String
    @State private var bridgeInterface: String
    @State private var edited: Set<Field> = []

    init(machines: [VPhoneLaunchpadMachine]) {
        self.machines = machines
        let first = machines.first
        _cpu = State(initialValue: first?.cpuCount ?? 8)
        _memoryMB = State(initialValue: first?.memoryMB ?? 8192)
        _network = State(initialValue: first.map { $0.network.mode == "hostOnly" ? "none" : $0.network.mode } ?? "nat")
        _bridgeInterface = State(initialValue: first?.network.bridgeInterface ?? "")
    }

    private var title: Text {
        machines.count == 1 ? Text("\(machines[0].name) Settings") : Text("Settings for \(machines.count) Machines")
    }

    var body: some View {
        VPhoneLaunchpadSheet(title) {
            Form {
                Section {
                    Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
                    Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
                } header: {
                    Text("Hardware")
                }
                Section {
                    Picker("Mode", selection: $network) {
                        Text("NAT").tag("nat")
                        Text("Bridged").tag("bridged")
                        Text("None").tag("none")
                    }
                    if network == "bridged" {
                        TextField("Interface", text: $bridgeInterface, prompt: Text("First available"))
                    }
                } header: {
                    Text("Network")
                } footer: {
                    if machines.count > 1 {
                        Text("Only the settings you change are applied to each machine.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(edited.isEmpty)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: cpu) { edited.insert(.cpu) }
        .onChange(of: memoryMB) { edited.insert(.memory) }
        .onChange(of: network) { edited.insert(.network) }
        .onChange(of: bridgeInterface) { edited.insert(.network) }
    }

    private func save() {
        let cpu = edited.contains(.cpu) ? cpu : nil
        let memoryMB = edited.contains(.memory) ? memoryMB : nil
        let network = edited.contains(.network) ? network : nil
        let bridgeInterface = network == "bridged" ? bridgeInterface : nil
        let paths = machines.map(\.path)
        let library = model.machines
        Task {
            for path in paths {
                await library.configure(path, cpu: cpu, memoryMB: memoryMB, network: network, bridgeInterface: bridgeInterface)
            }
        }
        dismiss()
    }
}

// MARK: - Rename and clone

struct VPhoneLaunchpadNameSheet: View {
    let title: LocalizedStringKey
    let action: LocalizedStringKey
    let initial: String
    /// The machine renamed or cloned. The new name stays in its library.
    let machine: VPhoneLaunchpadMachinePath
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var fitsLocation: Bool {
        VPhoneLaunchpadMachineLocations.socketPathFits(root: machine.libraryRoot, name: name)
    }

    private var isValid: Bool {
        VPhoneLaunchpadNames.isValidMachineName(name) && name != machine.name && fitsLocation
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text(title)) {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    if fitsLocation {
                        Text("Use letters, numbers, periods, hyphens, and underscores.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The path is too long. Use a shorter name, or a location with a shorter path.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(action) {
                onConfirm(name)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { name = initial }
    }
}

// MARK: - Export

/// One machine offers the archive options. Several are written with the
/// defaults, one `<name>.tzst` each, into a folder chosen once.
struct VPhoneLaunchpadExportView: View {
    let machines: [VPhoneLaunchpadMachinePath]
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var densest = false
    @State private var includeIPSW = false

    private var title: Text {
        machines.count == 1 ? Text("Export \(machines[0].name)") : Text("Export \(machines.count) Machines")
    }

    var body: some View {
        VPhoneLaunchpadSheet(title) {
            Form {
                if machines.count == 1 {
                    Section {
                        Toggle("Maximum compression", isOn: $densest)
                        Toggle("Include the restore IPSW directory", isOn: $includeIPSW)
                    } footer: {
                        Text(densest
                            ? "Creates a smaller .txz archive. Export takes much longer."
                            : "Creates a .tzst archive.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(machines, id: \.self) { machine in
                            Text(verbatim: "\(machine.name).tzst")
                        }
                    } footer: {
                        Text("Creates a .tzst archive for each machine in the folder you choose.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Choose Location…") { choose() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let library = model.machines
        if machines.count == 1 {
            let machine = machines[0]
            let panel = NSSavePanel()
            panel.title = String(localized: "Export \(machine.name)")
            panel.nameFieldStringValue = "\(machine.name).\(densest ? "txz" : "tzst")"
            let densest = densest
            let includeIPSW = includeIPSW
            panel.present { url in
                Task { await library.export([(machine, url)], densest: densest, includeIPSW: includeIPSW) }
                dismiss()
            }
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Export \(machines.count) Machines")
        panel.prompt = String(localized: "Export")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        let machines = machines
        panel.present { folder in
            let items = machines.map { ($0, folder.appendingPathComponent("\($0.name).tzst")) }
            Task { await library.export(items, densest: false, includeIPSW: false) }
            dismiss()
        }
    }
}
