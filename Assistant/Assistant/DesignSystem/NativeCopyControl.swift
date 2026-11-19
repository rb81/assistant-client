import AppKit
import SwiftUI

/// A real AppKit control keeps copy clicks out of SwiftUI's selectable-text gesture handling.
struct NativeCopyControl: NSViewRepresentable {
    let label: String
    let compact: Bool
    let copied: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> CopyButton {
        let button = CopyButton()
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = context.coordinator
        button.action = #selector(Coordinator.copyText(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: CopyButton, context: Context) {
        context.coordinator.action = action
        button.title = compact ? "" : label
        button.image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: label)
        button.imagePosition = compact ? .imageOnly : .imageLeading
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(label)
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CopyButton, context: Context) -> CGSize? {
        CGSize(width: compact ? 28 : max(28, nsView.intrinsicContentSize.width), height: 28)
    }

    /// Copy should work on the first click even when the app was inactive.
    final class CopyButton: NSButton {
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// AppKit retains a stable target while SwiftUI updates the source and feedback.
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func copyText(_ sender: NSButton) { action() }
    }
}
