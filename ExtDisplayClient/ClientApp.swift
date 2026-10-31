import SwiftUI

@main
struct ExtDisplayClientApp: App {
    @StateObject private var model = ClientModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(active: phase == .active)
        }
    }
}
