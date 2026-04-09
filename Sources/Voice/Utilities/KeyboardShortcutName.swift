@preconcurrency import KeyboardShortcuts

@MainActor
extension KeyboardShortcuts.Name {
    static let dictationTrigger = Self(
        "dictationTrigger",
        default: .init(.v, modifiers: [.command, .shift])
    )
}
