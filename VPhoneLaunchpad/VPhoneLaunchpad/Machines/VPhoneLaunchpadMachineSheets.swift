import AppKit
import SwiftUI

// MARK: - Settings

struct VPhoneLaunchpadMachineSettingsView: View {
    let machine: VPhoneLaunchpadMachine
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cpu = 8
    @State private var memoryMB = 8192
    @State private var network = "nat"
    @State private var bridgeInterface = ""

    private var currentNetwork: String {
        machine.network.mode == "hostOnly" ? "none" : machine.network.mode
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("\(machine.name) Settings")) {
            Form {
                Section {
                    Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
                    Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
                } header: {
                    Text("Hardware")
                }
                Section("Network") {
                    Picker("Mode", selection: $network) {
                        Text("NAT").tag("nat")
                        Text("Bridged").tag("bridged")
                        Text("None").tag("none")
                    }
                    if network == "bridged" {
                        TextField("Interface", text: $bridgeInterface, prompt: Text("First available"))
                    }
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            cpu = machine.cpuCount
            memoryMB = machine.memoryMB
            network = currentNetwork
            bridgeInterface = machine.network.bridgeInterface ?? ""
        }
    }

    private func save() {
        let bridgeChanged = bridgeInterface != (machine.network.bridgeInterface ?? "")
        Task {
            await model.machines.configure(
                machine.path,
                cpu: cpu == machine.cpuCount ? nil : cpu,
                memoryMB: memoryMB == machine.memoryMB ? nil : memoryMB,
                network: network == currentNetwork && !bridgeChanged ? nil : network,
                bridgeInterface: network == "bridged" ? bridgeInterface : nil,
            )
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

struct VPhoneLaunchpadExportView: View {
    let machine: VPhoneLaunchpadMachinePath
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var densest = false
    @State private var includeIPSW = false

    private var name: String {
        machine.name
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Export \(name)")) {
            Form {
                Section {
                    Toggle("Maximum compression", isOn: $densest)
                    Toggle("Include the restore IPSW directory", isOn: $includeIPSW)
                } footer: {
                    Text(densest
                        ? "Creates a smaller .txz archive. Export takes much longer."
                        : "Creates a .tzst archive.")
                        .foregroundStyle(.secondary)
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
        let panel = NSSavePanel()
        panel.title = String(localized: "Export \(name)")
        panel.nameFieldStringValue = "\(name).\(densest ? "txz" : "tzst")"
        let densest = densest
        let includeIPSW = includeIPSW
        panel.present { url in
            Task { await model.machines.export(machine, to: url, densest: densest, includeIPSW: includeIPSW) }
            dismiss()
        }
    }
}
