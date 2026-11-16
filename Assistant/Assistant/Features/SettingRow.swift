import SwiftUI

/// One setting: label and explanation above a full-width control, with details one click away.
struct SettingRow: View {
    let field: SettingField
    let showIdentifier: Bool
    var credential: SavedCredential? = nil
    var credentialStatusLoaded = false
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
        } else if let choices = field.choices {
            Picker(field.label, selection: $value) {
                // Keep an unexpected saved value selectable rather than silently replacing it.
                ForEach(choices.contains(value) ? choices : [value] + choices, id: \.self) { choice in
                    Text(choice.isEmpty ? String(localized: "Not set") : choice).tag(choice)
                }
            }
            .labelsHidden().frame(maxWidth: Self.pickerWidth, alignment: .leading)
        } else {
            TextField(field.label, text: $value, prompt: field.defaultText.map { Text($0) })
                .textFieldStyle(.roundedBorder)
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
