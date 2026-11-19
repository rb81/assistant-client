import AppKit
import SwiftUI

/// Native lazy text layout keeps large read-only code, JSON, and log previews responsive.
struct SourceTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.usesFindPanel = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textContainerInset = NSSize(width: 12, height: 12)
            view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.setAccessibilityLabel(String(localized: "File or response text"))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.textColor = .labelColor
    }
}
