import NotifdexCore
import SwiftUI

struct InboxView: View {
    @ObservedObject var viewModel: AppViewModel
    let onOpenCapture: () -> Void
    @State private var inspectedItem: HybridInboxItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scopePicker
                if !viewModel.availableAppsInInbox.isEmpty {
                    filterBar
                }
                if let lastHide = viewModel.lastHideAction {
                    HStack(spacing: 10) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.secondary)
                        Text(lastHide.bannerText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") {
                            viewModel.undoLastHide()
                        }
                        .font(.caption.weight(.semibold))
                        Button {
                            viewModel.lastHideAction = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                }

                if viewModel.hybridItems.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.hybridItems) { item in
                            Button {
                                inspectedItem = item
                            } label: {
                                HybridInboxRowView(item: item)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    viewModel.toggleRead(item.primary)
                                } label: {
                                    Label(item.primary.isRead ? "Unread" : "Read",
                                          systemImage: item.primary.isRead ? "envelope.badge" : "envelope.open")
                                }
                                .tint(NotifdexTheme.prussian)

                                Button {
                                    viewModel.toggleFlag(item.primary)
                                } label: {
                                    Label(item.primary.isFlagged ? "Unflag" : "Flag",
                                          systemImage: item.primary.isFlagged ? "flag.slash" : "flag.fill")
                                }
                                .tint(NotifdexTheme.sienna)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if viewModel.inboxFilter == .hidden {
                                    Button {
                                        viewModel.restoreAlert(item.primary)
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(NotifdexTheme.celadon)
                                } else {
                                    Button(role: .destructive) {
                                        viewModel.hideAlert(item.primary)
                                    } label: {
                                        Label("Hide", systemImage: "eye.slash")
                                    }
                                }
                                Button {
                                    viewModel.toggleSaved(item.primary)
                                } label: {
                                    Label(item.primary.saved ? "Unsave" : "Save",
                                          systemImage: item.primary.saved ? "bookmark.slash" : "bookmark.fill")
                                }
                                .tint(NotifdexTheme.celadon)
                            }
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
                if !viewModel.hideRules.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(viewModel.hideRules) { rule in
                                Button(role: .destructive) {
                                    viewModel.removeHideRule(rule.match)
                                } label: {
                                    Label(
                                        "Remove \(rule.match.app) · \(rule.match.field.rawValue): \(rule.match.text)",
                                        systemImage: "trash"
                                    )
                                }
                            }
                        } label: {
                            Label("Rules (\(viewModel.hideRules.count))", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
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
            .sheet(item: $inspectedItem) { item in
                HybridNotificationDetailSheet(item: item, viewModel: viewModel)
            }
        }
    }

    private var scopePicker: some View {
        Picker("Filter", selection: $viewModel.inboxFilter) {
            ForEach(InboxTabFilter.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "All",
                    count: viewModel.coreAppCounts.values.reduce(0, +),
                    color: NotifdexTheme.prussian,
                    isSelected: viewModel.selectedAppFilter == nil
                ) {
                    viewModel.selectedAppFilter = nil
                }

                ForEach(viewModel.availableAppsInInbox, id: \.self) { app in
                    FilterChip(
                        title: app,
                        count: viewModel.coreAppCounts[app] ?? 0,
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
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                viewModel.searchText.isEmpty && viewModel.selectedAppFilter == nil && viewModel.inboxFilter == .all
                    ? "No Captured Notifications"
                    : "No Matching Alerts",
                systemImage: "tray"
            )
        } description: {
            if viewModel.searchText.isEmpty && viewModel.selectedAppFilter == nil && viewModel.inboxFilter == .all {
                Text("Connect an iOS 27 Shortcuts Notification automation or pair iCloud Sync with your Mac to view alerts here.")
            } else {
                Text("Try switching scopes or clearing your search filter.")
            }
        } actions: {
            if viewModel.inboxFilter == .all && viewModel.searchText.isEmpty && viewModel.selectedAppFilter == nil {
                Button("Set Up Capture & Sync") {
                    onOpenCapture()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Reset Filters") {
                    viewModel.inboxFilter = .all
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

private struct HybridInboxRowView: View {
    let item: HybridInboxItem

    var body: some View {
        let entry = item.primary
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(NotifdexTheme.color(for: entry.app).opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: NotifdexTheme.symbol(for: entry.app))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NotifdexTheme.color(for: entry.app))
                    .frame(width: 38, height: 38)
                if !entry.isRead {
                    Circle()
                        .fill(NotifdexTheme.prussian)
                        .frame(width: 9, height: 9)
                        .offset(x: 2, y: -2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.app)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NotifdexTheme.color(for: entry.app))

                    ForEach(item.provenanceBadges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(.secondarySystemFill)))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if entry.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(NotifdexTheme.sienna)
                    }
                    if entry.saved {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(NotifdexTheme.celadon)
                    }

                    Text(Date(timeIntervalSince1970: entry.capturedAt), style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(entry.title.isEmpty ? entry.app : entry.title)
                    .font(.subheadline.weight(entry.isRead ? .regular : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(entry.body.isEmpty ? "No message body exposed" : entry.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if !entry.personName.isEmpty || entry.dueAt != nil {
                    HStack(spacing: 8) {
                        if !entry.personName.isEmpty {
                            Label(entry.personName, systemImage: "person.fill")
                                .font(.caption2)
                                .foregroundStyle(NotifdexTheme.prussian)
                        }
                        if let dueAt = entry.dueAt, !entry.done {
                            Label(Date(timeIntervalSince1970: dueAt).formatted(date: .abbreviated, time: .shortened),
                                  systemImage: "calendar.badge.clock")
                                .font(.caption2)
                                .foregroundStyle(NotifdexTheme.sienna)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HybridNotificationDetailSheet: View {
    let item: HybridInboxItem
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewPerson = false
    @State private var newPersonName = ""
    @State private var followUpDate = Calendar.current.date(byAdding: .hour, value: 4, to: Date()) ?? Date()

    private var entry: InboxEntry {
        viewModel.hybridItems.first(where: { $0.id == item.id })?.primary ?? item.primary
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Notification") {
                    LabeledContent("App", value: entry.app)
                    LabeledContent("Title", value: entry.title.isEmpty ? "—" : entry.title)
                    if !entry.subtitle.isEmpty {
                        LabeledContent("Subtitle", value: entry.subtitle)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Body")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.body.isEmpty ? "No message body exposed." : entry.body)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }

                Section("Workflow Actions") {
                    Button {
                        viewModel.toggleRead(entry)
                    } label: {
                        Label(entry.isRead ? "Mark Unread" : "Mark Read",
                              systemImage: entry.isRead ? "envelope.badge" : "envelope.open")
                    }

                    Button {
                        viewModel.toggleFlag(entry)
                    } label: {
                        Label(entry.isFlagged ? "Remove Flag" : "Flag Alert",
                              systemImage: entry.isFlagged ? "flag.slash" : "flag.fill")
                    }

                    Button {
                        viewModel.toggleSaved(entry)
                    } label: {
                        Label(entry.saved ? "Remove from Saved" : "Save Alert",
                              systemImage: entry.saved ? "bookmark.slash" : "bookmark.fill")
                    }

                    DatePicker("Follow-up", selection: $followUpDate, displayedComponents: [.date, .hourAndMinute])
                    Button {
                        viewModel.scheduleFollowUp(entry, dueDate: followUpDate)
                    } label: {
                        Label("Schedule Follow-up", systemImage: "calendar.badge.plus")
                    }

                    if viewModel.inboxFilter == .hidden {
                        Button {
                            viewModel.restoreAlert(entry)
                            dismiss()
                        } label: {
                            Label("Restore Alert", systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button(role: .destructive) {
                            viewModel.hideAlert(entry)
                            dismiss()
                        } label: {
                            Label("Hide Alert", systemImage: "eye.slash")
                        }

                        if entry.app != "Unknown app" {
                            if !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button(role: .destructive) {
                                    viewModel.addHideRule(app: entry.app, field: .title, text: entry.title)
                                    dismiss()
                                } label: {
                                    Label("Hide All with This Title", systemImage: "eye.slash.fill")
                                }
                            }
                            if !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button(role: .destructive) {
                                    viewModel.addHideRule(app: entry.app, field: .body, text: entry.body)
                                    dismiss()
                                } label: {
                                    Label("Hide All with This Body", systemImage: "eye.slash.fill")
                                }
                            }
                        }
                    }
                }

                Section("Person") {
                    if !entry.personName.isEmpty {
                        LabeledContent("Linked To", value: entry.personName)
                        Button(role: .destructive) {
                            viewModel.link(entry.id, to: nil)
                        } label: {
                            Label("Unlink Person", systemImage: "person.badge.minus")
                        }
                    } else {
                        if !viewModel.people.isEmpty {
                            Menu {
                                ForEach(viewModel.people) { person in
                                    Button(person.name) {
                                        viewModel.link(entry.id, to: person.id)
                                    }
                                }
                            } label: {
                                Label("Link to Existing Person", systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                        Button {
                            newPersonName = entry.title
                            showingNewPerson = true
                        } label: {
                            Label("Create & Link Person", systemImage: "person.badge.plus")
                        }
                    }
                }

                Section("Provenance") {
                    LabeledContent("Captured", value: Date(timeIntervalSince1970: entry.capturedAt).formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Sources", value: item.provenanceBadges.joined(separator: " · "))
                    LabeledContent("Observations", value: "\(item.observationIDs.count)")
                }
            }
            .navigationTitle(entry.app)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Create Person", isPresented: $showingNewPerson) {
                TextField("Display Name", text: $newPersonName)
                Button("Create & Link") {
                    viewModel.createPerson(name: newPersonName, linking: entry.id)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
