import SwiftUI

/// Provider choices come from public endpoint metadata and retain unavailable saved selections.
struct ProviderSelectionView: View {
    let catalog: OpenRouterCatalog
    let zdr: Bool
    @Binding var value: String
    @State private var showing = false
    @State private var search = ""

    private var selected: [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(value.isEmpty ? String(localized: "No provider preference") : value) {
                    showing.toggle()
                }
                .accessibilityIdentifier("openrouter-provider-picker")
                .popover(isPresented: $showing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(zdr ? "ZDR-compatible providers" : "OpenRouter providers").font(.headline)
                        TextField("Search providers", text: $search)
                        Button("No provider preference") { value = ""; showing = false }
                        ScrollView {
                            LazyVStack(alignment: .leading) {
                                ForEach(catalog.providers(zdr: zdr).filter {
                                    search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) ||
                                        $0.id.localizedCaseInsensitiveContains(search)
                                }) { provider in
                                    Button {
                                        value = (selected.contains(provider.id) ?
                                            selected.filter { $0 != provider.id } : selected + [provider.id])
                                            .joined(separator: ",")
                                    } label: {
                                        HStack {
                                            Text(provider.name)
                                            Text(provider.id).foregroundStyle(Theme.secondary)
                                            Spacer()
                                            if selected.contains(provider.id) { Image(systemName: "checkmark") }
                                        }.padding(6).contentShape(Rectangle())
                                    }
                                    .accessibilityIdentifier("openrouter-provider-\(provider.id)")
                                    .buttonStyle(.plain)
                                }
                            }
                        }.frame(height: 280)
                        Button("Refresh providers", systemImage: "arrow.clockwise") {
                            Task { await catalog.refreshProviders(zdr: zdr, force: true) }
                        }.disabled(catalog.providersLoading.contains(zdr))
                        Text("Public availability can differ from your account and may change.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }.padding(16).frame(width: 440)
                }
                StableProgress(active: catalog.providersLoading.contains(zdr))
            }
            if let error = catalog.providerErrors[zdr] {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if catalog.providersFetchedAt(zdr: zdr) != nil {
                let unavailable = selected.filter { id in
                    !catalog.providers(zdr: zdr).contains { id == $0.id || id.hasPrefix($0.id + "/") }
                }
                if !unavailable.isEmpty {
                    Label("Some selected providers are unavailable under the current catalog policy. Requests may fail; remove them or change the policy.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    ForEach(unavailable, id: \.self) { id in
                        Button("Remove \(id)") {
                            value = selected.filter { $0 != id }.joined(separator: ",")
                        }.font(.caption)
                    }
                }
            }
        }
        .task(id: zdr) { await catalog.refreshProviders(zdr: zdr) }
    }
}

/// Native provider catalogs are fetched through the authenticated Management API.
struct ProviderModelSelectionView: View {
    let models: [ProviderModel]
    let loading: Bool
    let refresh: () async -> Void
    @Binding var value: String
    @State private var showing = false
    @State private var search = ""

    private var matches: [ProviderModel] {
        models.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) ||
            $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(value.isEmpty ? String(localized: "Choose a discovered model…") : value) {
                showing.toggle()
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Available provider models").font(.headline)
                    TextField("Search models", text: $search)
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(matches) { model in
                                Button {
                                    value = model.id
                                    showing = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.name)
                                        Text(model.id).font(.caption).foregroundStyle(Theme.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                                }
                                .buttonStyle(.plain)
                            }
                            if matches.isEmpty {
                                Text("No models match this search.").foregroundStyle(Theme.secondary).padding(8)
                            }
                        }
                    }.frame(height: 280)
                    Button("Refresh provider models", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }.disabled(loading)
                    if loading { ProgressView("Loading models…") }
                }.padding(16).frame(width: 440)
            }
        }
    }
}

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
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.outline).allowsHitTesting(false))
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

#if DEBUG
/// Preview uses deterministic provider identifiers and never contacts a live server.
private struct ProviderModelSelectionPreview: View {
    @State private var value = "claude-sonnet-4-6"
    private let models = [
        ProviderModel(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6"),
        ProviderModel(id: "claude-opus-4-6", name: "Claude Opus 4.6"),
    ]

    var body: some View {
        ProviderModelSelectionView(models: models, loading: false, refresh: {}, value: $value)
            .padding(24).frame(width: 520, alignment: .leading)
    }
}

#Preview("Native model picker light") {
    ProviderModelSelectionPreview().preferredColorScheme(.light)
}

#Preview("Native model picker dark") {
    ProviderModelSelectionPreview().preferredColorScheme(.dark)
}
#endif
