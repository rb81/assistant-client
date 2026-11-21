import SwiftUI

/// One installation-wide destination for decisions, notifications, and mutation receipts.
enum ActivitySection: String, CaseIterable, Identifiable {
    case attention, updates, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attention: return String(localized: "Needs Attention")
        case .updates: return String(localized: "Updates")
        case .history: return String(localized: "Operation History")
        }
    }
}

/// Activity is available from every screen, not just the chat list.
struct ActivityView: View {
    @Bindable var model: ClientModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Activity", systemImage: "bell").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Picker("Activity section", selection: $model.activitySection) {
                ForEach(ActivitySection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 16)
            if let error = model.error { ErrorBanner(message: error).padding(.horizontal, 24).padding(.bottom, 16) }
            Divider()
            switch model.activitySection {
            case .attention:
                VStack(spacing: 0) {
                    if !model.unconfirmedReferences.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Some action outcomes are unconfirmed").font(.headline)
                                Text("This is not a permission request. Check the server’s receipts before trying the action again.")
                                    .font(.callout).foregroundStyle(Theme.secondary)
                                Button("Check operation history") { model.activitySection = .history }
                            }
                            Spacer(minLength: 0)
                        }.padding(24)
                        Divider()
                    }
                    ApprovalsView(model: model)
                }
            case .updates: updates
            case .history: OperationsView(model: model)
            }
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 560, idealHeight: 680)
        .background(Theme.background)
    }

    private var updates: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Replies and notices").font(.title2.weight(.semibold))
                Text("Select a reply to open its conversation. Permission requests are in Needs Attention.")
                    .foregroundStyle(Theme.secondary)
                let items = model.activityUpdates.filter { $0.instanceID == model.health?.instanceID }
                if items.isEmpty && model.messages.allSatisfy({ $0.taskID != nil }) {
                    ContentUnavailableView("You’re all caught up", systemImage: "bell.badge",
                                           description: Text("New replies and installation notices will appear here."))
                }
                ForEach(items) { update in
                    Button {
                        if update.category == "approvals" { model.activitySection = .attention }
                        else if let task = update.taskID {
                            model.notificationTaskID = task
                            model.notificationRequest = UUID()
                            dismiss()
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: update.category == "approvals" ? "hand.raised" :
                                    update.category == "errors" ? "exclamationmark.circle" : "bubble.left")
                                .foregroundStyle(Theme.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(update.title).font(.body.weight(.medium))
                                Text(update.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if update.taskID != nil || update.category == "approvals" {
                                Image(systemName: "chevron.right").foregroundStyle(Theme.secondary)
                            }
                        }
                        .padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(update.taskID == nil && update.category != "approvals")
                }
                ForEach(model.messages.filter { $0.taskID == nil }) { message in
                    ManagementPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.purpose.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                            MarkdownContent(text: message.body)
                            if let error = message.error { ErrorBanner(message: error) }
                        }
                    }
                }
                if model.historyCursor != nil {
                    Button("Load earlier notices") {
                        Task {
                            do { try await model.loadHistory(older: true) }
                            catch { model.error = error.presentableMessage }
                        }
                    }
                }
            }.padding(24)
        }
        .onAppear { model.markUpdatesSeen() }
        .onChange(of: model.activityUpdates.count) { model.markUpdatesSeen() }
    }
}
