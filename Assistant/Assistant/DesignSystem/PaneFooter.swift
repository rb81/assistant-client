import SwiftUI

/// Sidebar and detail footers share one baseline and fixed control height.
struct PaneFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content.frame(maxWidth: .infinity, minHeight: Theme.footerHeight, maxHeight: Theme.footerHeight)
                .padding(.horizontal, 16)
        }.background(Theme.panel)
    }
}
