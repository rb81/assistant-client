import SwiftUI

/// One setting: label and explanation above a full-width control, with details one click away.
struct SettingRow: View {
    let field: SettingField
    let showIdentifier: Bool
    var credential: SavedCredential? = nil
    var credentialStatusLoaded = false
    var modelCatalog: OpenRouterCatalog? = nil
    var modelPurpose: ModelPurpose? = nil
    var providerModels: [ProviderModel]? = nil
    var providerModelsLoading = false
    var refreshProviderModels: (() async -> Void)? = nil
    var eligibilityWarning: String? = nil
    var zdrOnly = false
    var choices: [String]? = nil
    var selectionChoices: SettingChoices? = nil
    var choicesLoading = false
    var refreshChoices: (() async -> Void)? = nil
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if field.boolean && field.editable {
                Toggle(isOn: Binding(get: { value.lowercased() == "true" },
                                     set: { value = $0 ? "true" : "false" })) { heading }
                    .toggleStyle(.switch)
            } else {
                heading
                control
            }
            if let warning = field.warning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let eligibilityWarning {
                Label(eligibilityWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label, optional identifier, and explanation; the info button reveals defaults and allowed values.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(field.label).font(.system(.body, weight: .medium))
                SettingInfoButton(field: field)
            }
            if showIdentifier {
                Text(verbatim: field.key).font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
            }
            if let help = field.help {
                Text(help).font(.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Secret placeholders are never sent back as replacement credentials.
    @ViewBuilder private var control: some View {
        if !field.editable {
            Text(field.value.isEmpty ? String(localized: "Not set") : field.value)
                .textSelection(.enabled).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if field.secret {
            SecureField(field.label, text: $value, prompt: Text("Leave blank to keep the saved value"))
                .textFieldStyle(.roundedBorder)
            if !value.isEmpty {
                Label("Replacement not saved", systemImage: "pencil.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if let credential {
                Label(credential.title, systemImage: credential.active ? "checkmark.circle.fill" : "clock")
                    .font(.caption).foregroundStyle(credential.active ? .green : .orange)
            } else {
                Label(credentialStatusLoaded ? "No saved key" : "Saved key status unavailable",
                      systemImage: "key")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        } else if let selection = field.metadata?["selection"]?.string,
                  ["multiple", "ordered"].contains(selection) {
            SettingSelectionList(choices: selectionChoices?.choices ?? choices ?? field.choices ?? [],
                                 labels: selectionChoices?.choiceLabels ?? [:],
                                 field: field, ordered: selection == "ordered", value: $value)
            if let refreshChoices {
                Button(choicesLoading ? "Loading choices…" : "Refresh choices") {
                    Task { await refreshChoices() }
                }.disabled(choicesLoading)
            }
            ForEach(selectionChoices?.warnings ?? [], id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        } else if let modelCatalog, field.key == "AGENT_LLM_ALLOWED_PROVIDERS" {
            ProviderSelectionView(catalog: modelCatalog, zdr: zdrOnly, value: $value)
        } else if let modelCatalog, let modelPurpose {
            ModelSelectionView(catalog: modelCatalog, purpose: modelPurpose, zdr: zdrOnly,
                               multiple: field.key == "AGENT_FUSION_ANALYSIS_MODELS", value: $value)
        } else if [
            "AGENT_LLM_MODEL", "AGENT_LLM_FALLBACK_MODEL", "AGENT_NAMING_MODEL",
            "AGENT_ROUTING_MODEL", "AGENT_LIMITS_SUMMARIZATION_MODEL", "AGENT_MEMORY_STEWARD_MODEL",
            "AGENT_DEEP_RESEARCH_MODEL", "AGENT_DEEP_RESEARCH_SEARCH_MODEL", "AGENT_SEARCH_MODEL",
            "AGENT_SECURITY_DEVELOPMENT_MODEL",
        ].contains(field.key), modelPurpose == nil,
                  let refreshProviderModels {
            ProviderModelSelectionView(models: providerModels ?? [], loading: providerModelsLoading,
                                       refresh: refreshProviderModels, value: $value)
        } else if let choices = choices ?? field.choices {
            Picker(field.label, selection: $value) {
                // Preserve an unavailable saved value without letting it become a new selection.
                ForEach(choices.contains(value) ? choices : [value] + choices, id: \.self) { choice in
                    Text(choice.isEmpty ? String(localized: "Not set") : field.choiceLabel(choice)).tag(choice)
                        .disabled(!choices.contains(choice))
                }
            }
            .disabled(choices.isEmpty)
            .labelsHidden().frame(maxWidth: Self.pickerWidth, alignment: .leading)
            if choices.isEmpty {
                Text("No configured choices are available. Complete and save the related setup first.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            } else if !choices.contains(value), !value.isEmpty {
                Text("The saved choice is unavailable. Select a configured option before saving this setting.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            TextField(field.label, text: $value, prompt: field.defaultText.map { Text($0) })
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Searchable multi-selection keeps wire-format lists out of the editor and makes order explicit.
    private struct SettingSelectionList: View {
        let choices: [String]
        let labels: [String: String]
        let field: SettingField
        let ordered: Bool
        @Binding var value: String
        @State private var search = ""

        private var selected: [String] {
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if ordered && !selected.isEmpty {
                    ForEach(Array(selected.enumerated()), id: \.element) { index, item in
                        HStack {
                            Text("\(index + 1). \(label(item))")
                            Spacer()
                            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).accessibilityLabel("Move up")
                            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == selected.count - 1).accessibilityLabel("Move down")
                        }
                    }
                }
                if choices.count > 8 {
                    TextField("Search choices", text: $search).textFieldStyle(.roundedBorder)
                }
                if choices.isEmpty {
                    Text("No configured choices are available. Complete and save the related setup first.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach((selected.filter { !choices.contains($0) } + choices).filter {
                            search.isEmpty || label($0).localizedCaseInsensitiveContains(search) ||
                                $0.localizedCaseInsensitiveContains(search)
                        }, id: \.self) { item in
                            Toggle(isOn: Binding(get: { selected.contains(item) }, set: { enabled in
                                var items = selected.filter { $0 != item }
                                if enabled && choices.contains(item) { items.append(item) }
                                value = items.joined(separator: ",")
                            })) {
                                Text(label(item) + (choices.contains(item) ? "" :
                                    " · " + String(localized: "Saved choice unavailable")))
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
            }
        }

        private func label(_ item: String) -> String { labels[item] ?? field.choiceLabel(item) }

        private func move(_ index: Int, by offset: Int) {
            var items = selected
            let target = index + offset
            guard items.indices.contains(target) else { return }
            items.swapAt(index, target)
            value = items.joined(separator: ",")
        }
    }

    /// Pickers hold short values; stretching them across the page makes them harder to scan.
    private static let pickerWidth: CGFloat = 280
}

/// Help popover tying a setting's label to its explanation, identifier, and default.
private struct SettingInfoButton: View {
    let field: SettingField
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
        .help("About this setting")
        .accessibilityLabel(Text("About \(field.label)"))
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(field.label).font(.headline)
                Text(field.help ?? String(localized: "No description is available for this setting."))
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                detail("Identifier", field.key, monospaced: true)
                if let defaultText = field.defaultText { detail("Default", defaultText, monospaced: true) }
                if let choices = field.choices { detail("Allowed values", choices.joined(separator: ", "), monospaced: true) }
                if let warning = field.warning { detail("Note", warning, monospaced: false) }
            }
            .padding(Theme.spacing).frame(width: Self.width, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private func detail(_ title: LocalizedStringKey, _ value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            Text(verbatim: value).font(monospaced ? .callout.monospaced() : .callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let width: CGFloat = 340
}

#if DEBUG
/// Deterministic settings controls let previews exercise selected, unavailable, and ordered options.
private struct ProviderSettingsControlsPreview: View {
    @State private var value = "openai,anthropic"

    private var field: SettingField {
        let choices: [JSONValue] = [.string("openrouter"), .string("openai"), .string("anthropic")]
        let labels: JSONValue = .object(["openrouter": .string("OpenRouter"), "openai": .string("OpenAI"),
                                         "anthropic": .string("Anthropic")])
        let metadata: JSONValue = .object(["selection": .string("ordered"), "choices": .array(choices),
                                           "choice_labels": labels])
        return SettingField(
            group: "providers", key: "AGENT_PROVIDERS_PRIORITY", label: "Provider selection order",
            value: "", secret: false, boolean: false, editable: true, editRestriction: nil,
            metadata: metadata, defaultValue: nil)
    }

    var body: some View {
        SettingRow(field: field, showIdentifier: false, value: $value)
            .padding(24).frame(width: 520, height: 330)
    }
}

#Preview("Provider settings light") {
    ProviderSettingsControlsPreview().preferredColorScheme(.light)
}

#Preview("Provider settings dark") {
    ProviderSettingsControlsPreview().preferredColorScheme(.dark)
}
#endif
