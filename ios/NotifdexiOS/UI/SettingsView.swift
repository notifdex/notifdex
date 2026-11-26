import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section("Capture Status") {
                    LabeledContent("Mode") {
                        Text(viewModel.settings.paused ? "Paused" : "Listening for Shortcuts")
                            .foregroundStyle(viewModel.settings.paused ? NotifdexTheme.sienna : NotifdexTheme.celadon)
                            .fontWeight(.semibold)
                    }
                    LabeledContent("Captured Alerts", value: "\(viewModel.stats.totalCount)")
                    LabeledContent("Verified Apps", value: "\(viewModel.settings.verifiedAppLabels.count)")
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
                        Label("Clear Captured Notifications", systemImage: "trash")
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
            .navigationTitle("Settings")
            .confirmationDialog(
                "Clear all captured notifications on this iPhone?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    viewModel.clearAllNotifications()
                }
                Button("Cancel", role: .cancel) {}
            }
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
