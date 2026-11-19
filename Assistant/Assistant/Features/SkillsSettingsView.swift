import SwiftUI

/// A versioned skill catalog entry; instruction bodies are fetched only on open.
struct SkillEntry: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String
    let revision: String
    let locked: Bool
    let overlayFor: String?
    let body: String?
    let preferences: SkillPreference?

    /// Locks descriptive fields and the expected revision into a reviewed mutation.
    func deletion() -> JSONValue? {
        guard !locked else { return nil }
        return Self.mutation("delete", ["id": .string(id), "revision": .string(revision)])
    }

    /// Wraps skill mutations in the shared confirmed operation envelope.
    static func mutation(_ action: String, _ arguments: [String: JSONValue]) -> JSONValue {
        .object(["operation": .string("domain.mutate"), "action": .string("skills.\(action)"),
                 "confirmed": .bool(true), "arguments": .object(arguments)])
    }
}

/// Editable instructions attached to a locked workflow.
struct SkillPreference: Decodable {
    let id: String
    let title: String
    let description: String
    let revision: String
    let body: String
}

/// Settings for inspecting locked workflows and managing versioned custom guidance.
struct SkillsSettingsView: View {
    private static let pageSize = 20
    let model: ClientModel
    @State private var entries: [SkillEntry] = []
    @State private var selected: SkillEntry?
    @State private var search = ""
    @State private var offset = 0
    @State private var total = 0
    @State private var error: String?
    @State private var loading = false
    @State private var busy = false
    @State private var editor: SkillDraft?
    @State private var pendingDeletion: Deletion?
    @State private var deleting = false

    private struct Page: Decodable {
        let skills: [SkillEntry]
        let total: Int
    }

    private struct Deletion {
        let payload: JSONValue
        let title: String
        let parentID: String?
    }

    private struct SearchPage: Equatable {
        let query: String
        let offset: Int
        let instanceID: String?
    }

