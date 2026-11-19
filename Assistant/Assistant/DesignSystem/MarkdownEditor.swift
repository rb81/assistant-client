import AppKit
import SwiftUI

/// A bounded native Markdown editor; only its document scrolls, never the surrounding page.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var label = String(localized: "Assistant instructions")
    var identifier = "instructions-editor"
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier(identifier)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        editor.isEditable = isEnabled
        if editor.string != text {
            editor.string = text
            context.coordinator.highlight(editor)
        } else if context.coordinator.colorScheme != colorScheme {
            context.coordinator.highlight(editor)
        }
        context.coordinator.colorScheme = colorScheme
    }

    /// Attribute-only updates preserve the insertion point, undo history, and original Markdown.
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var colorScheme: ColorScheme?
        private var highlighting: Task<Void, Never>?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
            highlighting?.cancel()
            highlighting = Task { [weak self, weak editor] in
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard let self, let editor, !editor.hasMarkedText() else { return }
                highlight(editor)
            }
        }

        func highlight(_ editor: NSTextView) {
            guard let storage = editor.textStorage, !editor.hasMarkedText() else { return }
            let range = NSRange(location: 0, length: storage.length)
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: range)
            for (pattern, color, weight) in [
                ("(?m)^#{1,6}\\s+.+$", NSColor.controlAccentColor, NSFont.Weight.semibold),
                ("(?m)^\\s*(?:[-*+] |[0-9]+[.)] |> ).*$", NSColor.secondaryLabelColor, .regular),
                ("\\*\\*[^\\n*]+\\*\\*|__[^\\n_]+__", NSColor.labelColor, .semibold),
                ("\\[[^\\]\\n]+\\]\\([^\\n)]+\\)", NSColor.linkColor, .regular),
                ("(?s)```.*?(?:```|\\z)|~~~.*?(?:~~~|\\z)|`[^`\\n]+`", NSColor.systemOrange, .regular)
            ] {
                guard let expression = try? NSRegularExpression(pattern: pattern) else {
                    preconditionFailure("Invalid Markdown highlighting rule")
                }
                for match in expression.matches(in: editor.string, range: range) {
                    storage.addAttributes([.foregroundColor: color,
                                           .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: weight)],
                                          range: match.range)
                }
            }
            storage.endEditing()
            editor.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        }
    }
}
