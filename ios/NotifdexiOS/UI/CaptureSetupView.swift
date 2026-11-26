import SwiftUI

struct CaptureSetupView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showingGuideSheet = false
    @State private var showingAddAppAlert = false
    @State private var customAppName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "bolt.badge.automatic.fill")
                                .font(.title3)
                                .foregroundStyle(NotifdexTheme.prussian)
                            Text("iOS 27 Shortcuts Capture")
                                .font(.headline)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !viewModel.settings.paused },
                                set: { viewModel.setPaused(!$0) }
                            ))
                            .labelsHidden()
                        }

                        Text("Create one combined Notification automation in Apple Shortcuts covering all apps you want (X, Gmail, WeChat, Messages, etc.). Once connected to Notifdex's Capture Notification action, toggling apps below controls capture dynamically without re-editing Shortcuts.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                viewModel.openShortcutsAutomations()
                            } label: {
                                Label("Open Shortcuts", systemImage: "arrow.up.forward.app.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                showingGuideSheet = true
                            } label: {
                                Label("Setup Guide", systemImage: "list.number")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    ForEach(viewModel.settings.apps) { app in
                        CaptureAppRow(
                            app: app,
                            status: viewModel.automationStatus(for: app),
                            onToggle: { viewModel.toggleApp(id: app.id) }
                        )
                    }

                    Button {
                        customAppName = ""
                        showingAddAppAlert = true
                    } label: {
                        Label("Add Custom App", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Apps in Notifdex")
                } footer: {
                    Text("A toggle only controls whether Notifdex stores alerts it receives. \"Selected · Awaiting Shortcut\" means the app is enabled here, but no Shortcuts automation has delivered a notification for it yet.")
                }

                if let toast = viewModel.toastMessage {
                    Section {
                        Text(toast)
                            .font(.footnote)
                            .foregroundStyle(NotifdexTheme.celadon)
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(NotifdexTheme.vermilion)
                    }
                }
            }
            .navigationTitle("Capture")
            .sheet(isPresented: $showingGuideSheet) {
                ShortcutsGuideSheet(onOpenShortcuts: { viewModel.openShortcutsAutomations() })
            }
            .alert("Add Custom App", isPresented: $showingAddAppAlert) {
                TextField("Exact App Name (e.g. Telegram)", text: $customAppName)
                Button("Add") {
                    viewModel.addCustomApp(name: customAppName)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Match the App label exposed by your iOS 27 Shortcuts Notification automation.")
            }
        }
    }
}

private struct CaptureAppRow: View {
    let app: CaptureAppConfig
    let status: AppAutomationStatus
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NotifdexTheme.color(for: app.name).opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: NotifdexTheme.symbol(for: app.name))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotifdexTheme.color(for: app.name))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body.weight(.medium))
                statusLine
            }

            Spacer()

            Toggle("", isOn: Binding(get: { app.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .active(let lastCapturedAt, let count):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NotifdexTheme.celadon)
                if lastCapturedAt > 0 {
                    Text("Active via Shortcuts · \(count) saved")
                } else {
                    Text("Active via Shortcuts")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .awaitingShortcut:
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.questionmark")
                    .foregroundStyle(NotifdexTheme.sienna)
                Text("Selected · Awaiting Shortcut")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .paused(let count):
            HStack(spacing: 4) {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                Text(count > 0 ? "Paused in Notifdex · \(count) saved" : "Paused in Notifdex")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutsGuideSheet: View {
    let onOpenShortcuts: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("One-Time Combined Setup (All Apps in One Automation)") {
                    stepRow(1, "Open Apple Shortcuts and tap the Automation tab.")
                    stepRow(2, "Tap + → choose Notification.")
                    stepRow(3, "Select all apps you want to track (e.g. X, Gmail, WeChat, Messages), leave text filters empty, and choose Run Immediately.")
                    stepRow(4, "Tap Next → New Blank Automation → search for Notifdex → Capture Notification.")
                    stepRow(5, "Map the Notification variable into the 4 fields on that single action: App → App, Title → Title, Subtitle → Subtitle, Body → Body.")
                    stepRow(6, "Tap Done. Send a test alert — the app row in Notifdex will switch to Active via Shortcuts.")
                }

                Section("Known iOS Limitations") {
                    Text("• Notifdex cannot silently create or toggle Apple Shortcuts automations on your behalf.")
                    Text("• Capture is forward-only: it records alerts as they arrive, not older Notification Center history.")
                    Text("• If iOS Show Previews is set to Never or When Unlocked, lock-screen triggers may omit the message body.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Section {
                    Button {
                        dismiss()
                        onOpenShortcuts()
                    } label: {
                        Label("Open Apple Shortcuts", systemImage: "arrow.up.forward.app.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Shortcuts Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(NotifdexTheme.prussian.opacity(0.16)))
                .foregroundStyle(NotifdexTheme.prussian)
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
