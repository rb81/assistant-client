import SwiftUI

/// Task-oriented server settings use structured pages, immutable review and explicit activation.
struct ConfigurationView: View {
    let model: ClientModel
    @Binding var location: SettingsLocation
    let navigate: (SettingsPage, SettingsCategory) -> Void
    @State private var configuration: FullConfiguration?
    @State private var catalogSnapshot: JSONValue?
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
    @State private var scrollMemory = ScrollMemory()
    @State private var acknowledge = false
    @State private var preview: JSONValue?
    @State private var reviewedPayload: [String: JSONValue]?
    @State private var confirming = false
    @State private var confirmingDiscard = false
    @State private var apply = false
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var refreshAfterBusy = false
    @State private var searchFocus: String?
    @State private var expandedAccounts: Set<String> = []
    @State private var offerFirstChat = false
    @State private var showingFeedback = false
    @State private var showingInstructionPreview = false
    @State private var showingReview = false
    @State private var modelAccess: [String: String] = [:]
    @State private var modelAccessLoaded = false
    @State private var providerModelCatalogs: [String: ProviderModelCatalog] = [:]
    @State private var providerModelCatalogErrors: [String: String] = [:]
    @State private var providerModelCatalogLoading: Set<String> = []
    @State private var settingChoiceLists: [String: SettingChoices] = [:]
    @State private var settingChoicesLoading: Set<String> = []
    @State private var settingChoiceErrors: [String: String] = [:]
    @State private var modelOverview: ModelSettingsOverview?
    @State private var modelOverviewLoading = false
    @State private var modelOverviewError: String?
    @AppStorage("settings.showIdentifiers") private var showIdentifiers = false

    private var navigation: SettingsNavigation? { (configuration ?? model.settingsMenu).map(SettingsNavigation.init) }
    private var category: SettingsCategory { location.category }
    private var page: SettingsPage { location.page }
    private var search: String { location.search }

