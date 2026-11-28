import NotifdexCore
import SwiftUI

struct StorageManagementView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var pendingConfirmation: StorageCleanupPreview?
    @State private var showBreakdown = false

    var body: some View {
        List {
            Section {
                if let report = viewModel.storageReport {
                    LabeledContent("Total Storage Used") {
                        Text(report.formattedTotalSize)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    LabeledContent("Stored Notifications") {
                        Text(report.observationCount.formatted())
                            .monospacedDigit()
                    }
                    if report.protectedObservationCount > 0 {
                        LabeledContent("Protected Alerts") {
                            Text("\(report.protectedObservationCount.formatted()) saved, flagged, follow-up, or linked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("History Range", value: historyRangeText(oldest: report.oldestObservationAt, newest: report.newestObservationAt))
                    LabeledContent("Last Calculated") {
                        Text(Date(timeIntervalSince1970: report.calculatedAt), style: .relative)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("Calculating storage usage…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView()
                    }
                }

                Button {
                    viewModel.refreshStorageUsage()
                } label: {
                    HStack {
                        Label("Refresh Storage Usage", systemImage: "arrow.clockwise")
                        if viewModel.storageBusy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.storageBusy)
            } header: {
                Text("Overview")
            }

            if let report = viewModel.storageReport {
                Section("Storage Breakdown") {
                    DisclosureGroup("View Categories", isExpanded: $showBreakdown) {
                        LabeledContent("Notification Content & Payloads", value: report.formattedContentAndPayloads)
                        LabeledContent("Records & Metadata", value: report.formattedRecordsAndMetadata)
                        LabeledContent("Media & Attachments", value: report.formattedAttachmentsAndMedia)
                        LabeledContent("Indexes & Database Overhead", value: report.formattedIndexesAndOverhead)
                        LabeledContent("SQLite WAL / SHM Sidecars", value: StorageUsageReport.formatBytes(report.walBytes + report.shmBytes))
                        if report.auxiliaryDatabaseBytes > 0 {
                            LabeledContent("Shortcuts Telemetry Store", value: StorageUsageReport.formatBytes(report.auxiliaryDatabaseBytes))
                        }
                    }

                    Button {
                        viewModel.compactStorageDatabase()
                    } label: {
                        Label("Compact Database", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(viewModel.storageBusy)
                }
            }

            Section {
                Picker("Remove Notifications", selection: Binding(
                    get: { viewModel.selectedCleanupPeriod },
                    set: { period in
                        viewModel.selectedCleanupPeriod = period
                        viewModel.refreshStoragePreview(for: period)
                    }
                )) {
                    ForEach(StorageCleanupPeriod.ageRetentionOptions) { period in
                        Text(period.title).tag(period)
                    }
                }
                .disabled(viewModel.storageBusy)

                if let preview = viewModel.storagePreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(previewSummary(preview))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Preserves \(preview.preservedPeopleCount) people, \(preview.preservedNotesCount) notes, \(preview.preservedWorkspacesCount) workspaces, and \(preview.preservedHideRulesCount) hide rules.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)

                    Button(role: .destructive) {
                        pendingConfirmation = preview
                    } label: {
                        Label(
                            "Clean Up \(preview.period.title)…",
                            systemImage: "trash"
                        )
                    }
                    .disabled(viewModel.storageBusy || preview.removableObservationCount == 0)
                }
            } header: {
                Text("Clean Up Older History")
            } footer: {
                Text("Age-based cleanup removes disposable older notifications and compacts SQLite to reclaim space. Saved, flagged, follow-up, and person-linked alerts are preserved.")
            }

            Section {
                Button(role: .destructive) {
                    viewModel.prepareClearAllPreview { preview in
                        pendingConfirmation = preview
                    }
                } label: {
                    Label("Clear All Notification History…", systemImage: "exclamationmark.triangle")
                }
                .disabled(viewModel.storageBusy || (viewModel.storageReport?.observationCount ?? 0) == 0)
            } header: {
                Text("Clear All History")
            } footer: {
                Text("Permanently removes all stored notifications from this iPhone. People, notes, workspaces, and hide rules are preserved, and your paired Mac keeps its own history.")
            }

            if let message = viewModel.storageResultMessage {
                Section("Last Maintenance") {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Storage & Cleanup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.refreshStorageUsage()
        }
        .confirmationDialog(
            pendingConfirmation?.period.isClearAll == true
                ? "Clear all notification history?"
                : "Remove older notifications?",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let preview = pendingConfirmation {
                Button(
                    preview.period.isClearAll
                        ? "Clear All (\(preview.removableObservationCount) Alerts)"
                        : "Delete \(preview.removableObservationCount) Alerts (Est. \(preview.formattedEstimatedReclaim))",
                    role: .destructive
                ) {
                    let period = preview.period
                    pendingConfirmation = nil
                    viewModel.executeStorageCleanup(period)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingConfirmation = nil
            }
        } message: {
            if let preview = pendingConfirmation {
                if preview.period.isClearAll {
                    Text("This permanently deletes all \(preview.removableObservationCount) notifications from this iPhone (estimated \(preview.formattedEstimatedReclaim) reclaimed). People (\(preview.preservedPeopleCount)), notes (\(preview.preservedNotesCount)), workspaces (\(preview.preservedWorkspacesCount)), and hide rules (\(preview.preservedHideRulesCount)) stay safe.")
                } else {
                    Text("Deletes \(preview.removableObservationCount) alerts \(preview.period.title.lowercased()) (estimated \(preview.formattedEstimatedReclaim) reclaimed) and keeps \(preview.preservedObservationCount) protected alerts plus all people, notes, workspaces, and hide rules.")
                }
            }
        }
    }

    private func historyRangeText(oldest: Double?, newest: Double?) -> String {
        guard let oldest, let newest else { return "No notifications" }
        let start = Date(timeIntervalSince1970: oldest).formatted(date: .abbreviated, time: .omitted)
        let end = Date(timeIntervalSince1970: newest).formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) – \(end)"
    }

    private func previewSummary(_ preview: StorageCleanupPreview) -> String {
        if preview.removableObservationCount == 0 {
            if preview.preservedObservationCount > 0 {
                return "No disposable alerts \(preview.period.title.lowercased()). \(preview.preservedObservationCount) protected alert(s) will be kept."
            }
            return "No notifications found \(preview.period.title.lowercased())."
        }
        var text = "\(preview.removableObservationCount.formatted()) alert(s) to remove · Est. \(preview.formattedEstimatedReclaim) reclaimed"
        if preview.preservedObservationCount > 0 {
            text += " · \(preview.preservedObservationCount.formatted()) protected kept"
        }
        return text + "."
    }
}
