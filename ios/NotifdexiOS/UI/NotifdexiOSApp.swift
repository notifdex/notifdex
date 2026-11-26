import SwiftUI

@main
struct NotifdexiOSApp: App {
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView(viewModel: viewModel)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        viewModel.reload()
                    }
                }
        }
    }
}