    /// All changes stay in memory until a server-reviewed draft is explicitly confirmed.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HSplitView {
                categoryNavigation
                detailPane
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            actionFooter
        }
        .task { await load() }
        .task(id: model.configurationVisit) { await checkForExternalChanges() }
        .onChange(of: busy) { _, isBusy in
            if !isBusy && refreshAfterBusy {
                refreshAfterBusy = false
                Task { await checkForExternalChanges() }
            }
        }
        .task(id: page) { await loadPage() }
        .onChange(of: search) { if !search.isEmpty { searchFocus = nil } }
        .sheet(isPresented: $showingReview) { draftReview }
        .alert("Discard unsaved configuration changes?", isPresented: $confirmingDiscard) {
            Button("Discard draft", role: .destructive) { Task { await discardDraft() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards only edits on this Mac. Settings already saved on the server are kept.")
        }
    }

    private var canSave: Bool {
        preview?["valid"] == .bool(true) && model.configurationDirty
    }

    private var modelRouteProblem: String? {
        let routes: [(String, String?)] = [
            ("AGENT_LLM_MODEL", "AGENT_MODEL_ROUTES_TASK_PROVIDER"),
            ("AGENT_LLM_FALLBACK_MODEL", "AGENT_MODEL_ROUTES_TASK_PROVIDER"),
            ("AGENT_NAMING_MODEL", "AGENT_MODEL_ROUTES_NAMING_PROVIDER"),
            ("AGENT_ROUTING_MODEL", "AGENT_MODEL_ROUTES_ROUTING_PROVIDER"),
            ("AGENT_LIMITS_SUMMARIZATION_MODEL", "AGENT_MODEL_ROUTES_SUMMARIZATION_PROVIDER"),
            ("AGENT_MEMORY_STEWARD_MODEL", "AGENT_MODEL_ROUTES_MEMORY_PROVIDER"),
            ("AGENT_DEEP_RESEARCH_MODEL", "AGENT_MODEL_ROUTES_RESEARCH_PROVIDER"),
            ("AGENT_DEEP_RESEARCH_SEARCH_MODEL", "AGENT_MODEL_ROUTES_RESEARCH_SEARCH_PROVIDER"),
            ("AGENT_SEARCH_MODEL", "AGENT_MODEL_ROUTES_WEB_SEARCH_PROVIDER"),
            ("AGENT_SECURITY_DEVELOPMENT_MODEL", "AGENT_MODEL_ROUTES_DEVELOPMENT_PROVIDER"),
        ]
        let defaultProviderChanged = values["AGENT_LLM_PROVIDER"] != nil || values["AGENT_LLM_BASE_URL"] != nil
        for (modelKey, routeKey) in routes {
            let routeChanged = routeKey.map { values[$0] != nil } ?? false
            let inheritsChangedDefault = routeKey.map {
                let selected = effectiveValue($0).lowercased()
                return defaultProviderChanged && (selected.isEmpty || selected == "inherit" || selected == "auto")
            } ?? defaultProviderChanged
            guard usesProviderModelCatalog(modelKey),
                  values[modelKey] != nil || routeChanged || inheritsChangedDefault else { continue }
            let provider = selectedModelProvider(for: modelKey)
            let selected = effectiveValue(modelKey).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if selected.isEmpty {
                if modelKey == "AGENT_LLM_FALLBACK_MODEL" { continue }
                return String(localized: "Choose a model for each changed provider route before reviewing these settings.")
            }
            let available: Set<String>
            if provider == "openrouter", let purpose = ModelPurpose.forSetting(modelKey) {
                available = Set(model.modelCatalog.models(zdr: zdrOnly(for: modelKey), purpose: purpose).map(\.id))
            } else if let catalog = providerModelCatalogs[provider] {
                available = Set(catalog.models.map(\.id))
            } else {
                return String(localized: "Discover models for the selected provider before reviewing these settings.")
            }
            if selected.contains(where: { !available.contains($0) }) {
                return String(localized: "A selected model is not available in the current provider catalog. Choose a discovered model.")
            }
        }
        return nil
    }

    // MARK: - Navigation

    /// Settings sections stay in place when the detail page changes.
    private var categoryNavigation: some View {
        SettingsNavigationPane(title: String(localized: "Settings sections")) {
            if let navigation {
                ForEach(SettingsCategory.allCases) { scope in
                    let groups = navigation.pages(in: scope)
                    if scope == .app || scope == .assistant || scope == .models || !groups.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(scope.title, systemImage: scope.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("settings-category-\(scope.rawValue)")
                            if scope == .app {
                                sectionButton(String(localized: "On this Mac"), page: .app, in: scope, identifier: "app")
                            }
                            if scope == .models {
                                sectionButton(String(localized: "Model settings overview"), page: .modelOverview,
                                              in: scope, identifier: "overview")
                            }
                            ForEach(groups) { group in
                                sectionButton(navigation.title(group, in: scope),
                                              page: .group(group.id), in: scope, identifier: group.id)
                            }
                            if scope == .assistant {
                                sectionButton(String(localized: "Instructions"), page: .instructions, in: scope, identifier: "instructions")
                                sectionButton(String(localized: "Skills"), page: .skills, in: scope, identifier: "skills")
                            }
                        }
                    }
                }
            } else if error != nil {
                Label("Settings unavailable", systemImage: "exclamationmark.triangle").padding(12)
            } else {
                ProgressView("Loading settings…")
                    .controlSize(.small).padding(12)
                    .accessibilityIdentifier("settings-menu-loading")
            }
        }
        .frame(minWidth: 220, idealWidth: Theme.settingsCategoryWidth, maxWidth: 380)
        .background(SplitViewAutosave(name: "Assistant.Settings", defaultLeadingWidth: Theme.settingsCategoryWidth))
        .disabled(busy || configuration == nil)
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
                Text(page == .modelOverview ? String(localized: "Model settings") :
                     search.isEmpty ? category.title : String(localized: "Search results"))
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("Find a setting", text: $location.search).textFieldStyle(.plain)
                        .accessibilityIdentifier("settings-search")
                    Button("Clear search", systemImage: "xmark.circle.fill") { location.search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .opacity(search.isEmpty ? 0 : 1).disabled(search.isEmpty)
                        .accessibilityHidden(search.isEmpty)
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.outline).allowsHitTesting(false))
                .frame(maxWidth: 230)
                Button("Reload", systemImage: "arrow.clockwise") {
                    model.invalidateResources()
                    Task { await load() }
                }
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
            if configuration == nil {
                if let error {
                    ContentUnavailableView("Settings unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView("Loading settings…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    if page == .instructions || instructionsLoaded {
                        instructionsEditor
                            .padding(.horizontal, 20).padding(.bottom, 20)
                            .accessibilityIdentifier("settings-detail")
                            .opacity(page == .instructions && search.isEmpty ? 1 : 0)
                            .allowsHitTesting(page == .instructions && search.isEmpty)
                            .accessibilityHidden(page != .instructions || !search.isEmpty)
                            .disabled(page != .instructions || !search.isEmpty)
                    }
                    if page != .instructions || !search.isEmpty { scrollingDetail }
                }
            }
        }.frame(minWidth: Theme.settingsDetailMinimum, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Non-editor pages share scroll restoration and deep links to individual controls.
    private var scrollingDetail: some View {
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
                    if page == .modelOverview {
                        ModelSettingsOverviewView(overview: modelOverview, loading: modelOverviewLoading,
                                                  error: modelOverviewError, search: search,
                                                  modelRow: settingRow, openSettings: openRelatedSettings)
                    } else if !search.isEmpty { searchResults }
                    else {
                        switch page {
                        case .group(let id): groupPage(id)
                        case .instructions: EmptyView()
                        case .skills: SkillsSettingsView(model: model)
                        case .app: AppPreferencesView(model: model)
                        case .modelOverview: EmptyView()
                        }
                    }
                    if configuration?.setupComplete == false { setupAcknowledgment }
                }
                .frame(maxWidth: Theme.contentWidth, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 20).disabled(busy)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .rememberingScroll(location, in: scrollMemory, ready: pageScrollReady)
            .id(location)
            .accessibilityIdentifier("settings-detail")
            .task(id: searchFocus) {
                guard let searchFocus else { return }
                reader.scrollTo(searchFocus, anchor: .center)
            }
        }
    }

    private var footerLoading: Bool {
        busy || !loadingGroups.isEmpty || instructionsLoading || modelOverviewLoading || (configuration == nil && error == nil)
    }

    private var pageScrollReady: Bool {
        switch page {
        case .group(let id): return loadedGroups.contains(id)
        case .modelOverview: return modelOverview != nil
        default: return true
        }
    }

    private var footerTitle: String {
        if configuration == nil { return error == nil ? String(localized: "Loading settings…") : String(localized: "Settings unavailable") }
        if model.configurationDirty { return String(localized: "Unsaved changes") }
        if model.activationState == .pending { return String(localized: "Saved · Needs applying") }
        if model.activationState == .unknown { return String(localized: "Activation needs checking") }
        return String(localized: "All changes saved")
    }

    /// Single-line status is centered; a second line exists only when there is actual feedback.
    private var actionFooter: some View {
        PaneFooter {
            HStack(spacing: 12) {
                Group {
                    if footerLoading { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: error != nil || credentialError != nil ? "exclamationmark.circle" :
                                model.configurationDirty ? "pencil.circle" :
                                model.activationState != .active ? "clock" : "checkmark.circle")
                            .foregroundStyle(error != nil || credentialError != nil ? Color.red : Theme.accent)
                    }
                }.frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(footerTitle)
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    if let feedback = error ?? credentialError ?? modelRouteProblem ?? notice {
                        Button { showingFeedback.toggle() } label: {
                            Text(feedback).font(.caption)
                                .foregroundStyle(error != nil || credentialError != nil || modelRouteProblem != nil
                                                 ? .red : Theme.secondary)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-feedback")
                        .accessibilityLabel(Text(feedback))
                        .frame(height: 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .popover(isPresented: $showingFeedback) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error { ErrorBanner(message: error) }
                        if let credentialError {
                            ErrorBanner(message: credentialError)
                            Button("Retry credential status") { Task { await loadCredentials() } }
                        }
                        if let modelRouteProblem { ErrorBanner(message: modelRouteProblem) }
                        if let notice { Text(notice).textSelection(.enabled) }
                        Button("Done") { showingFeedback = false }
                    }.padding().frame(width: 420)
                }
                if model.configurationDirty {
                    Button("Discard draft…") { confirmingDiscard = true }.disabled(busy)
                }
                if !canSave {
                    if !model.configurationDirty && model.activationState != .active {
                        Button("Review & Apply") { model.activationReviewPresented = true }.disabled(busy)
                    }
                }
                Button("Review changes") {
                    if preview != nil { showingReview = true }
                    else { Task { await review() } }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(!model.configurationDirty || busy || modelRouteProblem != nil)
            }
        }
    }

    private func selectPage(_ destination: SettingsPage, in scope: SettingsCategory) {
        navigate(destination, scope)
        searchFocus = nil
    }

    /// Follow the server's owning page and reveal the first associated control.
    private func openRelatedSettings(_ link: ModelSettingsLink) {
        guard let scope = SettingsCategory(rawValue: link.destination),
              navigation?.group(link.group) != nil else {
            modelOverviewError = String(localized: "This model setting’s editor is unavailable. Reload settings.")
            return
        }
        selectPage(.group(link.group), in: scope)
        searchFocus = link.fieldKey
    }

    // MARK: - Pages

    /// A page introduces its group, lists its fields by section, then any nested groups.
    @ViewBuilder private func groupPage(_ id: String) -> some View {
        if let navigation, let group = navigation.group(id) {
            pageIntro(navigation.title(group, in: category), help: group.help)
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
        return fields.filter {
            navigation.category(for: root, field: $0) == category &&
                !(category != .advanced && $0.key.hasPrefix("AGENT_TTS_") &&
                  $0.key != "AGENT_TTS_ENABLED" && effectiveValue("AGENT_TTS_ENABLED") != "true")
        }
    }

    private func fieldList(_ fields: [SettingField]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(fields) { field in
                settingRow(field)
                    .id(field.key)
                if field.id != fields.last?.id { Divider() }
            }
        }
    }

    /// Quick model edits and full settings pages share bindings, eligibility, and draft review.
    private func settingRow(_ field: SettingField) -> some View {
        let provider = selectedModelProvider(for: field)
        return SettingRow(field: field, showIdentifier: showIdentifiers,
                   credential: credentials.first { $0.name == field.key },
                   credentialStatusLoaded: credentialStatusLoaded,
                   modelCatalog: model.modelCatalog, modelPurpose: modelPurpose(field),
                   providerModels: providerModels(field),
                   providerModelsLoading: providerModelCatalogLoading.contains(provider),
                   refreshProviderModels: { await loadProviderModels(for: field, force: true) },
                   eligibilityWarning: settingChoiceErrors[field.key] ?? modelEligibilityWarning(field),
                   zdrOnly: zdrOnly(field), choices: providerChoices(field) ?? voiceChoices(field),
                   selectionChoices: settingChoiceLists[field.key],
                   choicesLoading: settingChoicesLoading.contains(field.key),
                   refreshChoices: field.metadata?["choices_source"]?.string == nil ||
                       field.metadata?["selection"]?.string == "single" ? nil : {
                       await loadSettingChoices(field, force: true)
                   },
                   value: binding(field))
            .disabled(ModelPurpose.forSetting(field.key) != nil && !modelAccessLoaded)
            .task(id: "\(provider):\(modelAccessLoaded)") {
                if field.metadata?["choices_source"]?.string != nil,
                   field.metadata?["selection"]?.string != "single" {
                    await loadSettingChoices(field)
                }
                guard modelPurpose(field) == nil, configuredProviderIDs.contains(provider),
                      !providerIsDisabled(provider) else { return }
                await loadProviderModels(for: field)
            }
    }

    private func loadSettingChoices(_ field: SettingField, force: Bool = false) async {
        guard field.metadata?["choices_source"]?.string != nil,
              !settingChoicesLoading.contains(field.key),
              force || settingChoiceLists[field.key] == nil else { return }
        let current = loadGeneration
        settingChoicesLoading.insert(field.key)
        defer { if current == loadGeneration { settingChoicesLoading.remove(field.key) } }
        do {
            let choices = try await model.settingChoices(key: field.key, force: force)
            guard current == loadGeneration, !Task.isCancelled else { return }
            settingChoiceLists[field.key] = choices
            settingChoiceErrors[field.key] = nil
        } catch {
            guard current == loadGeneration, !Task.isCancelled else { return }
            settingChoiceErrors[field.key] = error.presentableMessage
        }
    }

    private func effectiveValue(_ key: String) -> String {
        values[key] ?? loadedFields[key]?.value ?? modelAccess[key] ?? ""
    }

    private func voiceChoices(_ field: SettingField) -> [String]? {
        guard field.key == "AGENT_TTS_VOICE" else { return nil }
        let voices = model.modelCatalog.models(zdr: zdrOnly(field), purpose: .speech).first {
            $0.id == effectiveValue("AGENT_TTS_MODEL")
        }?.supportedVoices
        return voices?.isEmpty == false ? voices : nil
    }

    private func modelPurpose(_ field: SettingField) -> ModelPurpose? {
        guard let purpose = ModelPurpose.forSetting(field.key) else { return nil }
        return selectedModelProvider(for: field) == "openrouter" ? purpose : nil
    }

    private func zdrOnly(_ field: SettingField) -> Bool {
        effectiveValue("AGENT_LLM_ZDR_ONLY") == "true" ||
            (field.key.hasPrefix("AGENT_TTS_") && effectiveValue("AGENT_TTS_ZDR_ONLY") == "true")
    }

    private func modelEligibilityWarning(_ field: SettingField) -> String? {
        guard isModelIdentifier(field.key) else { return nil }
        let provider = selectedModelProvider(for: field)
        if let error = providerModelCatalogErrors[provider] { return error }
        if field.key == "AGENT_SECURITY_DECISION_MODEL_MODEL" {
            let credential = provider == "openrouter"
                ? "AGENT_LLM_OPENROUTER_API_KEY" : "AGENT_SECURITY_DECISION_MODEL_API_KEY"
            let saved = Set(configuration?.credentialNames ?? credentials.map(\.name))
            if !saved.contains(credential) && values[credential]?.isEmpty != false {
                return String(localized: "Save this provider's screening credential before using its model.")
            }
            if zdrOnly(field) {
                if provider == "openrouter" {
                    return String(localized: "OpenRouter ZDR routing may include Safety Retention endpoints. Review account privacy settings or a guardrail; this warning does not block usage.")
                }
                guard provider == "openrouter" || provider == "openai" else {
                    return String(localized: "Strict Zero Data Retention blocks this screening provider.")
                }
                let verifiedProviders = Set(effectiveValue("AGENT_LLM_ZDR_VERIFIED_PROVIDERS")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                guard verifiedProviders.contains(provider) else {
                    return String(localized: "Verify this screening account and add it to the verified ZDR provider list.")
                }
                let model = effectiveValue(field.key).trimmingCharacters(in: .whitespaces)
                let verifiedModels = Set(effectiveValue("AGENT_LLM_ZDR_VERIFIED_MODELS")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                guard !model.isEmpty, verifiedModels.contains(provider + ":" + model) else {
                    return String(localized: "This screening model is not in the administrator-verified ZDR model list.")
                }
            }
            return nil
        }
        if providerIsDisabled(provider) {
            return String(localized: "This provider is disabled. Enable it before using its models.")
        }
        if !configuredProviderIDs.contains(provider) {
            return String(localized: "Configure and save this provider's credentials before selecting its models.")
        }
        if zdrOnly(field), provider == "gemini" {
            return String(localized: "Gemini Developer API does not provide strict Zero Data Retention; strict mode blocks this route.")
        }
        if provider == "openai-compatible" && zdrOnly(field) {
            return String(localized: "Strict Zero Data Retention blocks custom OpenAI-compatible endpoints.")
        }
        if zdrOnly(field) {
            if provider == "openrouter" {
                return String(localized: "OpenRouter ZDR routing may include Safety Retention endpoints. Review account privacy settings or a guardrail; this warning does not block usage.")
            }
            let verifiedProviders = Set(effectiveValue("AGENT_LLM_ZDR_VERIFIED_PROVIDERS")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            guard verifiedProviders.contains(provider) else {
                return String(localized: "Strict mode is fail-closed. Verify this provider account and add it to the verified ZDR provider list.")
            }
            let model = effectiveValue(field.key).trimmingCharacters(in: .whitespaces)
            let verifiedModels = Set(effectiveValue("AGENT_LLM_ZDR_VERIFIED_MODELS")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            guard !model.isEmpty, verifiedModels.contains(provider + ":" + model) else {
                return String(localized: "This exact model is not in the administrator-verified ZDR model list.")
            }
        }
        if usesProviderModelCatalog(field.key), provider != "openrouter",
           providerModelCatalogs[provider] == nil {
            return String(localized: "Load this provider's model list before saving a model selection.")
        }
        if provider == "cloudflare" {
            return String(localized: "Verify AI Gateway logging, caching, and Logpush settings. Request headers do not disable Logpush.")
        }
        if let catalog = providerModelCatalogs[provider] {
            let selectedModels = effectiveValue(field.key).split(separator: ",").map(String.init)
            if selectedModels.contains(where: { model in !catalog.models.contains { $0.id == model } }) {
                return String(localized: "The selected model is not in this provider's latest discovered model list.")
            }
        }
        return providerModelCatalogs[provider]?.warning
    }

    private func providerIsDisabled(_ provider: String) -> Bool {
        effectiveValue("AGENT_PROVIDERS_DISABLED")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains(provider)
    }

    private func providerChoices(_ field: SettingField) -> [String]? {
        guard field.key == "AGENT_LLM_PROVIDER" ||
                (field.key.hasPrefix("AGENT_MODEL_ROUTES_") && field.key.hasSuffix("_PROVIDER")) else { return nil }
        let allowed = field.choices ?? []
        let disabled = Set(effectiveValue("AGENT_PROVIDERS_DISABLED")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let configured = configuredProviderIDs.filter { !disabled.contains($0) }
        if field.key == "AGENT_LLM_PROVIDER" {
            return ["auto"] + configured.filter { allowed.contains($0) }
        }
        var choices = configured.filter { allowed.contains($0) }
        if allowed.contains("inherit") { choices.insert("inherit", at: 0) }
        return choices
    }

    private var configuredProviderIDs: [String] {
        let savedNames = Set(configuration?.credentialNames ??
            credentials.filter { $0.active && $0.status != "removal pending" }.map(\.name))
        let credentialProviders: [(String, String)] = [
            ("openrouter", "AGENT_LLM_OPENROUTER_API_KEY"),
            ("openai", "AGENT_LLM_OPENAI_API_KEY"),
            ("anthropic", "AGENT_LLM_ANTHROPIC_API_KEY"),
            ("gemini", "AGENT_LLM_GEMINI_API_KEY"),
            ("cloudflare", "AGENT_LLM_CLOUDFLARE_API_KEY"),
        ]
        let configured = credentialProviders.compactMap { savedNames.contains($0.1) ? $0.0 : nil }
        let customURL = effectiveValue("AGENT_PROVIDERS_OPENAI_COMPATIBLE_BASE_URL")
        let hasCustomKey = savedNames.contains("AGENT_PROVIDERS_OPENAI_COMPATIBLE_API_KEY") ||
            savedNames.contains("AGENT_LLM_OPENAI_API_KEY")
        return orderedProviders(configured + (hasCustomKey && !customURL.isEmpty ? ["openai-compatible"] : []))
    }

    private func orderedProviders(_ values: [String]) -> [String] {
        let available = Set(values)
        let priority = effectiveValue("AGENT_PROVIDERS_PRIORITY")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return priority.filter { available.contains($0) } + values.filter { !priority.contains($0) }
    }

    private func isModelIdentifier(_ key: String) -> Bool {
        [
            "AGENT_LLM_MODEL", "AGENT_LLM_FALLBACK_MODEL", "AGENT_NAMING_MODEL", "AGENT_ROUTING_MODEL",
            "AGENT_LIMITS_SUMMARIZATION_MODEL", "AGENT_MEMORY_STEWARD_MODEL", "AGENT_DEEP_RESEARCH_MODEL",
            "AGENT_DEEP_RESEARCH_SEARCH_MODEL", "AGENT_SEARCH_MODEL", "AGENT_FUSION_MODEL",
            "AGENT_FUSION_ANALYSIS_MODELS", "AGENT_SECURITY_DECISION_MODEL_MODEL",
            "AGENT_SECURITY_DEVELOPMENT_MODEL", "AGENT_TTS_MODEL",
        ].contains(key)
    }

    private func usesProviderModelCatalog(_ key: String) -> Bool {
        [
            "AGENT_LLM_MODEL", "AGENT_LLM_FALLBACK_MODEL", "AGENT_NAMING_MODEL", "AGENT_ROUTING_MODEL",
            "AGENT_LIMITS_SUMMARIZATION_MODEL", "AGENT_MEMORY_STEWARD_MODEL", "AGENT_DEEP_RESEARCH_MODEL",
            "AGENT_DEEP_RESEARCH_SEARCH_MODEL", "AGENT_SEARCH_MODEL", "AGENT_SECURITY_DEVELOPMENT_MODEL",
        ].contains(key)
    }

    private func modelProviderSetting(for key: String) -> String? {
        switch key {
        case "AGENT_LLM_MODEL", "AGENT_LLM_FALLBACK_MODEL": return "AGENT_MODEL_ROUTES_TASK_PROVIDER"
        case "AGENT_NAMING_MODEL": return "AGENT_MODEL_ROUTES_NAMING_PROVIDER"
        case "AGENT_ROUTING_MODEL": return "AGENT_MODEL_ROUTES_ROUTING_PROVIDER"
        case "AGENT_LIMITS_SUMMARIZATION_MODEL": return "AGENT_MODEL_ROUTES_SUMMARIZATION_PROVIDER"
        case "AGENT_MEMORY_STEWARD_MODEL": return "AGENT_MODEL_ROUTES_MEMORY_PROVIDER"
        case "AGENT_DEEP_RESEARCH_MODEL": return "AGENT_MODEL_ROUTES_RESEARCH_PROVIDER"
        case "AGENT_DEEP_RESEARCH_SEARCH_MODEL": return "AGENT_MODEL_ROUTES_RESEARCH_SEARCH_PROVIDER"
        case "AGENT_SEARCH_MODEL": return "AGENT_MODEL_ROUTES_WEB_SEARCH_PROVIDER"
        case "AGENT_FUSION_MODEL", "AGENT_FUSION_ANALYSIS_MODELS": return "AGENT_MODEL_ROUTES_FUSION_PROVIDER"
        case "AGENT_SECURITY_DECISION_MODEL_MODEL": return "AGENT_SECURITY_DECISION_MODEL_PROVIDER"
        case "AGENT_SECURITY_DEVELOPMENT_MODEL": return "AGENT_MODEL_ROUTES_DEVELOPMENT_PROVIDER"
        case "AGENT_TTS_MODEL": return "AGENT_MODEL_ROUTES_SPEECH_PROVIDER"
        default: return nil
        }
    }

    private func selectedModelProvider(for field: SettingField) -> String {
        selectedModelProvider(for: field.key)
    }

    private func selectedModelProvider(for fieldKey: String) -> String {
        if let key = modelProviderSetting(for: fieldKey) {
            let configured = effectiveValue(key).lowercased()
            if !configured.isEmpty && !["auto", "inherit"].contains(configured) { return configured }
        }
        if fieldKey == "AGENT_SECURITY_DECISION_MODEL_PROVIDER" {
            return effectiveValue(fieldKey).lowercased()
        }
        return selectedModelProvider()
    }

    private func zdrOnly(for _: String) -> Bool {
        effectiveValue("AGENT_LLM_ZDR_ONLY") == "true"
    }

    private func selectedModelProvider() -> String {
        let configured = effectiveValue("AGENT_LLM_PROVIDER").lowercased()
        if !configured.isEmpty && configured != "auto" { return configured }
        switch URL(string: effectiveValue("AGENT_LLM_BASE_URL"))?.host?.lowercased() {
        case "openrouter.ai": return "openrouter"
        case "api.openai.com": return "openai"
        case "api.anthropic.com": return "anthropic"
        case "generativelanguage.googleapis.com": return "gemini"
        case "api.cloudflare.com": return "cloudflare"
        default: return "openai-compatible"
        }
    }

    /// Extra accounts stay collapsed so one provider's spare slots do not bury the rest of the page.
    @ViewBuilder private func accountList(_ accounts: [SettingGroup], root: SettingGroup, navigation: SettingsNavigation) -> some View {
        if let first = accounts.first {
        let saved = Set(configuration?.credentialNames ?? credentials.filter { $0.status != "removal pending" }.map(\.name))
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
                            if navigation.configured(account, credentials: saved) {
                                StatusBadge(title: String(localized: "Set up"), tone: .green)
                            } else if navigation.fields(in: account.id).contains(where: { $0.secret && saved.contains($0.key) }) {
                                StatusBadge(title: String(localized: "Incomplete setup"), tone: .orange)
                            }
                        }
                    }
                }
            }.padding(.top, 8)
        } label: {
            let count = accounts.filter { navigation.configured($0, credentials: saved) }.count
            Text(count == 0 ? String(localized: "Additional accounts") :
                    String(localized: "Additional accounts (\(count) set up)"))
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
            HStack {
                Text("Markdown formatting is supported. Changes are saved only after review.")
                    .font(.callout).foregroundStyle(Theme.secondary)
                Spacer()
                Toggle("Preview", isOn: $showingInstructionPreview).toggleStyle(.switch).controlSize(.small)
            }
            Group {
                if showingInstructionPreview {
                    ScrollView {
                        MarkdownContent(text: instructions).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .rememberingScroll("instructions-preview", in: scrollMemory, ready: instructionsLoaded)
                } else {
                    MarkdownEditor(text: $instructions)
                        .disabled(!instructionsLoaded || busy)
                        .onChange(of: instructions) { invalidatePreview() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.outline).allowsHitTesting(false))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// Catalog metadata can change after a server update even when saved values have not.
    private func checkForExternalChanges() async {
        guard !busy else { refreshAfterBusy = true; return }
        guard configuration != nil else { return }
        let current = loadGeneration
        do {
            let latest = try await model.configurationCatalog()
            guard current == loadGeneration else { return }
            guard !busy else { refreshAfterBusy = true; return }
            guard latest != catalogSnapshot else { return }
            let updated = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(latest))
            if updated.revision == configuration?.revision {
                var merged = updated
                merged.mergeLoadedValues(loadedFields)
                configuration = merged
                model.setupRequired = !merged.setupComplete
                catalogSnapshot = latest
                loadedGroups = loadedGroups.filter { id in
                    let owners = Set([id] + (merged.groups ?? []).filter { $0.parent == id }.map(\.id))
                    return merged.settings.filter { owners.contains($0.group) }.allSatisfy { loadedFields[$0.key] != nil }
                }
                reconcilePage()
                await loadPage()
                return
            }
            guard !model.configurationDirty else {
                error = String(localized: "Settings changed on the server. Your draft is preserved; discard it and reload before saving.")
                return
            }
            model.invalidateResources()
            await load(catalog: latest)
        } catch { self.error = error.presentableMessage ?? self.error }
    }

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
        showingReview = false
        model.configurationDirty = !values.isEmpty || (instructionsLoaded && instructions != instructionsOriginal) || acknowledge
        if model.configurationDirty { notice = nil }
    }

    /// Discard local edits without modifying saved server values or their activation state.
    private func discardDraft() async {
        model.invalidateResources()
        clearDraft()
        notice = nil
        await load()
    }

    /// Use only after an explicit discard, a confirmed save, or an uncontested reload.
    private func clearDraft() {
        values = [:]
        instructions = instructionsOriginal
        acknowledge = false
        invalidatePreview()
    }

    private func load(catalog: JSONValue? = nil) async {
        guard catalog == nil || !model.configurationDirty else { return }
        loadGeneration = UUID()
        loadingGroups = []; instructionsLoading = false
        modelOverview = nil; modelOverviewLoading = false; modelOverviewError = nil
        modelAccessLoaded = false
        modelAccess = [:]
        providerModelCatalogs = [:]; providerModelCatalogErrors = [:]; providerModelCatalogLoading = []
        settingChoiceLists = [:]; settingChoiceErrors = [:]; settingChoicesLoading = []
        busy = true
        defer { busy = false }
        do {
            guard model.health?.capabilities.contains("configuration.structured") == true else {
                throw ClientError.serverOutdated(String(localized: "structured settings"))
            }
            let result: JSONValue
            if let catalog { result = catalog }
            else { result = try await model.configurationCatalog() }
            configuration = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(result))
            catalogSnapshot = result
            model.setupRequired = configuration?.setupComplete == false
            if model.setupRequired, values.isEmpty, let first = navigation?.pages(in: .models).first {
                selectPage(.group(first.id), in: .models)
            }
            instructions = ""; instructionsOriginal = ""; instructionsLoaded = false
            loadedGroups = []; loadedFields = [:]
            reconcilePage()
            clearDraft()
            error = nil
            async let pageLoad: () = loadPage()
            async let credentialsLoad: () = loadCredentials()
            async let modelLoad: () = loadModelAccess()
            _ = await (pageLoad, credentialsLoad, modelLoad)
        } catch { self.error = error.presentableMessage ?? self.error }
    }

    private func reconcilePage() {
        if case .group(let id) = page, navigation?.pages(in: category).contains(where: { $0.id == id }) != true {
            if let first = navigation?.pages(in: category).first { selectPage(.group(first.id), in: category) }
            else { selectPage(.instructions, in: .assistant) }
        }
    }

    private func loadCredentials() async {
        do {
            let result = try await model.cachedRead("credentials")
            credentials = try Wire.decoder().decode(CredentialInventory.self, from: JSONEncoder().encode(result)).credentials
            credentialStatusLoaded = true
            credentialError = nil
        } catch {
            credentialStatusLoaded = false
            credentialError = error.presentableMessage.map { String(localized: "Can’t check saved credentials right now. \($0)") }
        }
    }

    private func loadModelAccess() async {
        let current = loadGeneration
        do {
            let result = try await model.cachedRead("configuration/settings")
            guard current == loadGeneration, !Task.isCancelled else { return }
            guard result["revision"]?.string == configuration?.revision else {
                throw ClientError.operationFailed(String(localized: "Settings changed on the server. Reload before editing."))
            }
            guard let fields = result["settings"]?.array else { throw ClientError.malformedResponse }
            modelAccess = Dictionary(uniqueKeysWithValues: fields.compactMap { field in
                guard let key = field["key"]?.string, let value = field["value"]?.string,
                      field["secret"] != .bool(true) else { return nil }
                return (key, value)
            })
            modelAccessLoaded = true
        } catch {
            guard current == loadGeneration, !Task.isCancelled else { return }
            self.error = error.presentableMessage ?? self.error
        }
    }

    private func providerModels(_ field: SettingField) -> [ProviderModel]? {
        guard usesProviderModelCatalog(field.key), modelPurpose(field) == nil else { return nil }
        let provider = selectedModelProvider(for: field)
        guard !providerIsDisabled(provider), configuredProviderIDs.contains(provider) else { return nil }
        return providerModelCatalogs[provider]?.models
    }

    private func loadProviderModels(for field: SettingField, force: Bool = false) async {
        guard modelAccessLoaded else { return }
        let current = loadGeneration
        let provider = selectedModelProvider(for: field)
        guard !providerModelCatalogLoading.contains(provider) else { return }
        if !force, providerModelCatalogs[provider] != nil { return }
        providerModelCatalogLoading.insert(provider)
        defer { if current == loadGeneration { providerModelCatalogLoading.remove(provider) } }
        do {
            let catalog = try await model.providerModelCatalog(providerID: provider)
            guard current == loadGeneration, !Task.isCancelled else { return }
            providerModelCatalogs[provider] = catalog
            providerModelCatalogErrors[provider] = nil
        } catch {
            guard current == loadGeneration, !Task.isCancelled else { return }
            providerModelCatalogErrors[provider] = error.presentableMessage
        }
    }

    /// Lazy page reads retain the catalog revision, so external edits never silently merge with a draft.
    private func loadPage() async {
        guard let configuration else { return }
        let current = loadGeneration
        do {
            switch page {
            case .app, .skills: return
            case .modelOverview:
                guard modelOverview == nil, !modelOverviewLoading else { return }
                modelOverviewLoading = true
                defer { if loadGeneration == current { modelOverviewLoading = false } }
                do {
                    let overview = try await model.modelSettingsOverview(revision: configuration.revision)
                    guard loadGeneration == current, !Task.isCancelled else { return }
                    modelOverview = overview
                    for item in overview.sections.flatMap(\.settings) {
                        loadedFields[item.id] = item.field
                    }
                    modelOverviewError = nil
                } catch {
                    guard loadGeneration == current, !Task.isCancelled else { return }
                    modelOverviewError = error.presentableMessage
                }
                return
            case .instructions:
                guard !instructionsLoaded, !instructionsLoading else { return }
                instructionsLoading = true
                defer { if loadGeneration == current { instructionsLoading = false } }
                let result = try await model.cachedRead("configuration/instructions")
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
                let result = try await model.cachedRead("configuration/settings?\(query.percentEncodedQuery ?? "")")
                let loaded = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(result))
                guard loadGeneration == current, !Task.isCancelled else { return }
                guard loaded.revision == configuration.revision else { throw ClientError.operationFailed(
                    String(localized: "Settings changed on the server. Save or discard your draft, then reload.")) }
                for field in loaded.settings { loadedFields[field.key] = field }
                self.configuration?.mergeLoadedValues(loadedFields)
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
            showingReview = true
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
            clearDraft()
            model.recordActivation(apply ? .active : .pending)
            notice = apply ? String(localized: "Configuration saved and application services activated.") :
                String(localized: "Saved. Choose Review & Apply when you are ready.")
            await load()
            await model.refreshAssistantName()
            if model.health?.capabilities.contains("configuration.activation") == true {
                do { try await model.refreshActivation() }
                catch { self.error = error.presentableMessage ?? self.error }
            }
            offerFirstChat = starting
        } catch {
            model.recordActivation(.unknown)
            self.error = error.presentableMessage ?? self.error
            notice = String(localized: "Some changes may have been saved or applied. Check Activity > Operation History before retrying.")
            preview = nil; reviewedPayload = nil
        }
    }

    /// Draft review stays visible regardless of the page's current scroll position.
    private var draftReview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Review your changes").font(.title2.weight(.semibold))
            ScrollView {
                if let preview { changeReview(preview) }
                if let error { ErrorBanner(message: error) }
            }
            HStack {
                StableProgress(active: busy)
                Spacer()
                Button("Keep editing") { showingReview = false }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                if configuration?.setupComplete == false {
                    Button("Save & Start") { apply = true; confirming = true }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!canSave || busy)
                } else {
                    Button("Save & Apply") { apply = true; confirming = true }.disabled(!canSave || busy)
                    Button("Save changes") { apply = false; confirming = true }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!canSave || busy)
                }
            }
        }
        .padding(24).frame(width: 660, height: 540)
        .interactiveDismissDisabled(busy)
        .accessibilityIdentifier("settings-draft-review")
        .confirmationDialog(apply ? "Save and activate reviewed changes?" : "Save reviewed changes?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(apply ? "Save & Apply" : "Save configuration") { Task { await save() } }
        } message: {
            Text(apply ? "Affected application services will be started or recreated. Active work may be interrupted. Enabled connections may begin processing messages." :
                 "This saves your changes without restarting Assistant. Use Review & Apply in the saved-settings banner when you are ready.")
        }
    }

    /// Review emphasizes actual changes and validation problems instead of a JSON dump.
    private func changeReview(_ preview: JSONValue) -> some View {
        ManagementPanel {
            VStack(alignment: .leading, spacing: 12) {
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
