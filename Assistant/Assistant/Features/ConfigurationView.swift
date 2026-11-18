import SwiftUI

/// Task-oriented server settings use structured pages, immutable review and explicit activation.
struct ConfigurationView: View {
    let model: ClientModel
    @State private var configuration: FullConfiguration?
    @State private var credentials: [SavedCredential] = []
    @State private var credentialStatusLoaded = false
    @State private var credentialError: String?
    @State private var values: [String: String] = [:]
    @State private var instructions = ""
    @State private var instructionsOriginal = ""
    @State private var instructionsLoaded = false
    @State private var loadedGroups: Set<String> = []
    @State private var loadedFields: [String: SettingField] = [:]
    @State private var loadingGroups: Set<String> = []
    @State private var instructionsLoading = false
    @State private var loadGeneration = UUID()
    @State private var category = SettingsCategory.assistant
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
    @State private var searchFocus: String?
    @State private var expandedAccounts: Set<String> = []
    @State private var offerFirstChat = false
    @State private var showingFeedback = false
    @AppStorage("settings.showIdentifiers") private var showIdentifiers = false

    private var navigation: SettingsNavigation? { configuration.map(SettingsNavigation.init) }

    /// All changes stay in memory until a server-reviewed draft is explicitly confirmed.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HSplitView {
                categoryNavigation
                detailPane
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actionFooter
        }
        .task { await load() }
        .task(id: page) { await loadPage() }
        .onChange(of: search) { if !search.isEmpty { searchFocus = nil } }
        .confirmationDialog(apply ? "Save and activate reviewed changes?" : "Save reviewed changes?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(apply ? "Save & Apply" : "Save configuration") { Task { await save() } }
        } message: {
            Text(apply ? "Affected application services will be started or recreated. Active work may be interrupted. Enabled connections may begin processing messages." :
                 "This saves your changes without restarting Assistant. If they need activation, you can apply them later from Connection & Support.")
        }
    }

    private var canSave: Bool {
        preview?["valid"] == .bool(true) && model.configurationDirty
    }

    // MARK: - Navigation

    /// Settings sections stay in place when the detail page changes.
    private var categoryNavigation: some View {
        SettingsNavigationPane(title: String(localized: "Settings sections")) {
            ForEach(SettingsCategory.allCases) { scope in
                let groups = navigation?.pages(in: scope) ?? []
                if scope == .app || scope == .assistant || !groups.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(scope.title, systemImage: scope.symbol)
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.outline))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("settings-category-\(scope.rawValue)")
                        if scope == .app {
                            sectionButton(String(localized: "On this Mac"), page: .app, in: scope, identifier: "app")
                        }
                        ForEach(groups) { group in
                            sectionButton(group.title, page: .group(group.id), in: scope, identifier: group.id)
                        }
                        if scope == .assistant {
                            sectionButton(String(localized: "Instructions"), page: .instructions, in: scope, identifier: "instructions")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 185, idealWidth: Theme.settingsCategoryWidth, maxWidth: 240)
        .disabled(busy)
    }

    private func sectionButton(_ title: String, page destination: SettingsPage, in scope: SettingsCategory,
                               identifier: String) -> some View {
        let selected = page == destination && category == scope
        return Button { selectPage(destination, in: scope) } label: {
            Text(title).lineLimit(2)
        }
        .buttonStyle(DestinationButtonStyle(selected: selected))
        .accessibilityIdentifier("settings-section-\(scope.rawValue)-\(identifier)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(search.isEmpty ? category.title : String(localized: "Search results"))
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("Find a setting", text: $search).textFieldStyle(.plain)
                    Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .opacity(search.isEmpty ? 0 : 1).disabled(search.isEmpty)
                        .accessibilityHidden(search.isEmpty)
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.outline))
                .frame(maxWidth: 230)
                Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly).help("Reload settings")
                    .buttonStyle(.borderless)
                    .disabled(model.configurationDirty || busy)
                if category == .advanced && search.isEmpty {
                    Menu {
                        Toggle("Show identifiers", isOn: $showIdentifiers)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Display options")
                }
            }.padding(.horizontal, 20).frame(height: 44)
            ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if configuration?.setupComplete == false {
                        Label("Start with a model and API key, set your assistant basics, then review safety and choose Save & Start. Connections are optional.",
                              systemImage: "sparkles")
                            .font(.callout).foregroundStyle(Theme.secondary)
                    }
                    if offerFirstChat {
                        Button("Start your first chat", systemImage: "bubble.left.and.bubble.right") { model.newChatRequest = UUID() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    if !search.isEmpty { searchResults }
                    else {
                        switch page {
                        case .group(let id): groupPage(id)
                        case .instructions: instructionsEditor
                        case .app: AppPreferencesView(model: model)
                        }
                    }
                    if configuration?.setupComplete == false { setupAcknowledgment }
                    if let preview { changeReview(preview) }
                }
                .frame(maxWidth: Theme.contentWidth, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 20).disabled(busy)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(page)
            .accessibilityIdentifier("settings-detail")
            .task(id: searchFocus) {
                guard let searchFocus else { return }
                reader.scrollTo(searchFocus, anchor: .center)
            }
            }
        }.frame(minWidth: Theme.settingsDetailMinimum, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Review state, background progress and feedback have permanent space below all panes.
    private var actionFooter: some View {
        HStack(spacing: 12) {
            StableProgress(active: busy || !loadingGroups.isEmpty || instructionsLoading)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.configurationDirty ? String(localized: "Unsaved changes") :
                        model.activationState == .pending ? String(localized: "Saved · Needs applying") :
                        model.activationState == .unknown ? String(localized: "Activation needs checking") :
                        String(localized: "All changes saved"))
                    .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                Button { showingFeedback.toggle() } label: {
                    Text(error ?? credentialError ?? notice ?? " ").font(.caption)
                        .foregroundStyle(error != nil || credentialError != nil ? .red : Theme.secondary)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-feedback")
                .accessibilityLabel(Text(error ?? credentialError ?? notice ?? String(localized: "Settings feedback")))
                .disabled(error == nil && credentialError == nil && notice == nil)
                .accessibilityHidden(error == nil && credentialError == nil && notice == nil)
                .frame(height: 16)
                .popover(isPresented: $showingFeedback) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error { ErrorBanner(message: error) }
                        if let credentialError {
                            ErrorBanner(message: credentialError)
                            Button("Retry credential status") { Task { await loadCredentials() } }
                        }
                        if let notice { Text(notice).textSelection(.enabled) }
                        Button("Done") { showingFeedback = false }
                    }.padding().frame(width: 420)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if canSave {
                if configuration?.setupComplete == false {
                    Button("Save & Start") { apply = true; confirming = true }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy)
                } else {
                    Button("Save & Apply") { apply = true; confirming = true }.disabled(busy)
                    Button("Save changes") { apply = false; confirming = true }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy)
                }
            } else {
                Button("Review changes") { Task { await review() } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!model.configurationDirty || busy)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func selectPage(_ destination: SettingsPage, in scope: SettingsCategory) {
        category = scope
        page = destination
        search = ""
        searchFocus = nil
    }

    // MARK: - Pages

    /// A page introduces its group, lists its fields by section, then any nested groups.
    @ViewBuilder private func groupPage(_ id: String) -> some View {
        if let navigation, let group = navigation.group(id) {
            pageIntro(group.title, help: group.help)
            if category == .connections {
                Label("These are connection settings, not a verified connection. Saving without applying does not start message processing.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 20) {
            ForEach(navigation.sections(in: id).filter {
                !visible($0.fields, root: group).isEmpty ||
                $0.accounts.contains { !visible(navigation.fields(in: $0.id), root: group).isEmpty }
            }) { section in
                ManagementPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        if let title = section.title { sectionHeading(title) }
                        fieldList(visible(section.fields, root: group))
                        let accounts = section.accounts.filter { !visible(navigation.fields(in: $0.id), root: group).isEmpty }
                        if !accounts.isEmpty { accountList(accounts, root: group, navigation: navigation) }
                    }
                }
            }
            ForEach(navigation.subgroups(of: id, includeAdvanced: true).filter {
                !visible(navigation.fields(in: $0.id), root: group).isEmpty
            }) { child in
                ManagementPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeading(child.title, help: child.help)
                        fieldList(visible(navigation.fields(in: child.id), root: group))
                    }
                }
            }
            }.disabled(!loadedGroups.contains(id))
        } else if configuration != nil {
            Text("Select a section in the sidebar.").foregroundStyle(Theme.secondary)
        }
    }

    private func pageIntro(_ title: String, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.pageTitle).accessibilityAddTraits(.isHeader)
            if let help { Text(help).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func sectionHeading(_ title: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.sectionTitle).accessibilityAddTraits(.isHeader)
            if let help { Text(help).font(.callout).foregroundStyle(Theme.secondary) }
            Rectangle().fill(Theme.outline).frame(height: 1).accessibilityHidden(true)
        }
    }

    private func visible(_ fields: [SettingField], root: SettingGroup) -> [SettingField] {
        guard let navigation else { return [] }
        return fields.filter { navigation.category(for: root, field: $0) == category }
    }

    private func fieldList(_ fields: [SettingField]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(fields) { field in
                SettingRow(field: field, showIdentifier: showIdentifiers,
                           credential: credentials.first { $0.name == field.key },
                           credentialStatusLoaded: credentialStatusLoaded, value: binding(field))
                    .id(field.key)
                if field.id != fields.last?.id { Divider() }
            }
        }
    }

    /// Extra accounts stay collapsed so one provider's spare slots do not bury the rest of the page.
    @ViewBuilder private func accountList(_ accounts: [SettingGroup], root: SettingGroup, navigation: SettingsNavigation) -> some View {
        if let first = accounts.first {
        DisclosureGroup(isExpanded: accountExpansion(first.id + ":list")) {
            VStack(alignment: .leading, spacing: 10) {
                if let help = accounts.first?.help {
                    Text(help).font(.callout).foregroundStyle(Theme.secondary)
                }
                ForEach(accounts) { account in
                    DisclosureGroup(isExpanded: accountExpansion(account.id)) {
                        fieldList(visible(navigation.fields(in: account.id), root: root)).padding(.vertical, 8)
                    } label: {
                        HStack {
                            Text(account.title)
                            if navigation.configured(account) { StatusBadge(title: String(localized: "Configured"), tone: .green) }
                        }
                    }
                }
            }.padding(.top, 8)
        } label: {
            let count = accounts.filter(navigation.configured).count
            Text(count == 0 ? String(localized: "Additional accounts") :
                    String(localized: "Additional accounts (\(count) configured)"))
                .font(.callout.weight(.medium))
        }
        }
    }

    private func accountExpansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedAccounts.contains(id) }, set: {
            if $0 { expandedAccounts.insert(id) } else { expandedAccounts.remove(id) }
        })
    }

    /// Search spans every page, labelled with where each match lives.
    @ViewBuilder private var searchResults: some View {
        let results = navigation?.search(search) ?? []
        if results.isEmpty && configuration != nil {
            Text("No settings match “\(search)”.").foregroundStyle(Theme.secondary)
        }
        if let navigation {
            ForEach(results, id: \.group.id) { result in
                let root = result.group.parent.flatMap(navigation.group) ?? result.group
                ManagementPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(result.fields) { field in
                            let destination = navigation.category(for: root, field: field)
                            Button {
                                selectPage(.group(root.id), in: destination)
                                if let section = navigation.sections(in: root.id).first(where: {
                                    $0.accounts.contains { $0.id == result.group.id }
                                }), let first = section.accounts.first(where: {
                                    !visible(navigation.fields(in: $0.id), root: root).isEmpty
                                }) {
                                    expandedAccounts.formUnion([first.id + ":list", result.group.id])
                                }
                                searchFocus = field.key
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(field.label)
                                        Text("\(destination.title) › \(navigation.path(result.group))")
                                            .font(.caption).foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                            }.buttonStyle(.plain).padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageIntro(String(localized: "Instructions"),
                      help: String(localized: "Tell Assistant what to keep in mind across all your conversations."))
            Text("For example, say how you prefer summaries, what to ask before doing, or what to leave out. Keep one-off requests in Chats.")
                .font(.callout).foregroundStyle(Theme.secondary)
            TextEditor(text: $instructions).frame(minHeight: 260)
                .disabled(!instructionsLoaded)
                .font(.body).padding(10)
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

    // MARK: - Draft

    /// Only changed fields enter the immutable reviewed payload.
    private func binding(_ field: SettingField) -> Binding<String> {
        let effective = loadedFields[field.key] ?? field
        return Binding(get: { values[field.key] ?? (effective.secret ? "" : effective.value) }, set: {
            guard $0 != (values[field.key] ?? (effective.secret ? "" : effective.value)) else { return }
            if $0 == effective.value || (effective.secret && $0.isEmpty) { values.removeValue(forKey: field.key) }
            else { values[field.key] = $0 }
            invalidatePreview()
        })
    }

    /// Editing any part of the draft invalidates previous server confirmation.
    private func invalidatePreview() {
        preview = nil; reviewedPayload = nil
        model.configurationDirty = !values.isEmpty || (instructionsLoaded && instructions != instructionsOriginal) || acknowledge
        if model.configurationDirty { notice = nil }
    }

    /// A successful reload is the only point that clears a saved draft.
    private func load() async {
        loadGeneration = UUID()
        loadingGroups = []; instructionsLoading = false
        busy = true
        defer { busy = false }
        do {
            guard model.health?.capabilities.contains("configuration.structured") == true else {
                throw ClientError.serverOutdated(String(localized: "structured settings"))
            }
            let result = try await model.read("configuration/catalog")
            configuration = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(result))
            model.setupRequired = configuration?.setupComplete == false
            if model.setupRequired, values.isEmpty, let first = navigation?.pages(in: .models).first {
                category = .models; page = .group(first.id)
            }
            instructions = ""; instructionsOriginal = ""; instructionsLoaded = false
            loadedGroups = []; loadedFields = [:]
            if case .group(let id) = page, navigation?.pages(in: category).contains(where: { $0.id == id }) != true {
                if let first = navigation?.pages(in: category).first {
                    selectPage(.group(first.id), in: category)
                } else {
                    selectPage(.instructions, in: .assistant)
                }
            }
            values = [:]; acknowledge = false; preview = nil; reviewedPayload = nil
            model.configurationDirty = false
            error = nil
            await loadPage()
        } catch { self.error = error.presentableMessage ?? self.error }
        await loadCredentials()
    }

    private func loadCredentials() async {
        do {
            let result = try await model.read("credentials")
            credentials = try Wire.decoder().decode(CredentialInventory.self, from: JSONEncoder().encode(result)).credentials
            credentialStatusLoaded = true
            credentialError = nil
        } catch {
            credentialStatusLoaded = false
            credentialError = error.presentableMessage.map { String(localized: "Can’t check saved credentials right now. \($0)") }
        }
    }

    /// Lazy page reads retain the catalog revision, so external edits never silently merge with a draft.
    private func loadPage() async {
        guard let configuration else { return }
        let current = loadGeneration
        do {
            switch page {
            case .app: return
            case .instructions:
                guard !instructionsLoaded, !instructionsLoading else { return }
                instructionsLoading = true
                defer { if loadGeneration == current { instructionsLoading = false } }
                let result = try await model.read("configuration/instructions")
                guard loadGeneration == current, !Task.isCancelled else { return }
                guard result["revision"]?.string == configuration.revision,
                      let text = result["instructions"]?.string else { throw ClientError.operationFailed(
                        String(localized: "Settings changed on the server. Save or discard your draft, then reload.")) }
                instructions = text; instructionsOriginal = text; instructionsLoaded = true
            case .group(let id):
                guard !loadedGroups.contains(id), loadingGroups.insert(id).inserted else { return }
                defer { if loadGeneration == current { loadingGroups.remove(id) } }
                var query = URLComponents()
                query.queryItems = [URLQueryItem(name: "group", value: id)]
                let result = try await model.read("configuration/settings?\(query.percentEncodedQuery ?? "")")
                let loaded = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(result))
                guard loadGeneration == current, !Task.isCancelled else { return }
                guard loaded.revision == configuration.revision else { throw ClientError.operationFailed(
                    String(localized: "Settings changed on the server. Save or discard your draft, then reload.")) }
                for field in loaded.settings { loadedFields[field.key] = field }
                self.configuration?.settings = self.configuration?.settings.map { loadedFields[$0.key] ?? $0 } ?? []
                loadedGroups.insert(id)
            }
            error = nil
        } catch { self.error = error.presentableMessage ?? self.error }
    }

    /// Review sends only edited product settings and explicitly opened instructions.
    private func review() async {
        guard let configuration else { return }
        busy = true
        defer { busy = false }
        var payload: [String: JSONValue] = [
            "revision": .string(configuration.revision), "values": .object(values.mapValues(JSONValue.string)),
            "acknowledge": .bool(acknowledge)
        ]
        if instructionsLoaded && instructions != instructionsOriginal { payload["instructions"] = .string(instructions) }
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
        payload["apply"] = .bool(apply)
        let starting = configuration?.setupComplete == false && apply
        do {
            _ = try await model.perform(.object(payload))
            model.recordActivation(apply ? .active : .pending)
            notice = apply ? String(localized: "Configuration saved and application services activated.") :
                String(localized: "Saved. Apply changes from Connection & Support when you are ready.")
            await load()
            offerFirstChat = starting
        } catch {
            model.recordActivation(.unknown)
            self.error = error.presentableMessage ?? self.error
            notice = String(localized: "Some changes may have been saved or applied. Check operation history in Connection & Support before retrying.")
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
