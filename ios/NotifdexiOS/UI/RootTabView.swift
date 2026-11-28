import SwiftUI

struct RootTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @AppStorage("notifdex.ios.hasSeenWelcome") private var hasSeenWelcome = false
    @State private var selectedTab: Tab = .inbox
    @State private var showingWelcome = false

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

            SetupHubView(viewModel: viewModel, onShowWelcome: { showingWelcome = true })
                .tabItem {
                    Label("Setup", systemImage: "bolt.badge.automatic.fill")
                }
                .tag(Tab.setup)
        }
        .tint(NotifdexTheme.prussian)
        .onAppear {
            if !hasSeenWelcome && viewModel.stats.totalCount == 0 {
                showingWelcome = true
            }
        }
        .sheet(isPresented: $showingWelcome, onDismiss: { hasSeenWelcome = true }) {
            WelcomeOnboardingSheet(
                onSetupCapture: {
                    hasSeenWelcome = true
                    showingWelcome = false
                    selectedTab = .setup
                },
                onTrySamples: {
                    hasSeenWelcome = true
                    showingWelcome = false
                    selectedTab = .inbox
                    viewModel.loadSampleAlerts()
                },
                onDismiss: {
                    hasSeenWelcome = true
                    showingWelcome = false
                }
            )
        }
    }
}

private struct SetupHubView: View {
    @ObservedObject var viewModel: AppViewModel
    let onShowWelcome: () -> Void
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
                    SettingsView(viewModel: viewModel, embedded: true, onShowWelcome: onShowWelcome)
                }
            }
            .navigationTitle(section == .capture ? "Capture" : "Sync & Status")
        }
    }
}

private struct WelcomeOnboardingSheet: View {
    let onSetupCapture: () -> Void
    let onTrySamples: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(NotifdexTheme.prussian)
                        Text("Welcome to Notifdex")
                            .font(.largeTitle.bold())
                        Text("A local-first notification inbox, follow-up list, and relationship notebook for your iPhone and Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        OnboardingFeatureRow(
                            icon: "lock.shield.fill",
                            tint: NotifdexTheme.prussian,
                            title: "Private & Local by Default",
                            detail: "Alerts, People, Today follow-ups, and Notes stay in on-device SQLite—no account logins and no Notifdex servers."
                        )
                        OnboardingFeatureRow(
                            icon: "bolt.badge.automatic.fill",
                            tint: NotifdexTheme.celadon,
                            title: "Capture via Apple Shortcuts",
                            detail: "On iOS 27+, create one Shortcuts Notification automation pointing to Notifdex → Capture Notification to record alerts even while your Mac sleeps."
                        )
                        OnboardingFeatureRow(
                            icon: "icloud.fill",
                            tint: NotifdexTheme.sienna,
                            title: "Optional Private iCloud Sync",
                            detail: "Pair with Notifdex for macOS through your own Apple iCloud Private Database. Hidden Mac alerts stay strictly local."
                        )
                    }

                    VStack(spacing: 10) {
                        Button(action: onSetupCapture) {
                            Label("Set Up Shortcuts & iCloud Sync", systemImage: "bolt.badge.automatic.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(action: onTrySamples) {
                            Label("Try Sample Alerts", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button("Explore on My Own", action: onDismiss)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.top, 4)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}

private struct OnboardingFeatureRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
