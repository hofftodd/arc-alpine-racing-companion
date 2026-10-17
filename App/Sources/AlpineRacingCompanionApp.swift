import SwiftData
import SwiftUI

@main
struct AlpineRacingCompanionApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { model.start() }
        }
        .modelContainer(for: [Conversation.self, ChatMessage.self])
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.didEnterBackground()
            case .active: model.didBecomeActive()
            default: break
            }
        }

        #if os(macOS)
            Settings {
                SettingsView()
                    .environment(model)
                    .frame(width: 480)
            }
        #endif
    }
}
