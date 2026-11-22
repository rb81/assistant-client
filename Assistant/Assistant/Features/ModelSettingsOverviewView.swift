import SwiftUI

/// A single searchable, read-only view of saved model settings, including disabled features.
struct ModelSettingsOverviewView: View {
    let overview: ModelSettingsOverview?
    let loading: Bool
    let error: String?
    let search: String
    let hasDraft: Bool
    let edit: (SettingField) -> Void
    @State private var collapsedSections: Set<String> = []

    /// Existing theme panels and controls preserve the app's native settings presentation.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Model settings").font(Theme.pageTitle).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("model-settings-overview")
            Text("Saved settings only. Running models and provider availability are not verified.")
                .foregroundStyle(Theme.secondary)
            if hasDraft {
                Label("Local draft changes are not shown here.", systemImage: "pencil.circle")
                    .foregroundStyle(Theme.secondary)
            }

            if let error {
                ContentUnavailableView("Model settings unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if loading || overview == nil {
                ProgressView("Loading model settings…")
            } else if let overview {
                activationNotice(overview)
                let sections = overview.matchingSections(search)
                if sections.isEmpty {
                    Text("No model settings match this search.").foregroundStyle(Theme.secondary)
                }
                ForEach(sections) { section in
                    ManagementPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader(section)
                            DisclosureGroup(isExpanded: Binding(
                                get: { !search.isEmpty || !collapsedSections.contains(section.id) },
                                set: { expanded in
                                    if expanded { collapsedSections.remove(section.id) }
                                    else { collapsedSections.insert(section.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 16) {
                                    ForEach(section.settings) { field in
                                        settingRow(field, overview: overview)
                                    }
                                }.padding(.top, 12)
                            } label: {
                                Text("All settings").font(.callout)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Activation tracking is administrative history, not live container inspection.
    @ViewBuilder private func activationNotice(_ overview: ModelSettingsOverview) -> some View {
        if !overview.activationTracked {
            Label("Activation tracking is unavailable for earlier saves.", systemImage: "info.circle")
                .foregroundStyle(Theme.secondary)
        } else if overview.pendingActivation {
            Label("Saved changes are awaiting activation. Use Review & Apply when ready.", systemImage: "clock")
                .foregroundStyle(Theme.secondary)
        } else {
            Label("No tracked saved changes are awaiting activation.", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.secondary)
        }
    }

    /// Roles summarize model choices before the complete field list.
    private func sectionHeader(_ section: ModelOverviewSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title).font(Theme.sectionTitle).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("model-overview-section-\(section.id)")
                Spacer()
                if let enabled = section.enabled {
                    Text(enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            Text("Provider / service: \(section.provider)")
                .font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
            ForEach(section.summary) { field in
                Text("\(field.field.label): \(field.displayValue)")
                    .font(.callout).textSelection(.enabled)
            }
        }
    }

    /// Secret fields show presence only; editor links reuse the revision-reviewed save flow.
    private func settingRow(_ item: ModelOverviewField, overview: ModelSettingsOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(item.field.label).font(.callout.weight(.medium))
                Spacer(minLength: 12)
                Button("Edit") { edit(item.field) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Edit \(item.field.label)"))
                    .accessibilityIdentifier("model-overview-edit-\(item.id)")
            }
            Text(item.displayValue).font(.system(.callout, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if item.valueSource == .inherited, let key = item.inheritedFrom,
               let parent = overview.sections.flatMap(\.settings).first(where: { $0.id == key }) {
                Text("Inherited from \(parent.field.label)").font(.caption).foregroundStyle(Theme.secondary)
            } else if item.valueSource == .providerDefault {
                Text("Provider default").font(.caption).foregroundStyle(Theme.secondary)
            }
            if item.pendingActivation {
                Label("Needs applying", systemImage: "clock").font(.caption).foregroundStyle(Theme.secondary)
            }
            if let help = item.field.help {
                Text(help).font(.caption).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if DEBUG
/// Preview uses the pinned local API fixture, never a live installation.
private struct ModelSettingsOverviewPreview: View {
    @State private var overview: ModelSettingsOverview?
    @State private var error: String?

    var body: some View {
        ScrollView {
            ModelSettingsOverviewView(overview: overview, loading: overview == nil && error == nil,
                                      error: error, search: "", hasDraft: false, edit: { _ in })
                .padding(20)
        }
        .frame(width: Theme.contentWidth, height: 700)
        .task {
            do {
                let data = try await PreviewManagementAPI().request("configuration/model-settings", body: nil, key: nil)
                overview = try Wire.decoder().decode(ModelSettingsOverview.self, from: data)
            } catch { self.error = error.localizedDescription }
        }
    }
}

#Preview("Model settings light") {
    ModelSettingsOverviewPreview().preferredColorScheme(.light)
}

#Preview("Model settings dark") {
    ModelSettingsOverviewPreview().preferredColorScheme(.dark)
}
#endif
