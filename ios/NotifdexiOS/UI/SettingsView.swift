import NotifdexCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    var embedded: Bool = false
    @State private var confirmClear = false

    var body: some View {
        Group {
            if embedded {
                contentList
            } else {
                NavigationStack {
                    contentList
                        .navigationTitle("Settings")
                }
            }
        }
    }

    private var contentList: some View {
        List {
            Section {
                LabeledContent("Sync Mode") {
                    Text(viewModel.isSyncPaired ? (viewModel.autoSyncEnabled ? "Paired · Auto-Sync On" : "Paired · Manual Only") : "Local-Only")
                        .fontWeight(.semibold)
                        .foregroundStyle(viewModel.isSyncPaired ? NotifdexTheme.celadon : .secondary)
                }

                if viewModel.isSyncPaired {
                    Toggle("Automatic iCloud Sync", isOn: Binding(
                        get: { viewModel.autoSyncEnabled },
                        set: { viewModel.setAutoSyncEnabled($0) }
                    ))
                }

                if let summary = viewModel.lastSyncSummary {
                    LabeledContent("Last Sync", value: summary)
                }
                if let syncedAt = viewModel.lastSyncedAt {
                    LabeledContent("Last Synced") {
                        Text(syncedAt, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.isSyncPaired {
                    Button {
                        viewModel.enableCloudKitSync()
                    } label: {
                        Label("Enable & Pair iCloud Sync", systemImage: "icloud.and.arrow.up")
                    }
                } else {
                    Button {
                        viewModel.syncNowWithCloudKit()
                    } label: {
                        HStack {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud")
                            if viewModel.isSyncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isSyncing)

                    Button(role: .destructive) {
                        viewModel.revokeSyncDevice(viewModel.settings.deviceID)
                    } label: {
                        Label("Revoke This iPhone from Sync", systemImage: "xmark.icloud")
                    }
                }

                if !viewModel.syncDevices.isEmpty {
                    ForEach(viewModel.syncDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text("\(device.platform.displayLabel) · \(device.status.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.status == .paired {
                                Button("Revoke", role: .destructive) {
                                    viewModel.revokeSyncDevice(device.deviceID)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(NotifdexTheme.vermilion)
                }
            } header: {
                Text("Desktop ↔ iOS Sync")
            } footer: {
                Text("Sync is local-only by default. Opting in uses your private iCloud CloudKit container (iCloud.com.notifdex.shared). Hidden/muted Mac alerts never sync to iPhone, and revoking a device preserves all local data.")
            }

            Section("Capture Status") {
                LabeledContent("Mode") {
                    Text(viewModel.settings.paused ? "Paused" : "Listening for Shortcuts")
                        .foregroundStyle(viewModel.settings.paused ? NotifdexTheme.sienna : NotifdexTheme.celadon)
                        .fontWeight(.semibold)
                }
                LabeledContent("Inbox Alerts", value: "\(viewModel.coreAppCounts.values.reduce(0, +))")
                LabeledContent("Verified Shortcuts Apps", value: "\(viewModel.settings.verifiedAppLabels.count)")
                LabeledContent("Last Capture") {
                    if let ts = viewModel.stats.lastCapturedAt {
                        Text(Date(timeIntervalSince1970: ts), style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Device & Storage") {
                LabeledContent("Source ID") {
                    Text(viewModel.settings.sourceID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Database Size", value: viewModel.databaseFileSizeDescription)
                LabeledContent("Lock-Screen Writes", value: "After First Unlock")
            }

            Section {
                Button {
                    viewModel.simulateTestCapture(
                        app: "X",
                        title: "Notifidex",
                        subtitle: "",
                        body: "Simulated test alert (\(Int(Date().timeIntervalSince1970) % 10_000))"
                    )
                } label: {
                    Label("Simulate X Notification", systemImage: "paperplane.fill")
                }

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear Phase 1 Telemetry Log", systemImage: "trash")
                }
                .disabled(viewModel.stats.totalCount == 0)
            } header: {
                Text("Diagnostics & Test Tools")
            } footer: {
                Text("Simulated alerts are tagged as manual_test and do not mark an app as Shortcuts-verified.")
            }

            Section("Recent Intent Executions") {
                if viewModel.executionLogs.isEmpty {
                    Text("No intent invocations recorded yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.executionLogs.prefix(20)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.appLabel)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(entry.outcome.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(outcomeColor(entry.outcome).opacity(0.16)))
                                    .foregroundStyle(outcomeColor(entry.outcome))
                            }
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear Phase 1 telemetry store?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                viewModel.clearAllNotifications()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func outcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "captured": NotifdexTheme.celadon
        case "duplicate": NotifdexTheme.prussian
        case "skipped": NotifdexTheme.sienna
        case "failed": NotifdexTheme.vermilion
        default: NotifdexTheme.mineral
        }
    }
}