    private var searchPage: SearchPage {
        SearchPage(query: search, offset: offset, instanceID: model.health?.instanceID)
    }
    private var supported: Bool { model.health?.capabilities.contains("skills.manage") == true }
    private var attachedPreferences: Bool { model.health?.capabilities.contains("skills.preferences") == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            PageHeading(title: "Skills", subtitle: "Inspect shipped workflows or publish custom guidance and preference overlays.")
            if !supported {
                Label("This server does not support skill management.", systemImage: "info.circle")
                    .foregroundStyle(Theme.secondary)
            } else {
                if let error { ErrorBanner(message: error) }
                catalog
                if let selected { detail(selected) }
            }
        }
        .task(id: searchPage) {
            guard supported else { return }
            let request = searchPage
            if !request.query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
            await load(request)
        }
        .onChange(of: search) { offset = 0 }
        .onChange(of: model.health?.instanceID) {
            entries = []
            total = 0
            offset = 0
            selected = nil
            editor = nil
            deleting = false
            pendingDeletion = nil
        }
        .sheet(item: $editor) { draft in
            SkillEditor(draft: draft) { payload in
                _ = try await model.perform(payload)
                await load(searchPage)
                if let identifier = draft.refreshParent ?? payload["arguments"]?["id"]?.string {
                    await open(identifier)
                }
            }
        }
        .confirmationDialog(pendingDeletion?.parentID == nil ? "Delete this skill?" : "Remove preferences?",
                            isPresented: $deleting, titleVisibility: .visible,
                            presenting: pendingDeletion) { deletion in
            Button(deletion.parentID == nil ? "Delete skill" : "Remove preferences", role: .destructive) {
                Task { await delete(deletion) }
            }
        } message: { deletion in
            if deletion.parentID == nil {
                Text("Remove \(deletion.title) from the active skill catalog?")
            } else {
                Text("The locked skill will not change.")
            }
        }
        .disabled(busy)
    }

    private var catalog: some View {
        ManagementPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Search skills", text: $search)
                        .accessibilityIdentifier("skills-search")
                    StableProgress(active: loading)
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.invalidateResources()
                        Task { await load(searchPage) }
                    }
                    Button("Add skill", systemImage: "plus") { editor = SkillDraft() }
                }
                Divider()
                if entries.isEmpty && !loading { Text("No matching skills.").foregroundStyle(Theme.secondary) }
                ForEach(entries) { entry in
                    Button {
                        Task { await open(entry.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(entry.title, systemImage: entry.locked ? "lock" : "doc.text")
                            Text(entry.description).font(.caption).foregroundStyle(Theme.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(DestinationButtonStyle(selected: selected?.id == entry.id))
                    .accessibilityIdentifier("skill-\(entry.id)")
                }
                if offset > 0 || total > entries.count {
                    HStack {
                        Button("Previous") { offset = max(0, offset - Self.pageSize) }.disabled(offset == 0)
                        Text("\(offset + (entries.isEmpty ? 0 : 1))–\(offset + entries.count) of \(total)")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        Button("Next") { offset += Self.pageSize }.disabled(offset + entries.count >= total)
                    }
                }
            }
        }
    }

    private func detail(_ skill: SkillEntry) -> some View {
        ManagementPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(skill.title).font(.title3.weight(.semibold))
                    if skill.locked { Label("Locked", systemImage: "lock").foregroundStyle(Theme.secondary) }
                    Spacer()
                    if !skill.locked {
                        Button("Edit skill") { editor = SkillDraft(skill: skill) }
                        Button("Delete skill…", role: .destructive) {
                            guard let payload = skill.deletion() else { return }
                            pendingDeletion = Deletion(payload: payload, title: skill.title, parentID: nil)
                            deleting = true
                        }
                    }
                }
                Text("\(skill.id) · Revision \(skill.revision)").font(.caption).foregroundStyle(Theme.secondary)
                if let parent = skill.overlayFor { Text("Preferences for \(parent)").font(.caption) }
                Text(skill.body ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if skill.locked {
                    Divider()
                    HStack {
                        Text("Preferences").font(.headline)
                        Spacer()
                        Button(skill.preferences == nil ? "Add preferences" : "Edit preferences") {
                            editor = SkillDraft(parent: skill.id, preference: skill.preferences, attached: attachedPreferences)
                        }
                        if let preference = skill.preferences {
                            Button("Remove preferences", role: .destructive) {
                                let payload = SkillEntry.mutation("delete", [
                                    "id": .string(preference.id), "revision": .string(preference.revision)
                                ])
                                pendingDeletion = Deletion(payload: payload, title: preference.title, parentID: skill.id)
                                deleting = true
                            }
                        }
                    }
                    if let preference = skill.preferences {
                        Text(preference.body).textSelection(.enabled)
                    } else {
                        Text("No preferences set.").foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    private func fetch<T: Decodable>(_ action: String, _ arguments: [String: JSONValue], as type: T.Type) async throws -> T {
        let value = try await model.cachedSkillQuery(.object([
            "action": .string("skills.\(action)"), "arguments": .object(arguments)
        ]))
        return try Wire.decoder().decode(type, from: JSONEncoder().encode(value))
    }

    private func load(_ request: SearchPage) async {
        loading = true
        defer { if !Task.isCancelled && request == searchPage { loading = false } }
        do {
            var arguments: [String: JSONValue] = [
                "query": .string(request.query), "offset": .integer(Int64(request.offset)), "limit": .integer(Int64(Self.pageSize))
            ]
            if attachedPreferences { arguments["include_overlays"] = .bool(false) }
            let page = try await fetch("list", arguments, as: Page.self)
            guard !Task.isCancelled, request == searchPage else { return }
            if request.offset > 0 && request.offset >= page.total {
                offset = max(0, ((page.total - 1) / Self.pageSize) * Self.pageSize)
            } else {
                entries = page.skills
            }
            total = page.total
            error = nil
        } catch { if request == searchPage { self.error = error.presentableMessage } }
    }

    private func open(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            let skill = try await fetch("read", ["id": .string(id)], as: SkillEntry.self)
            guard skill.body != nil else { throw ClientError.malformedResponse }
            selected = skill
            error = nil
        } catch { self.error = error.presentableMessage }
    }

    private func delete(_ deletion: Deletion) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await model.perform(deletion.payload)
            if let parentID = deletion.parentID { await open(parentID) }
            else { selected = nil }
            await load(searchPage)
        } catch { self.error = error.presentableMessage }
    }
}

