import AppKit
import SwiftUI

/// Gives SwiftUI's native split view a stable AppKit divider-restoration identity.
struct SplitViewAutosave: NSViewRepresentable {
    let name: String
    var defaultLeadingWidth: CGFloat?

    func makeNSView(context: Context) -> Anchor { Anchor(name: name, defaultLeadingWidth: defaultLeadingWidth) }
    func updateNSView(_ view: Anchor, context: Context) {
        view.name = name
        view.defaultLeadingWidth = defaultLeadingWidth
        view.configure()
    }

    /// A background anchor never participates in pointer or keyboard handling.
    final class Anchor: NSView {
        var name: String
        var defaultLeadingWidth: CGFloat?
        private var installing = false
        init(name: String, defaultLeadingWidth: CGFloat?) {
            self.name = name
            self.defaultLeadingWidth = defaultLeadingWidth
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        override func layout() { super.layout(); configure() }

        func configure() {
            guard !installing else { return }
            var parent = superview
            while let candidate = parent {
                if let split = candidate as? NSSplitView, split.isVertical {
                    guard split.autosaveName != name else { return }
                    if let defaultLeadingWidth {
                        guard split.bounds.width > 0, split.arrangedSubviews.count >= 2 else { return }
                        installing = true
                        // HSplitView ignores idealWidth. Establish the default before restoring any saved divider.
                        split.setPosition(defaultLeadingWidth, ofDividerAt: 0)
                    }
                    split.autosaveName = name
                    installing = false
                    return
                }
                parent = candidate.superview
            }
        }
    }
}
