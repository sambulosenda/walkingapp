import AppIntents

/// "Hey Siri, start an Unwalked loop": plans a loop for the time given and starts guiding.
/// Also what the Action button and Shortcuts run.
struct StartLoopIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a loop"
    static var description = IntentDescription("Plans a loop from your door for the time you have, and starts guiding you round it.")
    /// A walk needs the app in front: location, guidance and the map all live there.
    static var openAppWhenRun = true

    @Parameter(title: "Minutes", inclusiveRange: (15, 120), requestValueDialog: "How many minutes have you got?")
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$minutes)-minute loop")
    }

    init() {}

    init(minutes: Int) {
        self.minutes = minutes
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // On a cold launch the app builds its model as it starts: give it a moment.
        var model = AppModel.current
        for _ in 0..<20 where model == nil {
            try await Task.sleep(for: .milliseconds(100))
            model = AppModel.current
        }
        guard let model else { return .result(dialog: "Open Unwalked once, then try again.") }
        let answer = await model.startLoop(minutes: minutes)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

struct UnwalkedShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartLoopIntent(),
            phrases: [
                "Start a loop with \(.applicationName)",
                "Start an \(.applicationName) loop",
                "Find me a walk with \(.applicationName)",
            ],
            shortTitle: "Start a loop",
            systemImageName: "figure.walk"
        )
    }
}
