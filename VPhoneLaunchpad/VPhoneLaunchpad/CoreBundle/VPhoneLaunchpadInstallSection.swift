import SwiftUI

/// The last Core Bundle install, as a section at the top of the inspector.
/// Its header collapses it to one summary row. It stays until dismissed,
/// across relaunches, and offers Retry and Skip when a step fails.
struct VPhoneLaunchpadInstallSection: View {
    @Environment(VPhoneLaunchpadModel.self) private var model

    private var bundles: VPhoneLaunchpadCoreBundle {
        model.bundles
    }

    var body: some View {
        if let progress = bundles.progress {
            Section {
                summary(progress)
                if model.isInstallExpanded {
                    details(progress)
                }
            } header: {
                header
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { model.isInstallExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("Core Bundle Install")
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(model.isInstallExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.isInstallExpanded ? "Hide the install steps" : "Show the install steps")
    }

    // MARK: - Summary

    private func summary(_ progress: VPhoneLaunchpadCoreBundle.InstallProgress) -> some View {
        HStack(spacing: 8) {
            VPhoneLaunchpadStatusIcon(status: progress.overall)
            Text(verbatim: progress.version.map { "VPhone.bundle \($0)" } ?? progress.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(state(progress))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func state(_ progress: VPhoneLaunchpadCoreBundle.InstallProgress) -> String {
        switch progress.overall {
        case .running: String(localized: "Installing…")
        case .failed where progress.status(.install) == .passed: String(localized: "Checks failed")
        case .failed: String(localized: "Not installed")
        case .warning: String(localized: "Checks skipped")
        default: String(localized: "Installed")
        }
    }

    // MARK: - Details

    @ViewBuilder
    private func details(_ progress: VPhoneLaunchpadCoreBundle.InstallProgress) -> some View {
        ForEach(progress.plan) { step in
            HStack(spacing: 8) {
                VPhoneLaunchpadStatusIcon(status: progress.status(step))
                Text(step.title)
                Spacer(minLength: 8)
                if step == .download, progress.status(.download) == .running {
                    Text("\(VPhoneLaunchpadCoreBundleView.size(progress.received)) of \(VPhoneLaunchpadCoreBundleView.size(progress.size))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if progress.status(step) == .warning {
                    Text("Skipped")
                        .foregroundStyle(.secondary)
                }
            }
        }
        if progress.status(.download) == .running {
            ProgressView(value: Double(progress.received), total: Double(max(progress.size, 1)))
                .labelsHidden()
        }
        if let error = progress.error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error.message)
                if let detail = error.detail {
                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !bundles.isInstalling {
            HStack {
                Spacer()
                Button("Dismiss") { bundles.dismissProgress() }
                if progress.canSkip {
                    Button("Skip") { bundles.skipFailedChecks() }
                        .help("Use this version without the failed checks.")
                }
                if progress.error != nil {
                    Button("Retry") {
                        Task { await model.retryInstall() }
                    }
                    .disabled(!model.canInstallBundles && progress.status(.install) != .passed)
                }
            }
        }
    }
}
