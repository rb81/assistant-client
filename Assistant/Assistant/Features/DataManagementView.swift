import AppKit
import SwiftUI

/// Contained workspace browsing, reviewed file changes, and isolated destructive administration.
struct DataManagementView: View {
    let model: ClientModel
    @State private var path = "."
    @State private var entries: [JSONValue] = []
    @State private var total = 0
    @State private var offset = 0
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var pending: ReviewedMutation?
    @State private var newFolder = ""
    @State private var showingReset = false
    @State private var confirmation = ""
    @State private var resetting = false
    @State private var hasLoaded = false
    @State private var loadedPath: String?
    @State private var loadedOffset = 0

    private var showingRequestedPage: Bool { loadedPath == path && loadedOffset == offset }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "Data", subtitle: "Browse Assistant’s workspace. Shared files stay separate from chat task deletion.")
            if let error {
                Label(showingRequestedPage ? "Couldn’t refresh this folder. Showing the last loaded files." :
                        "Couldn’t open this folder.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Retry loading workspace", systemImage: "arrow.clockwise") { Task { await load() } }
                    DisclosureGroup("Technical details") { ErrorBanner(message: error) }
                }
            }
            if let notice { Label(notice, systemImage: "info.circle").foregroundStyle(Theme.secondary) }
            ManagementPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Workspace files").font(.title3.weight(.semibold))
                        StableProgress(active: busy)
                        Spacer()
                        Button("Upload file", systemImage: "square.and.arrow.up") { upload() }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    }
                    HStack {
                        Button("Parent folder", systemImage: "arrow.up") {
                            path = (path as NSString).deletingLastPathComponent
                            if path.isEmpty { path = "." }
                            offset = 0
                            Task { await load() }
                        }.disabled(path == ".")
                        Text(path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1)
                    }
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if showingRequestedPage {
                                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in fileRow(entry) }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    .frame(minHeight: 180, maxHeight: .infinity)
                    .overlay {
                        if (!showingRequestedPage || entries.isEmpty) && (hasLoaded || error != nil) && !busy {
                            Text(error != nil ? "Workspace could not be loaded." : "This folder is empty.")
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    Divider()
                    HStack {
                        Button("Previous") { offset = max(0, offset - 100); Task { await load() } }.disabled(offset == 0)
                        Text(showingRequestedPage ?
                             String(localized: "\(offset + (entries.isEmpty ? 0 : 1))–\(offset + entries.count) of \(total)") : "—")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        Button("Next") { offset += 100; Task { await load() } }
                            .disabled(!showingRequestedPage || offset + entries.count >= total)
                        Spacer()
                        TextField("New folder name", text: $newFolder).frame(maxWidth: 220)
                        Button("Create folder") { createFolder() }.disabled(!validName(newFolder))
                    }
                }
            }
            HStack {
                Label("Recovery", systemImage: "externaldrive.badge.exclamationmark")
                Spacer()
                Text(model.configurationDirty ? "Save or discard your Settings draft before resetting." :
                        "Make and verify a server backup before resetting.").font(.caption)
                Button("Reset data…", role: .destructive) { confirmation = ""; showingReset = true }
                    .disabled(model.configurationDirty)
            }
            .foregroundStyle(Theme.secondary)
            .font(.callout)
        }
        .frame(maxWidth: 1050).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(busy).task { await load() }
        .sheet(item: $pending) { mutation in
            MutationReview(mutation: mutation) {
                busy = true
                do {
                    _ = try await model.perform(mutation.payload)
                    notice = String(localized: "File operation completed.")
                    newFolder = ""
                    await load()
                } catch { self.error = error.presentableMessage ?? self.error }
                busy = false
            }
        }
        .sheet(isPresented: $showingReset) { resetReview }
    }

    /// Workspace queries use the shared typed domain surface, not arbitrary host-file access.
    private func load() async {
        let requestedPath = path
        let requestedOffset = offset
        busy = true
        defer { busy = false }
        do {
            let result = try await model.query("query", payload: .object([
                "action": .string("workspace.list"),
                "arguments": .object(["path": .string(requestedPath), "offset": .integer(Int64(requestedOffset)), "limit": .integer(100)])
            ]))
            guard let entries = result["entries"]?.array, let total = result["total"]?.integer else {
                throw ClientError.malformedResponse
            }
            guard path == requestedPath, offset == requestedOffset else { return }
            self.entries = entries; self.total = Int(total); hasLoaded = true; error = nil
            loadedPath = requestedPath; loadedOffset = requestedOffset
        } catch { self.error = error.presentableMessage ?? self.error }
    }

    private func fileRow(_ entry: JSONValue) -> some View {
        let name = entry["path"]?.string ?? ""
        let directory = entry["is_dir"] == .bool(true)
        return HStack(spacing: 12) {
            Image(systemName: directory ? "folder.fill" : "doc").foregroundStyle(directory ? Theme.accent : Theme.secondary)
            Button((name as NSString).lastPathComponent) {
                if directory { path = name; offset = 0; Task { await load() } }
                else { Task { await download(name) } }
            }.buttonStyle(.plain)
            Spacer()
            if let size = entry["size_bytes"]?.integer, !directory {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(Theme.secondary)
            }
            if !directory {
                Button("Download") { Task { await download(name) } }.font(.caption)
            }
            Button(role: .destructive) {
                mutate("workspace.delete", arguments: ["path": .string(name)], title: String(localized: "Delete \(name)"))
            } label: { Image(systemName: "trash") }.accessibilityLabel("Delete \(name)")
        }.padding(.vertical, 7)
    }

    private func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ![".", ".."].contains(name) && !name.contains("/") && !name.contains("\0")
    }

    /// New paths are children of the visible folder; containment is revalidated by the server.
    private func createFolder() {
        guard validName(newFolder) else { return }
        let target = path == "." ? newFolder : path + "/" + newFolder
        mutate("workspace.mkdir", arguments: ["path": .string(target)], title: String(localized: "Create folder \(newFolder)"))
    }

    private func mutate(_ action: String, arguments: [String: JSONValue], title: String) {
        pending = ReviewedMutation(title: title, payload: .object([
            "operation": .string("domain.mutate"), "action": .string(action),
            "arguments": .object(arguments), "confirmed": .bool(true)
        ]))
    }

    /// Bounded uploads use the existing scanner-gated API; no silent partial large-file upload.
    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else {
                throw ClientError.operationFailed(String(localized: "Uploads are limited to 1 MiB per file in this client."))
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 1_048_576 else { throw ClientError.oversizedResponse }
            let target = path == "." ? url.lastPathComponent : path + "/" + url.lastPathComponent
            mutate("workspace.write", arguments: ["path": .string(target), "content_base64": .string(data.base64EncodedString())],
                   title: String(localized: "Upload \(url.lastPathComponent)"))
        } catch { self.error = error.presentableMessage ?? self.error }
    }

    /// Chunked downloads verify a stable server digest and remove partial local output on failure.
    private func download(_ name: String) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (name as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        defer { busy = false }
        do {
            let data = try await model.downloadFile(.workspace(name))
            try data.write(to: url, options: .atomic)
            notice = String(localized: "Downloaded \(name).")
            error = nil
        } catch { self.error = error.presentableMessage ?? self.error }
    }

    /// Reset requires a literal phrase and deliberately preserves mailbox position.
    private var resetReview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reset Assistant data").font(.title2.weight(.semibold))
            Text("This removes database history and resets application data. Configuration is retained and mailbox position is preserved. This cannot be undone by this client.")
            TextField("Type RESET to continue", text: $confirmation).textFieldStyle(.roundedBorder)
            HStack {
                StableProgress(active: resetting)
                Spacer()
                Button("Cancel") { showingReset = false }.disabled(resetting)
                Button("Reset data", role: .destructive) {
                    resetting = true
                    Task {
                        defer { resetting = false }
                        do {
                            _ = try await model.perform(.object([
                                "operation": .string("database.reset"), "confirmation": .string(confirmation),
                                "clean_install": .bool(false), "keep_mailbox_position": .bool(true)
                            ]))
                            model.chats.clearSavedCache()
                            showingReset = false
                            await model.disconnect()
                            model.status = String(localized: "Data reset completed. Reconnect to continue.")
                        } catch { self.error = error.presentableMessage ?? self.error; showingReset = false }
                    }
                }.disabled(confirmation != "RESET" || resetting)
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(resetting)
    }
}
