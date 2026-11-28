#if os(macOS)
import NotifdexCore
import SwiftUI

@MainActor
struct StorageManagementView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage & Cleanup")
                        .font(.system(size: 16, weight: .regular, design: .serif))
                    Text("Review local database space and safely clear older notifications while keeping people, notes, workspaces, and hide rules.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button(model.storageBusy ? "Calculating…" : "Refresh") {
                    model.refreshStorageUsage()
                }
                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                .disabled(model.storageBusy || !model.state.ready)
            }

            if let report = model.storageReport {
                LabeledContent("Total storage used") {
                    Text(report.formattedTotalSize)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                LabeledContent("Stored notifications") {
                    Text("\(report.observationCount.formatted()) (\(report.protectedObservationCount.formatted()) saved, flagged, follow-up, or linked)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("History range") {
                    Text(historyRangeText(oldest: report.oldestObservationAt, newest: report.newestObservationAt))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last calculated") {
                    Text(Date(timeIntervalSince1970: report.calculatedAt), style: .relative)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Storage breakdown", isExpanded: $model.showingStorageBreakdown) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Notification content & payloads") {
                            Text(report.formattedContentAndPayloads).foregroundStyle(.secondary).monospacedDigit()
                        }
                        LabeledContent("Records & metadata") {
                            Text(report.formattedRecordsAndMetadata).foregroundStyle(.secondary).monospacedDigit()
                        }
                        LabeledContent("Media & attachments") {
                            Text(report.formattedAttachmentsAndMedia).foregroundStyle(.secondary).monospacedDigit()
                        }
                        LabeledContent("Indexes & database overhead") {
                            Text(report.formattedIndexesAndOverhead).foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack {
                            Text("Includes SQLite WAL/SHM sidecars (\(StorageUsageReport.formatBytes(report.walBytes + report.shmBytes))) and \(report.formattedFreelistSize) reclaimable pages.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Compact database") {
                                model.compactStorageDatabase()
                            }
                            .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                            .disabled(model.storageBusy || !model.state.ready)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 6)
                }
                .font(.callout)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Picker("Remove notifications", selection: Binding(
                            get: { model.selectedCleanupPeriod },
                            set: { newPeriod in
                                model.selectedCleanupPeriod = newPeriod
                                model.refreshStoragePreview(for: newPeriod)
                            }
                        )) {
                            ForEach(StorageCleanupPeriod.ageRetentionOptions) { period in
                                Text(period.title).tag(period)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(model.storageBusy)

                        Spacer()

                        Button("Review & Clean Up…") {
                            model.requestCleanupConfirmation(for: model.selectedCleanupPeriod)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        .disabled(
                            model.storageBusy
                                || !model.state.ready
                                || (model.storagePreview?.removableObservationCount ?? 0) == 0
                        )
                    }

                    if let preview = model.storagePreview {
                        Text(previewSummaryText(preview))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Button("Clear all notification history…", role: .destructive) {
                            model.requestCleanupConfirmation(for: .allHistory)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                        .disabled(model.storageBusy || !model.state.ready || report.observationCount == 0)
                        Spacer()
                    }
                    .padding(.top, 2)
                }
                .padding(12)
                .notifdexSurface(.card)
            } else {
                Text(model.storageBusy ? "Calculating local storage usage…" : "Storage usage will appear once the database is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = model.storageResultMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.storageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .sheet(item: Binding(
            get: { model.confirmingStorageCleanup },
            set: { model.confirmingStorageCleanup = $0 }
        )) { preview in
            cleanupConfirmationSheet(preview)
        }
    }

    private func cleanupConfirmationSheet(_ preview: StorageCleanupPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(preview.period.isClearAll
                 ? "Clear all notification history?"
                 : "Clean up notifications \(preview.period.title.lowercased())?")
                .font(.title2)

            if preview.period.isClearAll {
                Text("This permanently deletes all \(preview.removableObservationCount.formatted()) stored notifications from this Mac, including saved, flagged, follow-up, and linked alerts. This action cannot be undone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This permanently deletes \(preview.removableObservationCount.formatted()) older notifications and compacts the local database.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Notifications to remove", value: preview.removableObservationCount.formatted())
                if !preview.period.isClearAll && preview.preservedObservationCount > 0 {
                    LabeledContent("Protected alerts kept", value: "\(preview.preservedObservationCount.formatted()) (saved, flagged, follow-up, or linked)")
                }
                LabeledContent("Estimated space reclaimed", value: preview.formattedEstimatedReclaim)
                LabeledContent("User data preserved", value: preservedUserDataText(preview))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            Text("People, notes, workspaces, and hide rules are always preserved. Cleaning up this Mac does not delete history stored on your paired iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") {
                    model.confirmingStorageCleanup = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(preview.period.isClearAll ? "Clear All History" : "Delete & Reclaim Space", role: .destructive) {
                    let period = preview.period
                    model.confirmingStorageCleanup = nil
                    model.executeStorageCleanup(period)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.storageBusy)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func historyRangeText(oldest: Double?, newest: Double?) -> String {
        guard let oldest, let newest else { return "No notifications stored" }
        let start = Date(timeIntervalSince1970: oldest).formatted(date: .abbreviated, time: .omitted)
        let end = Date(timeIntervalSince1970: newest).formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) – \(end)"
    }

    private func previewSummaryText(_ preview: StorageCleanupPreview) -> String {
        if preview.removableObservationCount == 0 {
            if preview.preservedObservationCount > 0 {
                return "No disposable alerts \(preview.period.title.lowercased()). \(preview.preservedObservationCount) older protected alert(s) are preserved."
            }
            return "No notifications found \(preview.period.title.lowercased())."
        }
        var parts = [
            "\(preview.removableObservationCount.formatted()) alert(s) eligible for removal",
            "estimated ~\(preview.formattedEstimatedReclaim) reclaimed"
        ]
        if preview.preservedObservationCount > 0 {
            parts.append("\(preview.preservedObservationCount.formatted()) saved/flagged/follow-up/linked alert(s) kept")
        }
        return parts.joined(separator: " · ") + "."
    }

    private func preservedUserDataText(_ preview: StorageCleanupPreview) -> String {
        "\(preview.preservedPeopleCount) people · \(preview.preservedNotesCount) notes · \(preview.preservedWorkspacesCount) workspaces · \(preview.preservedHideRulesCount) rules"
    }
}

extension StorageCleanupPreview: Identifiable {
    public var id: String { "\(period.rawValue)-\(removableObservationCount)-\(estimatedReclaimableBytes)" }
}
#endif
