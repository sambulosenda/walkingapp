import SwiftUI

@main
struct UnwalkedApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Reports made with no signal, or while the server was down, go now.
                .task { await model.reports.flush() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.ground.ignoresSafeArea()
            switch model.screen {
            case .onboarding:
                OnboardingFlow()
            case .home:
                HomeScreen()
            case .loops:
                LoopOptionsScreen()
            case .walking:
                if let session = model.session { WalkingScreen(session: session) }
            case .complete(let summary):
                WalkCompleteScreen(summary: summary)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .preferredColorScheme(model.isAfterDark && model.screen != .onboarding ? .dark : nil)
        .fullScreenCover(isPresented: $model.showPaywall) {
            PaywallScreen()
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet()
        }
        .tint(Theme.text)
    }
}
