import SwiftUI

/// The patch editor: a preset, and a checkmark for every patch the bundle
/// declares.
///
/// The list is never a copy of the catalogue — it is whatever
/// `vphone-cli fw patches --json` reports, so a patch set added to the bundle
/// shows up here without a change to Launchpad. Only the boxes that differ from
/// the preset are kept, and switching preset re-bases them, since a difference
/// from the preset that is no longer active means nothing.
struct VPhoneLaunchpadPatchSettingsView: View {
    typealias Catalog = VPhoneLaunchpadPatchCatalog

    /// The machine whose record this edits, or nil while New Machine is still
    /// composing one that no directory exists for yet.
    let machine: VPhoneLaunchpadMachinePath?
    /// What the boxes start from. An existing machine has its own record, read
    /// back through `fw patches`, so only New Machine passes one.
    let initial: VPhoneLaunchpadPatchSelection
    /// Hands the edited choice back. An existing machine's caller writes it with
    /// `fw set-patches`; New Machine holds it until the VM exists.
    let onSave: (VPhoneLaunchpadPatchSelection) -> Void

    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: VPhoneLaunchpadPatchSelection
    @State private var catalog: Catalog?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var filter = ""
    /// Empty keeps the order the bundle applies the patches in; a header click
    /// replaces it.
    @State private var sortOrder: [KeyPathComparator<Catalog.Patch>] = []
    /// The row whose summary the detail pane reads.
    @State private var highlighted: String?
    @State private var confirmsBootEssential = false

    init(
        machine: VPhoneLaunchpadMachinePath?,
        initial: VPhoneLaunchpadPatchSelection = VPhoneLaunchpadPatchSelection(),
        onSave: @escaping (VPhoneLaunchpadPatchSelection) -> Void,
    ) {
        self.machine = machine
        self.initial = initial
        self.onSave = onSave
        _selection = State(initialValue: initial)
    }

    private var essentialOff: [Catalog.Patch] {
        catalog.map { selection.bootEssentialOff(in: $0) } ?? []
    }

