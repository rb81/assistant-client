import SwiftUI

/// Searchable, capability-filtered catalog choices preserve an unavailable saved ID without inventing substitutes.
struct ModelSelectionView: View {
    let catalog: OpenRouterCatalog
    let purpose: ModelPurpose
    let zdr: Bool
    let multiple: Bool
    @Binding var value: String
    @State private var showing = false
    @State private var search = ""

    private var selectedIDs: [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    private var models: [OpenRouterModel] { catalog.models(zdr: zdr, purpose: purpose) }
    private var matches: [OpenRouterModel] {
        models.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) ||
            $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showing.toggle() } label: {
                    HStack {
                        Text(value.isEmpty ? String(localized: "Choose a model…") : value)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.outline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose OpenRouter model")
                .popover(isPresented: $showing) { choices }
                StableProgress(active: catalog.loading.contains(zdr))
            }
            if let error = catalog.errors[zdr] {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if catalog.fetchedAt(zdr: zdr) != nil,
               selectedIDs.contains(where: { id in !models.contains(where: { $0.id == id }) }) {
                Label("A saved model is not in this catalog or does not meet this field’s requirements. Choose an eligible model before saving.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if zdr {
                Label("Zero Data Retention endpoints only", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .task(id: zdr) { await catalog.refresh(zdr: zdr) }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(zdr ? "ZDR-compatible models" : "OpenRouter models").font(.headline)
            TextField("Search models", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    Button("Use default / Not set") { value = ""; showing = false }
                        .buttonStyle(.borderless).padding(8)
                    ForEach(matches) { model in
                        let selected = selectedIDs.contains(model.id)
                        Button {
                            if multiple {
                                value = (selected ? selectedIDs.filter { $0 != model.id } : selectedIDs + [model.id])
                                    .joined(separator: ",")
                            } else {
                                value = model.id
                                showing = false
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.name).font(.body.weight(.medium))
                                    Text(model.id).font(.caption).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }.padding(9).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selected ? Theme.accent.opacity(0.1) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                    if matches.isEmpty {
                        Text(catalog.loading.contains(zdr) ? "Loading models…" :
                                catalog.fetchedAt(zdr: zdr) == nil ? "Refresh to load the model list." : "No eligible models match.")
                            .foregroundStyle(Theme.secondary).padding(12)
                    }
                }
            }.frame(height: 310)
            Divider()
            ModelCatalogControls(catalog: catalog, zdr: zdr)
            Text("Catalog eligibility does not guarantee account access or current endpoint availability.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }.padding(16).frame(width: 440)
    }
}

/// Client-only catalog refresh controls are shared by every model picker and local preferences.
struct ModelCatalogControls: View {
    @Bindable var catalog: OpenRouterCatalog
    let zdr: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Refresh automatically each week", isOn: $catalog.automaticallyRefresh)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: catalog.automaticallyRefresh) {
                        if catalog.automaticallyRefresh { Task { await catalog.refresh(zdr: zdr) } }
                    }
                Spacer()
                Button("Refresh models", systemImage: "arrow.clockwise") {
                    Task { await catalog.refresh(zdr: zdr, force: true) }
                }.disabled(catalog.loading.contains(zdr))
            }
            if let date = catalog.fetchedAt(zdr: zdr) {
                Text("Last refreshed \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }
}
