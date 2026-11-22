import SwiftUI

/// A focused model editor; provider configuration and tuning stay on their owning pages.
struct ModelSettingsOverviewView<ModelRow: View>: View {
    let overview: ModelSettingsOverview?
    let loading: Bool
    let error: String?
    let search: String
    @ViewBuilder let modelRow: (SettingField) -> ModelRow
    let openSettings: (ModelSettingsLink) -> Void

    /// Existing theme panels and controls preserve the app's native settings presentation.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Model settings").font(Theme.pageTitle).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("model-settings-overview")
            Text("Choose models here. Provider, safety, voice, and tuning controls stay in the linked settings pages. Changes use the same reviewed draft.")
                .foregroundStyle(Theme.secondary)

            if let error {
                ContentUnavailableView("Model settings unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if loading || overview == nil {
                HStack {
                    StableProgress(active: true)
                    Text("Loading model settings…").foregroundStyle(Theme.secondary)
                }
            } else if overview?.sections.contains(where: { $0.selectionKeys == nil || $0.relatedSettings == nil }) == true {
                ContentUnavailableView("Update the server", systemImage: "arrow.up.circle",
                                       description: Text("Quick model editing requires updated model settings metadata. Use the existing settings pages until the server is updated."))
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
                            ForEach(section.selections) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    modelRow(item.field)
                                        .accessibilityIdentifier("model-overview-edit-\(item.id)")
                                    if item.valueSource == .inherited || item.valueSource == .providerDefault {
                                        Text("Saved effective model: \(item.displayValue)")
                                            .font(.caption).foregroundStyle(Theme.secondary)
                                    }
                                    if item.pendingActivation {
                                        Label("Saved model needs applying", systemImage: "clock")
                                            .font(.caption).foregroundStyle(Theme.secondary)
                                    }
                                }
                            }
                            if let links = section.relatedSettings, !links.isEmpty {
                                Divider()
                                Text("Other settings").font(.caption).foregroundStyle(Theme.secondary)
                                ForEach(links) { link in
                                    Button { openSettings(link) } label: {
                                        Label(link.title, systemImage: "arrow.up.right")
                                    }
                                    .buttonStyle(.link)
                                    .accessibilityIdentifier("model-settings-link-\(section.id)-\(link.id)")
                                }
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
                                      error: error, search: "",
                                      modelRow: { field in Text(field.value) }, openSettings: { _ in })
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
