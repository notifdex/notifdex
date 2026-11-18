#if os(macOS)
import AppKit
import SwiftUI
import NotifdexCore
import NotifdexMac

private enum WorkflowMode: String, CaseIterable, Hashable, Identifiable {
    case inbox = "Inbox"
    case saved = "Saved"
    case people = "Rolodex"
    case today = "Today"
    case hidden = "Hidden"

    var id: String { rawValue }
}

private enum InboxHide: Equatable {
    case alert(Int64)
    case subject(app: String, text: String)

    var message: String {
        switch self {
        case .alert: return "Alert hidden."
        case .subject: return "Matching alerts hidden."
        }
    }

    func apply(to store: CaptureStore) throws {
        switch self {
        case .alert(let id): try store.hideAlert(id)
        case .subject(let app, let text): try store.hideSubject(app: app, subject: text)
        }
    }

    func remove(from store: CaptureStore) throws {
        switch self {
        case .alert(let id): try store.restoreAlert(id)
        case .subject(let app, let text): try store.restoreSubject(app: app, subject: text)
        }
    }
}

@MainActor
private final class WorkflowModel: ObservableObject {
    @Published var mode: WorkflowMode = .inbox
    @Published var app: String?
    @Published var search = ""
    @Published var person: String?
    @Published var selected: Int64?
    @Published var name = ""
    @Published var identityApp = "X"
    @Published var identifier = ""
    @Published var due = Date()
    @Published private(set) var limit = 50
    @Published private(set) var entries: [InboxEntry] = []
    @Published private(set) var rules: [InboxFilter] = []
    @Published private(set) var lastHide: InboxHide?
    @Published private(set) var loadedQuery: InboxQuery?
    @Published private(set) var people: [RolodexPerson] = []
    @Published private(set) var cardID: String?
    @Published private(set) var identities: [RolodexIdentity] = []
    @Published private(set) var timeline: [InboxEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    private let worker: CaptureWorker
    private var generation = 0

    init(worker: CaptureWorker) { self.worker = worker }

    var scope: InboxQuery.Scope {
        switch mode {
        case .inbox, .saved: return .inbox(app: app, saved: mode == .saved)
        case .hidden: return .hidden(app: app)
        case .people: return .person(person ?? "")
        case .today: return .followUps
        }
    }

    var query: InboxQuery { InboxQuery(scope: scope, search: search, limit: limit + 1) }
    var visibleEntries: [InboxEntry] {
        guard loadedQuery?.scope == scope, loadedQuery?.search == search else { return [] }
        return entries
    }

    var alert: InboxEntry? { visibleEntries.first { $0.id == selected } }

    func load(query: InboxQuery) {
        guard self.query == query else { return }
        generation += 1
        let request = generation
        let selected = selected
        let person = person
        worker.withStore({ store in
            let entries = try store.inbox(query)
            let alert = entries.first { $0.id == selected }
            let card = alert?.personID ?? (query.scope == .person(person ?? "") ? person : nil)
            let timeline = try card.map { try store.inbox(InboxQuery(scope: .person($0), limit: 12)) } ?? []
            let identities = try card.map { try store.identities(for: $0) } ?? []
            return (entries, try store.people(), card, identities, timeline, try store.inboxFilters())
        }, completion: { [weak self] result in
            guard let self, self.generation == request, self.query == query,
                  self.selected == selected else { return }
            switch result {
            case .success(let value):
                self.loadedQuery = query
                self.entries = value.0
                self.people = value.1
                self.cardID = value.2
                self.identities = value.3
                self.timeline = value.4
                self.rules = value.5
            case .failure(let error): self.error = String(describing: error)
            }
        })
    }

    func loadMore() { limit = min(1000, limit + 50) }

    func edit(_ operation: @escaping (CaptureStore) throws -> Void, then: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        error = nil
        worker.withStore(operation) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success:
                then?()
                self.load(query: self.query)
            case .failure(let error): self.error = String(describing: error)
            }
        }
    }

    func markOpened(_ alert: InboxEntry) {
        guard !alert.isRead else { return }
        worker.withStore({ try $0.setRead(alert.id, read: true) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.load(query: self.query)
            case .failure(let error): self.error = String(describing: error)
            }
        }
    }

    func open(_ alert: InboxEntry) {
        let workspace = NSWorkspace.shared
        if let url = InboxDestination.nativeURL(for: alert.app),
           workspace.urlForApplication(toOpen: url) != nil, workspace.open(url) { return }
        if let url = InboxDestination.webURL(for: alert.app), workspace.open(url) { return }
        error = "Could not open \(alert.app)."
    }

    func hide(_ action: InboxHide) {
        edit({ try action.apply(to: $0) }) { [weak self] in self?.lastHide = action }
    }

    func restore(_ action: InboxHide) {
        edit({ try action.remove(from: $0) }) { [weak self] in
            guard self?.lastHide == action else { return }
            self?.lastHide = nil
        }
    }

    func createPerson(linking id: Int64?) {
        let name = name
        edit({ store in _ = try store.createPerson(name: name, linking: id) }) { [weak self] in
            self?.name = ""
        }
    }

    func addIdentity(to person: String) {
        let platform = identityApp
        let identifier = identifier
        edit({ try $0.addIdentity(person: person, platform: platform, identifier: identifier) }) { [weak self] in
            self?.identifier = ""
        }
    }
}

