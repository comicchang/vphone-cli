import AppKit
import SwiftUI

/// The commands Launchpad ran, newest first, in a sheet.
struct VPhoneLaunchpadCommandHistoryView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []

    private var entries: [VPhoneLaunchpadCommandHistory.Entry] {
        model.history.entries.reversed()
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Recent Commands")) {
            if entries.isEmpty {
                ContentUnavailableView("Commands that Launchpad runs appear here.", systemImage: "terminal")
            } else {
                table
            }
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 760, height: 460)
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("") { entry in
                VPhoneLaunchpadStatusIcon(status: entry.status.map { $0 == 0 ? .passed : .failed } ?? .running)
                    .help(entry.status.map { String(localized: "Exit status \($0)") } ?? "")
            }
            .width(20)
            TableColumn("Started") { entry in
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Command") { entry in
                Text(verbatim: entry.text)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.text)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Copy Command") { copy(ids) }
                .disabled(ids.isEmpty)
        }
        .onCopyCommand {
            let text = commands(selection)
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
    }

    /// The selected commands, one per line, in the order the table shows them.
    private func commands(_ ids: Set<UUID>) -> String {
        entries.filter { ids.contains($0.id) }.map(\.text).joined(separator: "\n")
    }

    private func copy(_ ids: Set<UUID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands(ids), forType: .string)
    }
}