    var body: some View {
        VPhoneLaunchpadSheet(machine.map { Text("\($0.name) Patches") } ?? Text("Patches")) {
            VStack(spacing: 0) {
                header
                Divider()
                list
                Divider()
                detailPane
            }
        } accessory: {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(machine == nil ? "Done" : "Save") { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(catalog == nil)
        }
        .frame(width: 920, height: 680)
        .confirmationDialog(
            "Leave ^[\(essentialOff.count) boot-essential patch](inflect: true) off?",
            isPresented: $confirmsBootEssential,
        ) {
            Button("Leave Them Off", role: .destructive) { finish() }
        } message: {
            Text("The machine may not boot without \(essentialOff.map(\.identifier).joined(separator: ", ")).")
        }
        .task { await load(preset: machine == nil ? initial.preset : nil) }
    }

    // MARK: - Preset

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Preset", selection: presetBinding) {
                    ForEach(catalog?.presets ?? []) { preset in
                        Text(verbatim: preset.title).tag(preset.identifier)
                    }
                }
                .disabled(catalog == nil || isLoading)
                .frame(width: 280)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                TextField("Filter", text: $filter, prompt: Text("Filter patches"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            if let summary = catalog?.preset(selection.preset)?.summary, !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    /// Switching preset clears both override lists: the checkmarks are read as a
    /// difference from the preset, so a difference from the one just left behind
    /// would silently change meaning.
    private var presetBinding: Binding<String> {
        Binding(
            get: { selection.preset },
            set: { identifier in
                guard identifier != selection.preset else {
                    return
                }
                selection = VPhoneLaunchpadPatchSelection(preset: identifier)
                Task { await load(preset: identifier) }
            },
        )
    }

    // MARK: - Patches

    @ViewBuilder
    private var list: some View {
        if let catalog {
            let rows = catalog.patches(matching: filter).sorted(using: sortOrder)
            if rows.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                table(rows)
            }
        } else if let loadError {
            ContentUnavailableView {
                Label("No Patch List", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: loadError)
            }
        } else {
            VStack {
                ProgressView()
                Text("Reading the bundle's patches…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A flat table sorted by the order the bundle applies the patches, which
    /// already runs one set after another. A header click regroups it; sections
    /// were tried first and make AppKit report a reentrant table delegate.
    private func table(_ rows: [Catalog.Patch]) -> some View {
        Table(rows, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("On") { patch in
                Toggle("On", isOn: Binding(
                    get: { selection.isOn(patch) },
                    set: { selection.set(patch, on: $0) },
                ))
                .labelsHidden()
            }
            .width(28)

            TableColumn("Patch", value: \.title) { patch in
                Text(verbatim: patch.title)
                    .lineLimit(1)
                    .help(patch.summary)
            }
            .width(min: 130, ideal: 180)

            TableColumn("Identifier", value: \.identifier) { patch in
                Text(verbatim: patch.identifier)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(patch.identifier)
            }
            .width(min: 200, ideal: 350)

            TableColumn("Patch Set", value: \.patchSetName) { patch in
                Text(verbatim: patch.patchSetName).lineLimit(1)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Applies To", value: \.applicability) { patch in
                if patch.isVersionGated {
                    Text(verbatim: patch.applicability).lineLimit(1)
                } else {
                    Text("Any version").foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .width(min: 80, ideal: 110)

            TableColumn("Boot") { patch in
                if patch.bootEssential {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(selection.isOn(patch) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .help(selection.isOn(patch)
                            ? String(localized: "Boot-essential")
                            : String(localized: "Boot-essential, and off"))
                }
            }
            .width(32)
        }
    }

    // MARK: - Detail

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !essentialOff.isEmpty {
                Label {
                    Text("^[\(essentialOff.count) boot-essential patch](inflect: true) off: \(essentialOff.map(\.identifier).joined(separator: ", "))")
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .font(.callout)
            }
            detail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private var detail: some View {
        if let patch = catalog?.patch(highlighted) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: patch.title).font(.headline)
                Text(verbatim: patch.summary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: patch.isVersionGated
                    ? "\(patch.patchSetName) · \(patch.target) · \(patch.applicability)"
                    : "\(patch.patchSetName) · \(patch.target)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 62, alignment: .topLeading)
        } else {
            Text("Select a patch to read what it changes.")
                .foregroundStyle(.secondary)
                .frame(height: 62, alignment: .topLeading)
        }
    }

    /// What is on, what differs from the preset, and when the choice takes effect.
    private var status: String {
        guard let catalog else {
            return ""
        }
        let on = catalog.patches.count(where: { selection.isOn($0) })
        var text = String(localized: "\(on) of \(catalog.patches.count) patches on.")
        if selection.hasOverrides {
            text += String(localized: " Differs from the preset: \(selection.blocked.count) off, \(selection.allowed.count) on.")
        }
        return machine == nil
            ? text + String(localized: " Recorded when the machine is created.")
            : text + String(localized: " Applies the next time the boot chain is patched.")
    }

    // MARK: - Actions

    private func load(preset: String?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let catalog = try await Catalog.read(
                using: model.bundles.commandLine(),
                machine: machine,
                preset: preset,
            )
            // A second switch of the picker may have overtaken this read.
            guard preset == nil || preset == selection.preset else {
                return
            }
            // A nil preset means "report what the VM has recorded", so its own
            // choice is what the boxes start from.
            selection.preset = catalog.activePreset
            if preset == nil {
                selection.blocked = Set(catalog.blockedPatches)
                selection.allowed = Set(catalog.allowedPatches)
            }
            selection.normalize(against: catalog)
            self.catalog = catalog
            // The detail pane reserves its space either way, so it starts with
            // something to read rather than a gap.
            highlighted = highlighted ?? catalog.patches.first?.identifier
            loadError = nil
        } catch {
            loadError = VPhoneLaunchpadError.message(for: error)
        }
    }

    private func commit() {
        if essentialOff.isEmpty {
            finish()
        } else {
            confirmsBootEssential = true
        }
    }

    private func finish() {
        onSave(selection)
        dismiss()
    }
}
