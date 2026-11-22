import Foundation

/// One destination in the Settings sidebar.
enum SettingsPage: Hashable {
    case group(String)
    case instructions
    case skills
    case app
    case modelOverview
}

/// A settings visit retains its category and search independently of its scroll position.
struct SettingsLocation: Hashable {
    var category = SettingsCategory.assistant
    var page = SettingsPage.group("identity")
    var search = ""
}

/// Browser-style history records visits, not redraws, and discards forward visits after a new branch.
struct NavigationHistory<Location: Equatable> {
    private(set) var current: Location
    private var previous: [Location] = []
    private var following: [Location] = []
    var canGoBack: Bool { !previous.isEmpty }
    var canGoForward: Bool { !following.isEmpty }

    init(_ current: Location) { self.current = current }

    /// Capture in-place state such as a search query before leaving a visit.
    mutating func update(_ location: Location) { current = location }

    mutating func visit(_ location: Location) {
        guard location != current else { return }
        previous.append(current)
        current = location
        following.removeAll()
    }

    mutating func back() {
        guard let location = previous.popLast() else { return }
        following.append(current)
        current = location
    }

    mutating func forward() {
        guard let location = following.popLast() else { return }
        previous.append(current)
        current = location
    }
}

/// Stable product destinations replace catalog-level navigation.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case app, assistant, models, connections, safety, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .assistant: return String(localized: "Assistant")
        case .models: return String(localized: "Models & Voice")
        case .connections: return String(localized: "Connections")
        case .safety: return String(localized: "Safety & Approvals")
        case .app: return String(localized: "General")
        case .advanced: return String(localized: "Advanced")
        }
    }

    /// Familiar symbols make the persistent category pane easy to scan.
    var symbol: String {
        switch self {
        case .assistant: return "sparkles"
        case .models: return "waveform"
        case .connections: return "network"
        case .safety: return "lock.shield"
        case .app: return "macwindow"
        case .advanced: return "slider.horizontal.3"
        }
    }
}
/// Fields that share a heading within a settings page, plus any extra accounts filed under it.
struct SettingsSection: Identifiable {
    let title: String?
    let fields: [SettingField]
    let accounts: [SettingGroup]
    var id: String { title ?? "" }
}

/// Turns the server's flat settings list and group metadata into pages, sections, and search results.
struct SettingsNavigation {
    let groups: [SettingGroup]
    private let fieldsByGroup: [String: [SettingField]]

    init(_ configuration: FullConfiguration) {
        fieldsByGroup = Dictionary(grouping: configuration.settings, by: \.group)
        groups = configuration.groups ?? Self.fallbackGroups(configuration.settings)
    }

    /// Everyday pages, in the server's order.
    var essentials: [SettingGroup] { groups.filter { $0.parent == nil && $0.basic } }

    /// Tuning pages, alphabetical because the list is long and rarely browsed in order.
    var advanced: [SettingGroup] {
        groups.filter { $0.parent == nil && !$0.basic }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func group(_ id: String) -> SettingGroup? { groups.first { $0.id == id } }
    /// Tuning pages are named for their task rather than inheriting an unrelated setup heading.
    func title(_ group: SettingGroup, in category: SettingsCategory) -> String {
        category == .advanced ? group.advancedTitle ?? group.title : group.title
    }

    /// Server-owned grouping keeps future fields discoverable without another client taxonomy.
    func pages(in category: SettingsCategory) -> [SettingGroup] {
        groups.filter { group in
            guard group.parent == nil else { return false }
            let relatedFields = fields(in: group.id) +
                groups.filter { $0.parent == group.id }.flatMap { fields(in: $0.id) }
            return relatedFields.contains { self.category(for: group, field: $0) == category }
        }
    }

    /// Settings tuning has a destination of its own, including tuning for otherwise basic pages.
    func category(for root: SettingGroup, field: SettingField) -> SettingsCategory {
        if root.destination == "server" || !root.basic || field.metadata?["level"]?.string == "advanced" {
            return .advanced
        }
        if let category = root.destination.flatMap(SettingsCategory.init(rawValue:)) { return category }
        switch root.id {
        case "models", "embeddings", "transcription": return .models
        case "email", "telegram", "calendar", "zoom", "dropbox": return .connections
        case "approvals", "security": return .safety
        case "deployment": return .advanced
        default: return .assistant
        }
    }

    func fields(in group: String) -> [SettingField] { fieldsByGroup[group] ?? [] }

    /// The page's own fields split by section; extra accounts attach to the section they belong to.
    func sections(in group: String) -> [SettingsSection] {
        let fields = fields(in: group)
        let accounts = groups.filter { $0.parent == group && $0.section != nil }
        var order: [String?] = []
        for field in fields where !order.contains(field.section) { order.append(field.section) }
        for account in accounts where !order.contains(account.section) { order.append(account.section) }
        return order.map { title in
            SettingsSection(title: title, fields: fields.filter { $0.section == title },
                            accounts: accounts.filter { $0.section == title })
        }
    }

    /// Nested groups shown as their own panels below the page's fields.
    func subgroups(of group: String, includeAdvanced: Bool) -> [SettingGroup] {
        groups.filter { $0.parent == group && $0.section == nil && (includeAdvanced || $0.basic) }
    }

    /// Search covers every label, identifier, and explanation regardless of the advanced toggle.
    func search(_ text: String) -> [(group: SettingGroup, fields: [SettingField])] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let synonyms = ["api key": "key", "password": "password", "ai": "model",
                        "permissions": "security", "mail": "email", "voice": "transcription"]
        let expanded = synonyms[query.lowercased()] ?? query
        return groups.compactMap { group in
            let matches = fields(in: group.id).filter {
                $0.label.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query)
                    || ($0.help?.localizedCaseInsensitiveContains(query) ?? false)
                    || $0.label.localizedCaseInsensitiveContains(expanded)
            }
            return matches.isEmpty ? nil : (group, matches)
        }
    }

    /// Breadcrumb such as "Calendar › Google calendar 2" for search results.
    func path(_ group: SettingGroup) -> String {
        guard let parent = group.parent.flatMap(self.group) else { return group.title }
        return "\(parent.title) › \(group.title)"
    }

    /// Defaults such as "primary" are not evidence of an OAuth account being set up.
    func configured(_ group: SettingGroup, credentials: Set<String> = []) -> Bool {
        let required = fields(in: group.id).filter(\.secret)
        guard !required.isEmpty else {
            return fields(in: group.id).contains { !$0.value.isEmpty && $0.value != $0.defaultText }
        }
        return required.allSatisfy { credentials.contains($0.key) }
    }

    /// Older servers send no group metadata; derive flat top-level pages from field groups.
    private static func fallbackGroups(_ settings: [SettingField]) -> [SettingGroup] {
        let essentials: Set = ["identity", "models", "email", "telegram", "calendar", "zoom", "dropbox",
                               "transcription", "approvals", "security", "embeddings"]
        var seen: [String] = []
        for field in settings where !seen.contains(field.group) { seen.append(field.group) }
        return seen.map { id in
            let title = id.replacingOccurrences(of: "advanced:", with: "")
                .replacingOccurrences(of: "catalog:", with: "")
                .replacingOccurrences(of: "_", with: " ").capitalized
            return SettingGroup(id: id, title: title, help: nil, parent: nil, section: nil,
                                basic: essentials.contains(id))
        }
    }
}
