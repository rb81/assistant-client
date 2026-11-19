import AppKit
import SwiftUI

/// Adaptive color, type and spacing for native Assistant views.
enum Theme {
    static let background = Color("Canvas")
    static let panel = Color("Panel")
    static let ink = Color("Ink")
    static let secondary = Color("Muted")
    static let accent = Color.accentColor
    static let highlight = Color("Ember")
    static let outline = secondary.opacity(0.18)
    static let pageTitle: Font = .largeTitle.weight(.semibold)
    static let sectionTitle: Font = .title2.weight(.semibold)
    static let spacing: CGFloat = 16
    static let radius: CGFloat = 12
    static let sidebarMinimum: CGFloat = 160
    static let sidebarIdeal: CGFloat = 180
    static let sidebarMaximum: CGFloat = 220
    static let contentWidth: CGFloat = 860
    static let settingsCategoryWidth: CGFloat = 210
    static let settingsDetailMinimum: CGFloat = 340
    static let windowMinimum = CGSize(width: 1000, height: 700)
    static let windowDefault = CGSize(width: 1280, height: 860)

    /// System monospace requires no manual font installation.
    static let terminalFont: Font = .system(size: 12, design: .monospaced)
}

/// Background progress occupies a fixed slot and stays invisible for fast reads.
struct StableProgress: View {
    let active: Bool
    @State private var visible = false

    var body: some View {
        ProgressView().controlSize(.small)
            .opacity(visible ? 1 : 0)
            .frame(width: 18, height: 18)
            .accessibilityHidden(!visible)
            .task(id: active) {
                visible = false
                guard active else { return }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    visible = true
                } catch { return }
            }
    }
}

/// Product navigation shares one selected treatment without stock list chrome.
struct DestinationButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(selected ? Theme.accent : Theme.ink)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(selected ? 0.12 : configuration.isPressed ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A persistent, vertically scrolling settings pane keeps its heading and selection in place.
struct SettingsNavigationPane<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.horizontal, 10).padding(.vertical, 16)
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier("settings-navigation")
        .background(Theme.panel)
    }
}

/// Consistent page introduction with room for a concise, task-oriented explanation.
struct PageHeading: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.pageTitle)
            Text(subtitle).foregroundStyle(Theme.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Status remains understandable without relying on color perception.
struct StatusBadge: View {
    let title: String
    let tone: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(tone.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A compact primary action preserves standard keyboard and accessibility semantics.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    /// Renders press feedback without removing the underlying native button behavior.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(Color("ButtonInk"))
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Shared panel container for management cards.
struct ManagementPanel<Content: View>: View {
    @ViewBuilder var content: Content

    /// Uses adaptive tokens and a subtle outline.
    var body: some View {
        content
            .padding(Theme.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.outline).allowsHitTesting(false))
    }
}

/// Errors remain selectable and visible rather than disappearing into console logs.
struct ErrorBanner: View {
    let message: String

    /// Conveys failure through text and icon, not color alone.
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(Text("Error: \(message)"))
    }
}

/// Text-only JSON/log inspector never executes HTML, Markdown, or remote scripts.
struct TerminalOutput: View {
    let text: String

    /// Uses selectable, wrapping output with the built-in monospace font.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: text)
                .font(Theme.terminalFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