/// An editable draft that retains the server revision it was opened against.
private struct SkillDraft: Identifiable {
    let id = UUID()
    let revision: String?
    let parent: String?
    let refreshParent: String?
    var identifier: String
    var title: String
    var description: String
    var body: String

    init(skill: SkillEntry? = nil) {
        revision = skill?.revision
        parent = skill?.overlayFor
        refreshParent = nil
        identifier = skill?.id ?? ""
        title = skill?.title ?? ""
        description = skill?.description ?? ""
        body = skill?.body ?? ""
    }

    init(parent: String, preference: SkillPreference?, attached: Bool) {
        revision = preference?.revision
        self.parent = parent
        refreshParent = attached ? parent : nil
        identifier = preference?.id ?? "\(parent).PREFERENCES"
        title = preference?.title ?? "\(parent) preferences"
        description = preference?.description ?? "Operator preferences for \(parent)."
        body = preference?.body ?? ""
    }

    var payload: JSONValue {
        if let parent, revision == nil, refreshParent != nil {
            return SkillEntry.mutation("create", ["overlay_for": .string(parent), "body": .string(body)])
        }
        var fields: [String: JSONValue] = [
            "id": .string(identifier), "title": .string(title),
            "description": .string(description), "body": .string(body)
        ]
        if let revision { fields["revision"] = .string(revision) }
        if let parent, revision == nil { fields["overlay_for"] = .string(parent) }
        return SkillEntry.mutation(revision == nil ? "create" : "edit", fields)
    }
}

/// Holds failed drafts in place for editing, and closes only after a confirmed save.
private struct SkillEditor: View {
    @State var draft: SkillDraft
    let publish: (JSONValue) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    @State private var review = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text(draft.parent != nil ? "Preferences" : (draft.revision == nil ? "Add skill" : "Edit skill"))
                .font(.title2.weight(.semibold))
            if let error { ErrorBanner(message: error) }
            if draft.parent == nil {
                TextField("Skill ID", text: $draft.identifier).disabled(draft.revision != nil)
                TextField("Title", text: $draft.title)
                TextField("Description", text: $draft.description)
            } else {
                Text("Include what the Assistant should do and when. Preferences load automatically with this skill for admin requests.")
                    .foregroundStyle(Theme.secondary)
            }
            Text(draft.parent == nil ? "Skill instructions" : "Preference instructions").font(.headline)
            MarkdownEditor(text: $draft.body,
                           label: draft.parent == nil ? String(localized: "Skill instructions") :
                            String(localized: "Preference instructions"), identifier: "skill-instructions-editor")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.outline))
            HStack {
                StableProgress(active: saving)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review & publish") { review = true }.buttonStyle(PrimaryButtonStyle())
                    .disabled([draft.identifier, draft.title, draft.description, draft.body].contains {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
            }
        }
        .padding(24).frame(width: 580, height: 480).disabled(saving)
        .interactiveDismissDisabled(saving)
        .confirmationDialog(draft.parent == nil ? "Publish this skill revision?" : "Publish preferences?",
                            isPresented: $review, titleVisibility: .visible) {
            Button(draft.parent == nil ? "Publish skill" : "Publish preferences") {
                let payload = draft.payload
                saving = true
                Task {
                    defer { saving = false }
                    do { try await publish(payload); dismiss() }
                    catch { self.error = error.presentableMessage }
                }
            }
        } message: {
            Text("This guidance can be loaded in future Assistant tasks. Do not include secrets.")
        }
    }
}
