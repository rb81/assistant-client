import SwiftUI

/// Server-owned saved changes are reviewed separately from unsaved drafts and technical requests.
struct ApplySettingsView: View {
    let model: ClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var summary: ConfigurationActivation?
    @State private var loading = true
    @State private var applying = false
    @State private var repeatConfirmed = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Apply saved settings").font(.title2.weight(.semibold))
            Text("Load the saved configuration into Assistant’s application services. Active work may be interrupted, and enabled connections may start processing messages.")
                .foregroundStyle(Theme.secondary)
            if let error { ErrorBanner(message: error) }
            if model.configurationDirty {
                Label("Save or discard your unsaved Settings draft before applying.", systemImage: "pencil.circle")
                    .foregroundStyle(.orange)
            }
            if model.pendingActivationAction {
                Label("A settings or service action is still running. Wait for its result in Activity before applying.",
                      systemImage: "hourglass").foregroundStyle(Theme.secondary)
            } else if model.unconfirmedActivationAction {
                Text("An earlier settings or service action has no confirmed outcome. Check Activity before applying again; this may repeat it.")
                    .foregroundStyle(.orange)
                Toggle("I checked Activity and intend to apply again", isOn: $repeatConfirmed)
                    .toggleStyle(.checkbox)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary {
                        if !summary.tracked {
                            Text("This server has no change history for settings saved before this update. Applying loads the currently saved configuration.")
                                .foregroundStyle(Theme.secondary)
                        } else if summary.changes.isEmpty {
                            Text("No saved changes are awaiting activation.").foregroundStyle(Theme.secondary)
                        } else {
                            Text("Saved values awaiting activation").font(.headline)
                            Text("Settings saved since the last successful apply. This is not a comparison with live container values.")
                                .font(.callout).foregroundStyle(Theme.secondary)
                            ForEach(summary.changes) { change in
                                VStack(alignment: .leading, spacing: 5) {
                                    if let context = change.context {
                                        Text(context).font(.caption).foregroundStyle(Theme.secondary)
                                    }
                                    Text(change.label).font(.body.weight(.medium))
                                    Text(change.value.isEmpty ? String(localized: "Not set") : change.value)
                                        .font(.callout).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                }
                                Divider()
                            }
                        }
                        if summary.requiresRebuild {
                            Label("Application images will be built before startup. This may take a few minutes.",
                                  systemImage: "shippingbox").font(.callout)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                StableProgress(active: loading || applying)
                if error != nil { Button("Reload changes") { Task { await load() } }.disabled(applying || loading) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("Apply saved settings") { Task { await apply() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(loading || applying || model.configurationDirty ||
                              model.pendingActivationAction || (model.unconfirmedActivationAction && !repeatConfirmed) ||
                              summary == nil || (summary?.tracked == true && summary?.pending != true))
            }
        }
        .padding(24).frame(width: 660, height: 540)
        .interactiveDismissDisabled(applying)
        .task { await load() }
    }

    private func load() async {
        loading = true
        summary = nil
        repeatConfirmed = false
        defer { loading = false }
        do {
            try await model.refreshOperations()
            try await model.refreshActivation()
            summary = model.activationSummary
            error = nil
        } catch {
            self.error = error.presentableMessage ??
                String(localized: "Settings changed while loading. Reload the saved changes.")
        }
    }

    private func apply() async {
        guard let summary else { return }
        guard !model.pendingActivationAction, !model.configurationDirty,
              !model.unconfirmedActivationAction || repeatConfirmed else {
            error = String(localized: "Check outstanding actions and unsaved changes before applying.")
            return
        }
        applying = true
        model.configurationApplying = true
        defer { applying = false; model.configurationApplying = false }
        do {
            _ = try await model.perform(.object([
                "operation": .string("service.lifecycle"), "action": .string("apply"),
                "revision": .string(summary.revision), "confirmed": .bool(true)
            ]))
            dismiss()
        } catch {
            self.summary = nil
            model.recordActivation(.unknown)
            self.error = error.presentableMessage ?? self.error
        }
    }
}
