import SwiftUI

// List and chrome differences between the platforms the package supports.
//
// `.insetGrouped` is an iOS style; macOS has no such thing and refuses to
// compile it. The grouped look is what a settings-shaped list wants on
// iOS, so the style is chosen once here instead of at every call site.

private struct GroupedListModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listStyle(.insetGrouped)
        #else
        content.listStyle(.inset)
        #endif
    }
}

extension View {
    /// A grouped settings list on iOS, an inset list on macOS.
    func groupedListStyle() -> some View {
        modifier(GroupedListModifier())
    }
}
