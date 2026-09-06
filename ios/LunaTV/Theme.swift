import SwiftUI

enum LunaTheme {
    static let background = Color(red: 0.035, green: 0.071, blue: 0.122)
    static let surface = Color(red: 0.075, green: 0.13, blue: 0.22)
    static let raised = Color(red: 0.105, green: 0.19, blue: 0.31)
    static let accent = Color(red: 0.20, green: 0.88, blue: 0.62)
    static let accentSoft = Color(red: 0.20, green: 0.88, blue: 0.62, opacity: 0.28)
    static let secondaryText = Color(red: 1, green: 1, blue: 1, opacity: 0.68)
}

struct LunaBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(LunaTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}

extension View {
    func lunaBackground() -> some View { modifier(LunaBackground()) }
}
