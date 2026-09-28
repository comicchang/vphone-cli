import SwiftUI

struct VPhoneLaunchpadRootView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var host = model.host
        @Bindable var bundles = model.bundles
        VPhoneLaunchpadMachinesView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    panelButton(.hostSetup, systemImage: "checklist", needsAttention: model.hostNeedsAttention)
                    panelButton(.coreBundle, systemImage: "shippingbox", needsAttention: model.bundleNeedsAttention)
                }
            }
            .navigationTitle("Machines")
            .task { await model.start() }
            .sheet(item: $model.panel) { panel in
                Group {
                    switch panel {
                    case .hostSetup:
                        VPhoneLaunchpadHostSetupView()
                    case .coreBundle:
                        VPhoneLaunchpadCoreBundleView()
                    }
                }
                .environment(model)
            }
            // A sheet shows its own errors; these cover work done with none
            // open, such as the helper update on launch.
            .errorAlert($host.actionError, isEnabled: model.panel == nil)
            .errorAlert($bundles.actionError, isEnabled: model.panel == nil)
    }

    private func panelButton(_ panel: VPhoneLaunchpadModel.Panel, systemImage: String, needsAttention: Bool) -> some View {
        Button {
            model.panel = panel
        } label: {
            Label {
                Text(panel.title)
            } icon: {
                if needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Image(systemName: systemImage)
                }
            }
        }
        .help(needsAttention ? "\(panel.title) needs attention" : panel.title)
    }
}

extension View {
    /// Presents an action error as an alert and clears it when dismissed.
    func errorAlert(_ error: Binding<VPhoneLaunchpadError?>, isEnabled: Bool = true) -> some View {
        alert(
            error.wrappedValue?.message ?? "",
            isPresented: Binding(
                get: { isEnabled && error.wrappedValue != nil },
                set: {
                    if !$0 {
                        error.wrappedValue = nil
                    }
                },
            ),
            presenting: error.wrappedValue,
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.detail ?? "")
        }
    }
}
