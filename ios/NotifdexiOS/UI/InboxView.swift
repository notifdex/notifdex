import SwiftUI

struct InboxView: View {
    @ObservedObject var viewModel: AppViewModel
    let onOpenCapture: () -> Void
    @State private var inspectedNotification: CapturedNotification?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !viewModel.availableAppsInInbox.isEmpty {
                    filterBar
                }

                if viewModel.notifications.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.notifications) { item in
                            Button {
                                inspectedNotification = item
                            } label: {
                                NotificationRowView(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        viewModel.reload()
                    }
                }
            }
            .navigationTitle("Inbox")
            .searchable(text: $viewModel.searchText, prompt: "Search app, title, or message")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.settings.paused {
                        Label("Paused", systemImage: "pause.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NotifdexTheme.sienna)
                    } else {
                        Button {
                            viewModel.reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh Inbox")
                    }
                }
            }
            .sheet(item: $inspectedNotification) { item in
                NotificationDetailSheet(item: item)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "All",
                    count: viewModel.stats.totalCount,
                    color: NotifdexTheme.prussian,
                    isSelected: viewModel.selectedAppFilter == nil
                ) {
                    viewModel.selectedAppFilter = nil
                }

                ForEach(viewModel.availableAppsInInbox, id: \.self) { app in
                    FilterChip(
                        title: app,
                        count: viewModel.stats.countByApp[app] ?? 0,
                        color: NotifdexTheme.color(for: app),
                        isSelected: viewModel.selectedAppFilter?.caseInsensitiveCompare(app) == .orderedSame
                    ) {
                        if viewModel.selectedAppFilter?.caseInsensitiveCompare(app) == .orderedSame {
                            viewModel.selectedAppFilter = nil
                        } else {
                            viewModel.selectedAppFilter = app
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                viewModel.searchText.isEmpty && viewModel.selectedAppFilter == nil
                    ? "No Captured Notifications"
                    : "No Matching Alerts",
                systemImage: "tray"
            )
        } description: {
            if viewModel.searchText.isEmpty && viewModel.selectedAppFilter == nil {
                Text("Connect an iOS 27 Shortcuts Notification automation for X, Gmail, or WeChat to capture alerts directly into Notifdex.")
            } else {
                Text("Try clearing your app filter or search text.")
            }
        } actions: {
            if viewModel.searchText.isEmpty && viewModel.selectedAppFilter == nil {
                Button("Set Up Capture") {
                    onOpenCapture()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Clear Filters") {
                    viewModel.selectedAppFilter = nil
                    viewModel.searchText = ""
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? NotifdexTheme.prussian : Color(.secondarySystemBackground))
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

private struct NotificationRowView: View {
    let item: CapturedNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(NotifdexTheme.color(for: item.appLabel).opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: NotifdexTheme.symbol(for: item.appLabel))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NotifdexTheme.color(for: item.appLabel))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.appLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NotifdexTheme.color(for: item.appLabel))

                    if item.captureChannel == .manualTest {
                        Text("TEST")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(NotifdexTheme.sienna.opacity(0.18)))
                            .foregroundStyle(NotifdexTheme.sienna)
                    }

                    Spacer()

                    Text(item.capturedDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !item.subtitle.isEmpty && item.subtitle != item.displayTitle {
                    Text(item.subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(item.displayPreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NotificationDetailSheet: View {
    let item: CapturedNotification
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Notification") {
                    LabeledContent("App", value: item.appLabel)
                    LabeledContent("Title", value: item.title.isEmpty ? "—" : item.title)
                    LabeledContent("Subtitle", value: item.subtitle.isEmpty ? "—" : item.subtitle)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Body")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.body.isEmpty ? "No message body exposed." : item.body)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }

                Section("Provenance & Identity") {
                    LabeledContent("Captured", value: item.capturedDate.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Origin", value: item.origin.displayLabel)
                    LabeledContent("Channel", value: item.captureChannel.displayLabel)
                    LabeledContent("Source ID", value: item.sourceID)
                    LabeledContent("Capture UUID", value: item.captureUUID)
                    LabeledContent("Dedup Key") {
                        Text(String(item.sourceEventID.prefix(16)) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if item.metadataJSON != "{}" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Metadata")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.metadataJSON)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(item.appLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
