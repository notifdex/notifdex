import SwiftUI

struct RootTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedTab: Tab = .inbox

    enum Tab: Hashable {
        case inbox
        case today
        case people
        case notes
        case setup
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            InboxView(viewModel: viewModel, onOpenCapture: { selectedTab = .setup })
                .tabItem {
                    Label("Inbox", systemImage: "tray.full.fill")
                }
                .tag(Tab.inbox)

            TodayView(viewModel: viewModel)
                .tabItem {
                    Label("Today", systemImage: "calendar.badge.clock")
                }
                .badge(viewModel.followUps.count)
                .tag(Tab.today)

            PeopleView(viewModel: viewModel)
                .tabItem {
                    Label("People", systemImage: "person.2.fill")
                }
                .tag(Tab.people)

            NotesView(viewModel: viewModel)
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
                .tag(Tab.notes)

            SetupHubView(viewModel: viewModel)
                .tabItem {
                    Label("Setup", systemImage: "bolt.badge.automatic.fill")
                }
                .tag(Tab.setup)
        }
        .tint(NotifdexTheme.prussian)
    }
}

private struct SetupHubView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var section: SectionKind = .capture

    enum SectionKind: String, CaseIterable, Identifiable {
        case capture = "Capture"
        case sync = "Sync & Status"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Setup Section", selection: $section) {
                    ForEach(SectionKind.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)

                if section == .capture {
                    CaptureSetupView(viewModel: viewModel, embedded: true)
                } else {
                    SettingsView(viewModel: viewModel, embedded: true)
                }
            }
            .navigationTitle(section == .capture ? "Capture" : "Sync & Status")
        }
    }
}
