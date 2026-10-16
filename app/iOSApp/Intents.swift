import AppIntents

/// "New Thought Dump": for the Action Button, Siri, Spotlight and Shortcuts. Opens straight into recording.
struct NewThoughtDumpIntent: AppIntent {
    static let title: LocalizedStringResource = "New Thought Dump"
    static let description = IntentDescription("Start recording a thought dump.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.recordRequested = true
        return .result()
    }
}

struct ThoughtDumpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewThoughtDumpIntent(),
            phrases: ["New \(.applicationName)", "Start a \(.applicationName)", "\(.applicationName) now"],
            shortTitle: "New Thought Dump",
            systemImageName: "mic.circle.fill"
        )
    }
}
