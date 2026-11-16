import SwiftUI

/// Guided server configuration with immutable previews, source backups, and explicit activation.
struct ConfigurationView: View {
    let model: ClientModel
    @State private var configuration: FullConfiguration?
    @State private var credentials: [SavedCredential] = []
    @State private var credentialStatusLoaded = false
    @State private var credentialError: String?
    @State private var values: [String: String] = [:]
    @State private var instructions = ""
    @State private var yaml = ""
    @State private var page = SettingsPage.group("identity")
    @State private var search = ""
    @State private var acknowledge = false
    @State private var preview: JSONValue?
    @State private var reviewedPayload: [String: JSONValue]?
    @State private var confirming = false
    @State private var apply = false
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var confirmingCacheClear = false
    @AppStorage("settings.showAdvanced") private var showAdvanced = false
    @AppStorage("settings.showIdentifiers") private var showIdentifiers = false

    private var navigation: SettingsNavigation? { configuration.map(SettingsNavigation.init) }

    /// All changes stay in memory until a server-reviewed draft is explicitly confirmed.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 16) {
                PageHeading(title: "Settings", subtitle: "Make Assistant yours. Fine-tune the rest only when you need to.")
                TextField("Find a setting", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(model.configurationDirty || busy)
                Button("Clear chat cache…", systemImage: "internaldrive") { confirmingCacheClear = true }
                    .disabled(model.chats.sending)
            }
            if let error { ErrorBanner(message: error) }
            if let credentialError { ErrorBanner(message: credentialError) }
            if let notice { Label(notice, systemImage: "info.circle").foregroundStyle(Theme.secondary).textSelection(.enabled) }
            HStack(alignment: .top, spacing: 24) {
                sidebar.frame(width: Self.sidebarWidth)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !search.isEmpty { searchResults }
                        else {
                            switch page {
                            case .group(let id): groupPage(id)
                            case .instructions: instructionsEditor
                            case .agentYaml: yamlEditor
                            }
                        }
                        setupAcknowledgment
                        if let preview { changeReview(preview) }
                    }.frame(maxWidth: Theme.contentWidth, alignment: .leading).padding(.bottom, 20)
                }
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(model.configurationDirty ? "Unsaved changes" : "All changes saved")
                    .font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Review changes") { Task { await review() } }
                    .disabled(!model.configurationDirty || busy)
                Button("Save") { apply = false; confirming = true }
                    .disabled(!canSave || yamlChanged || busy)
                Button("Save & Apply") { apply = true; confirming = true }
                    .buttonStyle(CopperButtonStyle()).disabled(!canSave || busy || configuration?.agentYaml == nil)
                    .help(configuration?.agentYaml == nil ? "Update the server to enable combined save and activation." : "Save and activate reviewed changes")
            }
        }
        .padding(24).task { await load() }
        .disabled(busy)
        .confirmationDialog("Clear cached conversations from this Mac?", isPresented: $confirmingCacheClear) {
            Button("Clear local cache", role: .destructive) { model.chats.clearSavedCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Server history is preserved. Conversations will be downloaded again when you open Chats.")
        }
        .onChange(of: showAdvanced) {
            // Leaving advanced mode must not strand the user on a page that is no longer listed.
            if !showAdvanced, case .group(let id) = page, navigation?.group(id)?.basic == false {
                page = .group(navigation?.essentials.first?.id ?? "identity")
            }
        }
        .confirmationDialog(apply ? "Save and activate reviewed changes?" : "Save reviewed changes?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(apply ? "Save & Apply" : "Save configuration") { Task { await save() } }
        } message: {
            Text(yamlChanged ?
                 "A backup of agent.yaml will be retained. Application images will be rebuilt and workers restarted. Active tasks may be interrupted. The management connection stays available where possible." :
                 apply ? "Affected application services will be recreated. Active work may be interrupted." :
                 "Settings are saved without restarting services. Apply them later from Server Health.")
        }
    }

    private static let sidebarWidth: CGFloat = 220

    private var yamlChanged: Bool { configuration?.agentYaml.map { yaml != $0 } ?? false }
    private var canSave: Bool {
        preview?["valid"] == .bool(true) && model.configurationDirty
    }

    // MARK: - Navigation

    /// Essentials first; advanced pages appear only on request; display toggles stay within reach.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarHeader("Essentials")
                    ForEach(navigation?.essentials ?? []) { sidebarButton($0.title, .group($0.id)) }
                    sidebarHeader("Files")
                    sidebarButton(String(localized: "Instructions"), .instructions)
                    sidebarButton("Agent.yaml", .agentYaml)
                    if showAdvanced {
                        sidebarHeader("Advanced")
                        ForEach(navigation?.advanced ?? []) { sidebarButton($0.title, .group($0.id)) }
                    }
                }
            }
            Divider()
            Toggle("Show advanced settings", isOn: $showAdvanced)
            Toggle("Show identifiers", isOn: $showIdentifiers)
                .help("Show each setting's environment variable name")
        }
        .toggleStyle(.switch).controlSize(.small).font(.callout)
    }

    private func sidebarHeader(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            .textCase(.uppercase).padding(.top, 10).padding(.bottom, 4).padding(.horizontal, 10)
    }

    private func sidebarButton(_ title: String, _ destination: SettingsPage) -> some View {
        let selected = search.isEmpty && page == destination
        return Button { page = destination; search = "" } label: {
            Text(title).font(.system(.body, weight: selected ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                .background(selected ? Theme.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pages

    /// A page introduces its group, lists its fields by section, then any nested groups.
    @ViewBuilder private func groupPage(_ id: String) -> some View {
        if let navigation, let group = navigation.group(id) {
            pageIntro(group.title, help: group.help)
            ForEach(navigation.sections(in: id)) { section in
                ManagementPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        if let title = section.title { Text(title).font(.title3.weight(.semibold)) }
                        fieldList(section.fields)
                        if !section.accounts.isEmpty { accountList(section, navigation: navigation) }
                    }
                }
            }
            ForEach(navigation.subgroups(of: id, includeAdvanced: showAdvanced)) { child in
                ManagementPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(child.title).font(.title3.weight(.semibold))
                            if let help = child.help { Text(help).font(.callout).foregroundStyle(Theme.secondary) }
                        }
                        fieldList(navigation.fields(in: child.id))
                    }
                }
            }
            if !showAdvanced && !navigation.subgroups(of: id, includeAdvanced: true).allSatisfy(\.basic) {
                Button("Show advanced settings for this page") { showAdvanced = true }
                    .buttonStyle(.link).font(.callout)
            }
        } else if configuration != nil {
            Text("Choose a section on the left.").foregroundStyle(Theme.secondary)
        }
    }

    private func pageIntro(_ title: String, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            if let help { Text(help).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func fieldList(_ fields: [SettingField]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(fields) { field in
                SettingRow(field: field, showIdentifier: showIdentifiers,
                           credential: credentials.first { $0.name == field.key },
                           credentialStatusLoaded: credentialStatusLoaded, value: binding(field))
                if field.id != fields.last?.id { Divider() }
            }
        }
    }

    /// Extra accounts stay collapsed so one provider's spare slots do not bury the rest of the page.
    private func accountList(_ section: SettingsSection, navigation: SettingsNavigation) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if let help = section.accounts.first?.help {
                    Text(help).font(.callout).foregroundStyle(Theme.secondary)
                }
                ForEach(section.accounts) { account in
                    DisclosureGroup {
                        fieldList(navigation.fields(in: account.id)).padding(.vertical, 8)
                    } label: {
                        HStack {
                            Text(account.title)
                            if navigation.configured(account) { StatusBadge(title: String(localized: "Configured"), tone: .green) }
                        }
                    }
                }
            }.padding(.top, 8)
        } label: {
            let count = section.accounts.filter(navigation.configured).count
            Text(count == 0 ? String(localized: "Additional accounts") :
                    String(localized: "Additional accounts (\(count) configured)"))
                .font(.callout.weight(.medium))
        }
    }

    /// Search spans every page, labelled with where each match lives.
    @ViewBuilder private var searchResults: some View {
        let results = navigation?.search(search) ?? []
        if results.isEmpty && configuration != nil {
            Text("No settings match “\(search)”.").foregroundStyle(Theme.secondary)
        }
        ForEach(results, id: \.group.id) { result in
            ManagementPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text(navigation?.path(result.group) ?? result.group.title).font(.title3.weight(.semibold))
                    fieldList(result.fields)
                }
            }
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageIntro(String(localized: "Instructions"),
                      help: String(localized: "The standing principles and guidance Assistant follows in every task."))
            TextEditor(text: $instructions).frame(minHeight: 360)
                .font(.system(.body, design: .monospaced)).padding(10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                .onChange(of: instructions) { invalidatePreview() }
                .accessibilityLabel("Assistant instructions")
        }
    }

    @ViewBuilder private var setupAcknowledgment: some View {
        if let configuration, !configuration.setupComplete {
            ManagementPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text(configuration.setupNotice).font(.callout).foregroundStyle(Theme.secondary)
                    Toggle("I understand the setup and isolation warnings", isOn: $acknowledge)
                        .onChange(of: acknowledge) { invalidatePreview() }
                }
            }
        }
    }

    /// Source YAML is separate from overrides, with backup restoration treated as a fresh draft.
    private var yamlEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent.yaml").font(.title2.weight(.semibold))
            Text("Core behavior, in its original source format. Environment overrides still take precedence. Saving changed source keeps the last three backups and rebuilds application images.")
                .foregroundStyle(Theme.secondary)
            if configuration?.agentYaml == nil {
                ErrorBanner(message: ClientError.serverOutdated(String(localized: "editing agent.yaml")).localizedDescription)
            } else {
                if let backups = configuration?.agentYamlBackups, !backups.isEmpty {
                    Menu("Load a previous version") {
                        ForEach(backups, id: \.self) { name in
                            Button(name) {
                                Task {
                                    do {
                                        let result = try await model.read("configuration/agent-yaml/backups/\(name)")
                                        guard let content = result["content"]?.string else { throw ClientError.malformedResponse }
                                        yaml = content
                                        invalidatePreview()
                                    } catch { self.error = error.presentableMessage ?? self.error }
                                }
                            }
                        }
                    }
                }
                TextEditor(text: $yaml)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 480).padding(10)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .onChange(of: yaml) { invalidatePreview() }
                    .accessibilityLabel("Agent.yaml source")
            }
        }
    }

    // MARK: - Draft

    /// Only changed fields enter the immutable reviewed payload.
    private func binding(_ field: SettingField) -> Binding<String> {
        Binding(get: { values[field.key] ?? (field.secret ? "" : field.value) }, set: {
            guard $0 != (values[field.key] ?? (field.secret ? "" : field.value)) else { return }
            if $0 == field.value || (field.secret && $0.isEmpty) { values.removeValue(forKey: field.key) }
            else { values[field.key] = $0 }
            invalidatePreview()
        })
    }

    /// Editing any part of the draft invalidates previous server confirmation.
    private func invalidatePreview() {
        preview = nil; reviewedPayload = nil
        model.configurationDirty = !values.isEmpty || instructions != configuration?.instructions || yamlChanged || acknowledge
    }

    /// A successful reload is the only point that clears a saved draft.
    private func load() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await model.read("configuration")
            configuration = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(result))
            instructions = configuration?.instructions ?? ""
            yaml = configuration?.agentYaml ?? ""
            if case .group(let id) = page, navigation?.group(id) == nil {
                page = navigation?.essentials.first.map { .group($0.id) } ?? .instructions
            }
            values = [:]; acknowledge = false; preview = nil; reviewedPayload = nil
            model.configurationDirty = false
            error = nil
        } catch { self.error = error.presentableMessage ?? self.error }
        do {
            let result = try await model.read("credentials")
            credentials = try Wire.decoder().decode(CredentialInventory.self, from: JSONEncoder().encode(result)).credentials
            credentialStatusLoaded = true
            credentialError = nil
        } catch {
            credentialStatusLoaded = false
            credentialError = error.presentableMessage.map { String(localized: "Saved key status could not be loaded: \($0)") }
        }
    }

    /// Preview includes source text so stale backups or external changes cannot be overwritten.
    private func review() async {
        guard let configuration else { return }
        busy = true
        defer { busy = false }
        var payload: [String: JSONValue] = [
            "revision": .string(configuration.revision), "values": .object(values.mapValues(JSONValue.string)),
            "acknowledge": .bool(acknowledge)
        ]
        if instructions != configuration.instructions { payload["instructions"] = .string(instructions) }
        if yamlChanged { payload["agent_yaml"] = .string(yaml) }
        do {
            preview = try await model.query("configuration/preview", payload: .object(payload))
            reviewedPayload = payload; error = nil
        } catch { self.error = error.presentableMessage ?? self.error }
    }

    /// Saving and activation are explicit; uncertain results retain their operation reference.
    private func save() async {
        guard var payload = reviewedPayload, let previewID = preview?["preview_id"]?.string else { return }
        busy = true
        model.configurationApplying = true
        defer { busy = false; model.configurationApplying = false }
        payload["operation"] = .string("configuration.save")
        payload["preview_id"] = .string(previewID)
        payload["confirmed"] = .bool(true)
        if configuration?.agentYaml != nil { payload["apply"] = .bool(apply) }
        do {
            _ = try await model.perform(.object(payload))
            notice = apply ? String(localized: "Configuration saved and application services activated.") :
                String(localized: "Saved. Activate these changes from Server Health when you are ready.")
            await load()
        } catch {
            self.error = error.presentableMessage ?? self.error
            notice = String(localized: "Saving or activation may have partial effects. Inspect Server Health and operation history before retrying.")
            preview = nil; reviewedPayload = nil
        }
    }

    /// Review emphasizes actual changes and validation problems instead of a JSON dump.
    private func changeReview(_ preview: JSONValue) -> some View {
        ManagementPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review your changes").font(.headline)
                ForEach(Array((preview["problems"]?.array ?? []).enumerated()), id: \.offset) { _, problem in
                    if let text = problem.string { ErrorBanner(message: text) }
                }
                ForEach(Array((preview["changes"]?.array ?? []).enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(configuration?.settings.first { $0.key == change["key"]?.string }?.label ??
                             change["key"]?.string ?? "").font(.callout.weight(.semibold))
                        Text("\(change["before"]?.string ?? "") → \(change["after"]?.string ?? "")")
                            .font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        if let diff = change["diff"]?.string {
                            DisclosureGroup("Source changes") { CodeBlock(language: "diff", source: diff) }
                        }
                    }
                }
            }
        }
    }
}

/// Fallible formatting remains available only for technical details and tool output.
struct PreviewText: View {
    let value: JSONValue

    var body: some View {
        if case .object(let fields) = value, !fields.isEmpty {
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    GridRow {
                        Text(verbatim: key.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                        if let field = fields[key] { JSONFieldValue(value: field) }
                    }
                    Divider()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            JSONFieldValue(value: value)
        }
    }
}

/// String values remain readable; compound JSON keeps its indentation rather than escaping it.
private struct JSONFieldValue: View {
    let value: JSONValue

    var body: some View {
        if case .string(let text) = value {
            TerminalOutput(text: text)
        } else if let text = try? value.formatted() {
            TerminalOutput(text: text)
        } else {
            ErrorBanner(message: String(localized: "This response could not be formatted."))
        }
    }
}