@MainActor
struct WorkflowView: View {
    @StateObject private var model: WorkflowModel
    let ready: Bool
    let total: Int
    let apps: [String]

    init(worker: CaptureWorker, ready: Bool, total: Int, apps: [String]) {
        _model = StateObject(wrappedValue: WorkflowModel(worker: worker))
        self.ready = ready
        self.total = total
        self.apps = apps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("View", selection: $model.mode) {
                ForEach(WorkflowMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            filterBar
            if let action = model.lastHide {
                HStack {
                    Text(action.message).foregroundStyle(.secondary)
                    Button("Undo") { model.restore(action) }.disabled(!ready || model.busy)
                    Spacer()
                }
                .font(.callout)
            }
            if model.mode == .hidden && !model.rules.isEmpty { subjectRules }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                VStack(spacing: 6) {
                    if model.mode == .today {
                        Text("Open follow-ups · earliest due first")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    entryList
                    if model.visibleEntries.count > model.limit {
                        if model.limit < 1000 { Button("Show more") { model.loadMore() } }
                        else { Text("Refine search to see more results.").font(.caption) }
                    }
                }
                .frame(minWidth: 250)
                ScrollView { detail.padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minWidth: 280)
            }
        }
        .padding(.top, 10)
        .task(id: model.query) {
            let query = model.query
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            if ready { model.load(query: query) }
        }
        .onChange(of: ready) { _, visible in
            if visible { model.load(query: model.query) }
        }
        .onChange(of: total) { _, _ in
            if ready { model.load(query: model.query) }
        }
        .onChange(of: model.selected) { _, _ in
            model.name = ""
            model.identifier = ""
            let defaultDue = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
            model.due = model.alert?.dueAt.map { Date(timeIntervalSince1970: $0) } ?? defaultDue
            if ready {
                if let alert = model.alert, !alert.isRead { model.markOpened(alert) }
                else { model.load(query: model.query) }
            }
        }
        .onChange(of: model.mode) { _, _ in
            model.selected = nil
            model.search = ""
            model.identifier = ""
            model.name = ""
        }
    }

    private var filterBar: some View {
        HStack {
            if model.mode == .inbox || model.mode == .saved || model.mode == .hidden {
                let categories = Set(apps.map { $0 == "Twitter" ? "X" : ($0.isEmpty ? "Unknown app" : $0) }).sorted()
                Picker("App", selection: $model.app) {
                    Text("All apps").tag(nil as String?)
                    ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .fixedSize()
            }
            if model.mode == .people {
                Picker("Person", selection: $model.person) {
                    Text("Choose a person").tag(nil as String?)
                    ForEach(model.people) { person in Text(person.name).tag(Optional(person.id)) }
                }
                .onChange(of: model.person) { _, _ in
                    model.selected = nil
                    model.identifier = ""
                }
            }
            TextField("Search captured alerts", text: $model.search)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var entryList: some View {
        let rows = Array(model.visibleEntries.prefix(model.limit))
        let grouped = model.mode == .inbox || model.mode == .saved || model.mode == .hidden
        return List(selection: $model.selected) {
            if grouped {
                ForEach(Set(rows.map(\.app)).sorted(), id: \.self) { app in
                    Section(app) {
                        ForEach(rows.filter { $0.app == app }) { row in entryRow(row, showHide: model.mode == .inbox).tag(row.id) }
                    }
                }
            } else {
                ForEach(rows) { row in entryRow(row, showHide: model.mode == .inbox).tag(row.id) }
            }
        }
        .overlay {
            if rows.isEmpty {
                Text(ready ? "No matching alerts" : "Opening inbox…").foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func entryRow(_ entry: InboxEntry, showHide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !entry.isRead {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Unread")
                }
                Text(entry.title.isEmpty ? "Notification" : entry.title)
                    .font(.headline)
                    .fontWeight(entry.isRead ? .regular : .semibold)
                    .foregroundStyle(entry.isRead ? Color.secondary : Color.primary)
                Spacer()
                if entry.saved { Image(systemName: "bookmark.fill").accessibilityLabel("Saved") }
                if showHide { hideMenu(entry) }
            }
            if !entry.body.isEmpty {
                Text(entry.body).lineLimit(2)
                    .foregroundStyle(entry.isRead ? Color.secondary : Color.primary)
            }
            HStack(spacing: 8) {
                Text(entry.app)
                if model.mode == .today, let due = entry.dueAt {
                    Text(Date(timeIntervalSince1970: due).formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text(Date(timeIntervalSince1970: entry.capturedAt).formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func hideMenu(_ entry: InboxEntry) -> some View {
        Menu {
            Button("Hide this alert") { model.hide(.alert(entry.id)) }
            if !entry.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Hide all with this subject") {
                    model.hide(.subject(app: entry.app, text: entry.subject))
                }
                .help("Match this exact subject within \(entry.app)")
            }
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Hide this alert or all alerts with the same subject")
        .disabled(!ready || model.busy)
    }

    private var subjectRules: some View {
        Menu("Subject rules") {
            ForEach(model.rules) { rule in
                Button("Remove \(rule.app) · \(rule.subject)") {
                    model.restore(.subject(app: rule.app, text: rule.subject))
                }
            }
        }
        .disabled(!ready || model.busy)
        .help("Remove a rule to show matching alerts in the Inbox again")
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let alert = model.alert {
                alertDetail(alert)
                if let id = alert.personID {
                    Divider()
                    personCard(id: id, name: alert.personName)
                }
            } else if model.mode == .people {
                if let card = model.people.first(where: { $0.id == model.person }) {
                    personCard(id: card.id, name: card.name)
                } else {
                    Text("Choose a person or create a card.").foregroundStyle(.secondary)
                    newPerson(linking: nil)
                }
            } else {
                Text("Select an alert to see details.").foregroundStyle(.secondary)
            }
        }
        .disabled(!ready || model.busy)
    }

    private func alertDetail(_ alert: InboxEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(alert.title.isEmpty ? "Notification" : alert.title).font(.title2)
            Text(alert.app).font(.caption).foregroundStyle(.secondary)
            if !alert.subtitle.isEmpty { Text(alert.subtitle).textSelection(.enabled) }
            Text(alert.body.isEmpty ? "No preview was captured." : alert.body)
                .textSelection(.enabled)
            HStack {
                if InboxDestination.webURL(for: alert.app) != nil {
                    Button("Open in \(alert.app)") { model.open(alert) }
                        .help("Open the app or its inbox")
                }
                Button(alert.isRead ? "Mark unread" : "Mark read") {
                    model.edit { try $0.setRead(alert.id, read: !alert.isRead) }
                }
            }
            if model.mode == .hidden {
                if alert.individuallyHidden {
                    Button("Undo individual hide") { model.restore(.alert(alert.id)) }
                }
                if alert.filtered {
                    Button("Remove matching subject rule") {
                        model.restore(.subject(app: alert.app, text: alert.subject))
                    }
                }
            }
            Button(alert.saved ? "Remove from Saved" : "Save for later") {
                model.edit { try $0.setSaved(alert.id, saved: !alert.saved) }
            }
            Menu(alert.personID == nil ? "Link to person" : "Change linked person") {
                ForEach(model.people) { person in
                    Button(person.name) { model.edit { try $0.link(alert.id, to: person.id) } }
                }
                if alert.personID != nil {
                    Button("Unlink") { model.edit { try $0.link(alert.id, to: nil) } }
                }
            }
            .disabled(model.people.isEmpty && alert.personID == nil)
            if alert.personID == nil { newPerson(linking: alert.id) }
            Divider()
            Text("Follow-up").font(.headline)
            if alert.done {
                Label("Completed", systemImage: "checkmark.circle")
            } else if let due = alert.dueAt {
                Text("Due " + Date(timeIntervalSince1970: due).formatted(date: .abbreviated, time: .shortened))
            }
            DatePicker("Due", selection: $model.due)
            Button(alert.dueAt == nil ? "Add follow-up" : (alert.done ? "Reopen follow-up" : "Reschedule")) {
                let due = model.due.timeIntervalSince1970
                model.edit { try $0.schedule(alert.id, dueAt: due) }
            }
            if let due = alert.dueAt, !alert.done {
                HStack {
                    Button("Snooze a day") {
                        let date = max(Date(timeIntervalSince1970: due), .now)
                        let next = Calendar.current.date(byAdding: .day, value: 1, to: date)
                            ?? date.addingTimeInterval(86_400)
                        model.due = next
                        model.edit { try $0.schedule(alert.id, dueAt: next.timeIntervalSince1970) }
                    }
                    Button("Mark done") { model.edit { try $0.complete(alert.id) } }
                }
            }
        }
    }

    private func newPerson(linking id: Int64?) -> some View {
        HStack {
            TextField("New person name", text: $model.name)
            Button(id == nil ? "Create" : "Create and link") { model.createPerson(linking: id) }
                .disabled(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func personCard(id: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(name, systemImage: "person.crop.circle").font(.title3)
            ForEach(model.cardID == id ? model.identities : []) { identity in
                HStack {
                    Text("\(identity.platform) · \(identity.identifier)").textSelection(.enabled)
                    Spacer()
                    Button("Remove") { model.edit { try $0.removeIdentity(identity.id, person: id) } }
                }
            }
            HStack {
                Picker("App", selection: $model.identityApp) {
                    ForEach(["X", "Gmail", "LinkedIn", "WhatsApp", "Slack", "Discord"], id: \.self) { Text($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Handle or address", text: $model.identifier)
                Button("Add") { model.addIdentity(to: id) }
                    .disabled(model.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Recent activity").font(.headline)
            if model.cardID == id && model.timeline.isEmpty { Text("No linked alerts yet.").foregroundStyle(.secondary) }
            ForEach(model.cardID == id ? model.timeline : []) { entry in
                Divider()
                entryRow(entry)
            }
        }
    }
}
#endif
