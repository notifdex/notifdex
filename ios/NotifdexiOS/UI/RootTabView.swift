import SwiftUI

struct RootTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedTab: Tab = .inbox

    enum Tab: Hashable {
        case inbox
        case capture
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            InboxView(viewModel: viewModel, onOpenCapture: { selectedTab = .capture })
                .tabItem {
                    Label("Inbox", systemImage: "tray.full.fill")
                }
                .tag(Tab.inbox)

            CaptureSetupView(viewModel: viewModel)
                .tabItem {
                    Label("Capture", systemImage: "bolt.badge.automatic.fill")
                }
                .tag(Tab.capture)

            SettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(Tab.settings)
        }
        .tint(NotifdexTheme.prussian)
    }
}
