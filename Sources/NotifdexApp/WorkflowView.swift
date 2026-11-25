#if os(macOS)
import AppKit
import SwiftUI
import NotifdexCore
import NotifdexMac

struct NoteDraft: Identifiable {
    let id = UUID()
    let personID: String?
    let personName: String?
    let noteID: String?
}

struct FolderDraft: Identifiable {
    let id = UUID()
    let folderID: String?
}

enum NoteCollection: String, CaseIterable, Identifiable {
    case mine = "My Notes"
    case people = "People Notes"

    var id: Self { self }
}

enum NoteFolderFilter: Hashable {
    case all
    case unfiled
    case folder(String)

    func includes(_ folderID: String?) -> Bool {
        switch self {
        case .all: true
        case .unfiled: folderID == nil
        case .folder(let id): folderID == id
        }
    }

    var folderID: String? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

struct TemplateRemoval {
    let personID: String
    let definition: RelationshipTemplate
}

enum WorkflowMode: String, CaseIterable, Hashable, Identifiable {
    case inbox = "Inbox"
    case today = "Today"
    case people = "People"
    case notes = "Notes"
    case docs = "Docs"
    case flagged = "Flagged"
    case saved = "Saved"
    case hidden = "Hidden"
    case apps = "Apps"
    case recovery = "Recovery"

    var id: String { rawValue }
    var hasTriageControls: Bool { self == .inbox || self == .flagged }
    var isUtility: Bool { self == .apps || self == .recovery }
    var isLibrary: Bool { self == .notes || self == .docs || isUtility }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .today: "calendar"
        case .people: "person.2"
        case .notes: "note.text"
        case .docs: "doc.text"
        case .flagged: "flag"
        case .saved: "bookmark"
        case .hidden: "eye.slash"
        case .apps: "square.grid.2x2"
        case .recovery: "arrow.clockwise"
        }
    }
}

struct HideRulePreview: Identifiable {
    let id = UUID()
    let match: InboxRuleMatch
    let count: Int
}

enum InboxHide: Equatable {
    case alert(Int64)
    case rule(InboxRuleMatch)

    var message: String {
        switch self {
        case .alert: return "Alert hidden."
        case .rule: return "Matching alerts hidden."
        }
    }

    func apply(to store: CaptureStore) throws {
        switch self {
        case .alert(let id): try store.hideAlert(id)
        case .rule(let match):
            guard try store.addHideRule(match) else {
                throw StoreError(description: "That hide rule already exists.")
            }
        }
    }

    func remove(from store: CaptureStore) throws {
        switch self {
        case .alert(let id): try store.restoreAlert(id)
        case .rule(let match): try store.removeHideRule(match)
        }
    }
}

@MainActor
final class WorkflowModel: ObservableObject {
    @Published var mode: WorkflowMode = .inbox
    @Published var app: String?
    @Published var search = ""
    @Published var inboxPresentation = InboxPresentation()
    @Published var readFilter: InboxQuery.ReadFilter = .all
    @Published var captureOrder: InboxQuery.Order = .newestFirst
    @Published var person: String?
    @Published var workspaceID: String?
    @Published var showingNewWorkspace = false
    @Published var workspaceName = ""
    @Published var selected: Int64?
    @Published var inboxDetailWidth: CGFloat?
    @Published var hoveredMode: WorkflowMode?
    @Published var hoveringDivider = false
    @Published var draggingDivider = false
    @Published var name = ""
    @Published var identityApp = "Messages"
    @Published var identifier = ""
    @Published var due = Date()
    @Published var matchPreview: PersonMatchPreview?
    @Published var hideRulePreview: HideRulePreview?
    @Published var noteDraft: NoteDraft?
    @Published var noteTitle = ""
    @Published var noteBody = ""
    @Published var noteFolderID: String?
    @Published var noteCollection: NoteCollection = .mine
    @Published var notebookFolder: NoteFolderFilter = .all
    @Published var notebookPersonID: String?
    @Published var folderDraft: FolderDraft?
    @Published var folderName = ""
    @Published var confirmingFolderDeletion = false
    @Published private(set) var noteFolders: [NoteFolder] = []
    @Published private(set) var personalNotes: [PersonalNote] = []
    @Published private(set) var notebookPeopleNotes: [PersonNote] = []
    @Published private var loadedNotebookPersonID: String?
    @Published var confirmingNoteDeletion = false
    @Published var templateRemoval: TemplateRemoval?
    @Published private(set) var notes: [PersonNote] = []
    @Published private(set) var templateAssignment: RelationshipTemplateAssignment?
    @Published private(set) var matchRules: [PersonMatchRule] = []
    @Published private(set) var limit = 50
    @Published private(set) var entries: [InboxEntry] = []
    @Published private(set) var rules: [InboxFilter] = []
    @Published private(set) var lastHide: InboxHide?
    @Published private(set) var loadedQuery: InboxQuery?
    @Published private var loadedAlert: InboxEntry?
    @Published private(set) var people: [PersonRecord] = []
    @Published private(set) var allIdentities: [String: [PersonIdentity]] = [:]
    @Published private(set) var inlineMatchPreview: PersonMatchPreview?
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published private(set) var personWorkspaceIDs: Set<String> = []
    @Published private var workspacePeople: [PersonRecord] = []
    @Published private(set) var cardID: String?
    @Published private(set) var identities: [PersonIdentity] = []
    @Published private(set) var timeline: [InboxEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var sheetError: String?
    @Published private(set) var popoverError: String?

    // Contact UX popover & inline edit state
    @Published var showingNewPersonPopover = false
    @Published var showingPeopleNewPersonPopover = false
    @Published var showingExistingPersonPopover = false
    @Published var showingContactCardPopover = false
    @Published var showingPeopleSwitcherPopover = false
    @Published var newPersonLinkingAlertID: Int64?
    @Published var newPersonWorkspaceID: String?
    @Published var newPersonPlatform = "Messages"
    @Published var newPersonHandle = ""
    @Published var newPersonRememberMatch = false
    @Published var personSearchQuery = ""
    @Published var showingAddHandleInline = false
    @Published var renamingPersonID: String?
    @Published var renamePersonDraft = ""
    @Published var personToDelete: PersonRecord?
    @Published var dismissedSuggestionAlertIDs: Set<Int64> = []
    @Published var dismissedRuleBannerAlertIDs: Set<Int64> = []
    @Published var dismissedHandleBannerAlertIDs: Set<Int64> = []

    private let worker: CaptureWorker
    private var generation = 0

    init(worker: CaptureWorker) { self.worker = worker }

    var scope: InboxQuery.Scope {
        switch mode {
        case .inbox, .saved: return .inbox(app: app, saved: mode == .saved)
        case .flagged: return .flagged(app: app)
        case .hidden: return .hidden(app: app)
        case .people: return .person(person ?? "")
        case .today: return .followUps
        case .notes, .docs, .apps, .recovery: return .person("")
        }
    }

    var query: InboxQuery {
        InboxQuery(scope: scope, search: search, limit: limit + 1,
                   readFilter: mode.hasTriageControls ? readFilter : .all,
                   order: mode.hasTriageControls ? captureOrder : .newestFirst,
                   workspaceID: mode == .people ? workspaceID : nil)
    }

    private var isCurrentQuery: Bool {
        guard var previous = loadedQuery else { return false }
        previous.limit = query.limit
        return previous == query
    }

    var visibleEntries: [InboxEntry] { isCurrentQuery ? entries : [] }

    var visiblePeople: [PersonRecord] {
        guard let workspaceID else { return people }
        return loadedQuery?.workspaceID == workspaceID ? workspacePeople : []
    }

    var alert: InboxEntry? {
        guard isCurrentQuery else { return nil }
        return entries.first { $0.id == selected } ?? (loadedAlert?.id == selected ? loadedAlert : nil)
    }

    func load(query: InboxQuery) {
        guard self.query == query else { return }
        generation += 1
        let request = generation
        guard mode != .docs && !mode.isUtility else { return }
        if mode == .notes {
            loadNotebook(request: request)
            return
        }
        let mode = self.mode
        let selected = selected
        let person = person
        let isPeople = mode == .people
        let keepsOpenDetail = mode.hasTriageControls
        worker.withStore({ store in
            let entries = try store.inbox(query)
            var alert = entries.first { $0.id == selected }
            if alert == nil, keepsOpenDetail, let selected {
                alert = try store.selectedInboxEntry(selected, in: query)
            }
            let allPeople = try store.people()
            let allIdentities = try store.allIdentitiesByPerson()
            let scopedPeople = try query.workspaceID.map { try store.people(in: $0) } ?? allPeople
            let visiblePerson = scopedPeople.first { $0.id == person }?.id
            let card = isPeople ? visiblePerson : alert?.personID
            let timeline = try (isPeople ? nil : card).map {
                try store.inbox(InboxQuery(scope: .person($0), limit: 12))
            } ?? []
            let identities = try card.map { try store.identities(for: $0) } ?? []
            let matches = try card.map { try store.personMatchRules(for: $0) } ?? []
            let notes = try card.map { try store.personNotes(for: $0) } ?? []
            let assignment = try (isPeople ? card : nil).flatMap { try store.templateAssignment(for: $0) }
            let membership = try card.map { try store.workspaceIDs(for: $0) } ?? []
            let inlineMatch: PersonMatchPreview? = {
                guard let alert, alert.personID != nil, alert.personRuleID == nil else { return nil }
                return try? store.previewPersonMatch(for: alert.id)
            }()
            let workspaceState = (options: try store.workspaces(), people: scopedPeople, memberships: membership)
            let contactExtras = (allIdentities: allIdentities, inlineMatch: inlineMatch)
            return (entries, allPeople, card, identities, timeline, try store.inboxFilters(),
                    matches, notes, alert, assignment, workspaceState, contactExtras)
        }, completion: { [weak self] result in
            guard let self, self.generation == request, self.mode == mode, self.query == query,
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
                self.matchRules = value.6
                self.notes = value.7
                self.loadedAlert = value.8
                self.templateAssignment = value.9
                self.workspaces = value.10.options
                self.workspacePeople = value.10.people
                self.personWorkspaceIDs = value.10.memberships
                self.allIdentities = value.11.allIdentities
                self.inlineMatchPreview = value.11.inlineMatch
                if isPeople, person != nil, value.2 == nil { self.person = nil }
                if isPeople, query.workspaceID != nil, selected != nil, value.8 == nil { self.selected = nil }
                if keepsOpenDetail, selected != nil, value.8 == nil { self.selected = nil }
            case .failure(let error): self.error = String(describing: error)
            }
        })
    }

    func toggleAppSection(_ app: String) {
        inboxPresentation.toggle(app)
        clearSelectionIfCollapsed()
    }

    func clearSelectionIfCollapsed() {
        guard mode.hasTriageControls, let app = alert?.app, !inboxPresentation.isExpanded(app) else { return }
        selected = nil
    }

    func loadMore() { limit = min(1000, limit + 50) }

    func edit(
        _ operation: @escaping (CaptureStore) throws -> Void,
        inSheet: Bool = false,
        inPopover: Bool = false,
        then: (() -> Void)? = nil
    ) {
        guard !busy else { return }
        busy = true
        if inSheet { sheetError = nil }
        else if inPopover { popoverError = nil }
        else { error = nil }
        worker.withStore(operation) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success:
                if inSheet { self.sheetError = nil }
                if inPopover { self.popoverError = nil }
                then?()
                self.load(query: self.query)
            case .failure(let error):
                if inSheet { self.sheetError = String(describing: error) }
                else if inPopover { self.popoverError = String(describing: error) }
                else { self.error = String(describing: error) }
            }
        }
    }

    func applyFounderOutreach(to person: String) {
        edit({ store in
            let definition = try store.installTemplate(RelationshipTemplate.bundledFounderOutreach())
            try store.applyTemplate(definition, to: person)
        }, then: { [weak self] in
            guard let self, self.mode == .people, self.person == person else { return }
            self.selected = nil
        })
    }

    func removeTemplate(_ removal: TemplateRemoval) {
        edit { try $0.removeTemplate(removal.definition, from: removal.personID) }
    }

    var displayedNotebookPeopleNotes: [PersonNote] {
        loadedNotebookPersonID == notebookPersonID ? notebookPeopleNotes : []
    }

    private func loadNotebook(request: Int) {
        let personID = notebookPersonID
        worker.withStore({ store in
            let notes = try personID.map { try store.personNotes(for: $0) } ?? []
            return (try store.noteFolders(), try store.personalNotes(), try store.people(), notes)
        }, completion: { [weak self] result in
            guard let self, self.generation == request, self.mode == .notes,
                  self.notebookPersonID == personID else { return }
            switch result {
            case .success(let snapshot):
                self.noteFolders = snapshot.0
                self.personalNotes = snapshot.1
                self.people = snapshot.2
                self.notebookPeopleNotes = snapshot.3.sorted {
                    if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                    return $0.updatedAt > $1.updatedAt
                }
                self.loadedNotebookPersonID = personID
                if let folderID = self.notebookFolder.folderID,
                   !snapshot.0.contains(where: { $0.id == folderID }) {
                    self.notebookFolder = .unfiled
                }
            case .failure(let error):
                self.error = String(describing: error)
            }
        })
    }

    func openNote(personID: String, name: String, note: PersonNote? = nil) {
        openNoteEditor(
            NoteDraft(personID: personID, personName: name, noteID: note?.id),
            title: note?.title ?? "", body: note?.body ?? "", folderID: nil
        )
    }

    func openPersonalNote(_ note: PersonalNote? = nil) {
        openNoteEditor(
            NoteDraft(personID: nil, personName: nil, noteID: note?.id),
            title: note?.title ?? "", body: note?.body ?? "",
            folderID: note == nil ? notebookFolder.folderID : note?.folderID
        )
    }

    private func openNoteEditor(_ draft: NoteDraft, title: String, body: String, folderID: String?) {
        sheetError = nil
        noteTitle = title
        noteBody = body
        noteFolderID = folderID
        confirmingNoteDeletion = false
        noteDraft = draft
    }

    func saveNote(_ draft: NoteDraft) {
        let title = noteTitle
        let body = noteBody
        let folderID = noteFolderID
        let time = Date().timeIntervalSince1970
        edit({ store in
            if let personID = draft.personID {
                if let id = draft.noteID {
                    try store.updatePersonNote(id, person: personID, title: title, body: body, at: time)
                } else {
                    try store.addPersonNote(person: personID, title: title, body: body, at: time)
                }
            } else {
                try store.savePersonalNote(draft.noteID, folderID: folderID, title: title, body: body, at: time)
            }
        }, inSheet: true, then: { [weak self] in self?.noteDraft = nil })
    }

    func deleteNote(_ draft: NoteDraft) {
        guard let id = draft.noteID else { return }
        edit({ store in
            if let personID = draft.personID {
                try store.deletePersonNote(id, person: personID)
            } else {
                try store.deletePersonalNote(id)
            }
        }, inSheet: true, then: { [weak self] in self?.noteDraft = nil })
    }

    func openFolderEditor(_ folder: NoteFolder? = nil) {
        sheetError = nil
        folderName = folder?.name ?? ""
        confirmingFolderDeletion = false
        folderDraft = FolderDraft(folderID: folder?.id)
    }

    func saveFolder(_ draft: FolderDraft) {
        let folderName = folderName
        edit({ store in
            try store.saveNoteFolder(draft.folderID, name: folderName)
        }, inSheet: true, then: { [weak self] in self?.folderDraft = nil })
    }

    func deleteFolder(_ draft: FolderDraft) {
        guard let id = draft.folderID else { return }
        edit({ try $0.deleteNoteFolder(id) }, inSheet: true, then: { [weak self] in
            self?.notebookFolder = .unfiled
            self?.folderDraft = nil
        })
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
        if let bundleID = InboxDestination.bundleIdentifier(for: alert.app),
           let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let appName = alert.app
            workspace.openApplication(at: appURL, configuration: configuration) { [weak self] _, openError in
                if openError != nil {
                    onAppMainLoop {
                        self?.error = "Could not open \(appName)."
                    }
                }
            }
            return
        }
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

    func reviewHideRule(_ match: InboxRuleMatch) {
        guard !busy else { return }
        busy = true
        error = nil
        worker.withStore({ try $0.previewHideRule(match) }) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let count): self.hideRulePreview = HideRulePreview(match: match, count: count)
            case .failure(let error): self.error = String(describing: error)
            }
        }
    }

    func reviewMatch(for alert: InboxEntry) {
        guard !busy else { return }
        busy = true
        error = nil
        worker.withStore({ try $0.previewPersonMatch(for: alert.id) }) { [weak self] result in
            guard let self else { return }
            self.busy = false
            guard self.alert?.id == alert.id else { return }
            switch result {
            case .success(let preview): self.matchPreview = preview
            case .failure(let error): self.error = String(describing: error)
            }
        }
    }

    func confirmMatch(_ preview: PersonMatchPreview, includeExisting: Bool) {
        matchPreview = nil
        edit { try $0.confirmPersonMatch(preview, includeExisting: includeExisting) }
    }

    func openWorkspaceEditor() {
        sheetError = nil
        workspaceName = ""
        showingNewWorkspace = true
    }

    func createWorkspace() {
        let name = workspaceName
        edit({ store in _ = try store.createWorkspace(name: name) }, inSheet: true) { [weak self] in
            self?.showingNewWorkspace = false
        }
    }

    func resetLimit() { limit = 50 }

    func createPerson(linking id: Int64?) {
        let name = name
        let workspace = mode == .people ? workspaceID : nil
        edit({ store in _ = try store.createPerson(name: name, linking: id, workspace: workspace) }) { [weak self] in
            self?.name = ""
        }
    }

    func closeContactPopovers() {
        showingNewPersonPopover = false
        showingPeopleNewPersonPopover = false
        showingExistingPersonPopover = false
        showingContactCardPopover = false
        showingPeopleSwitcherPopover = false
        popoverError = nil
    }

    func openNewPersonPopover(for alert: InboxEntry?, inPeopleBar: Bool = false) {
        closeContactPopovers()
        if let alert {
            newPersonLinkingAlertID = alert.id
            newPersonPlatform = ContactSuggestions.defaultPlatform(for: alert.app)
            let trimmedTitle = alert.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if ContactSuggestions.looksLikeIdentifier(trimmedTitle) {
                name = ""
                newPersonHandle = trimmedTitle
            } else {
                name = trimmedTitle
                newPersonHandle = ""
            }
            newPersonWorkspaceID = alert.workspaceID
            newPersonRememberMatch = alert.app != "Unknown app" && !trimmedTitle.isEmpty
        } else {
            newPersonLinkingAlertID = nil
            name = ""
            newPersonPlatform = "Messages"
            newPersonHandle = ""
            newPersonWorkspaceID = mode == .people ? workspaceID : nil
            newPersonRememberMatch = false
        }
        if inPeopleBar {
            showingPeopleNewPersonPopover = true
        } else {
            showingNewPersonPopover = true
        }
    }

    func openExistingPersonPopover(prefillQuery: String = "") {
        closeContactPopovers()
        personSearchQuery = prefillQuery
        showingExistingPersonPopover = true
    }

    func openContactCardPopover(for alert: InboxEntry) {
        closeContactPopovers()
        identityApp = ContactSuggestions.defaultPlatform(for: alert.app)
        identifier = ""
        showingAddHandleInline = false
        renamingPersonID = nil
        showingContactCardPopover = true
    }

    func openPeopleSwitcherPopover() {
        closeContactPopovers()
        personSearchQuery = ""
        showingPeopleSwitcherPopover = true
    }

    func submitNewPersonPopover() {
        let trimmedName = name
        let linkingID = newPersonLinkingAlertID
        let workspace = newPersonWorkspaceID
        let platform = newPersonPlatform
        let handle = newPersonHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        let remember = newPersonRememberMatch
        let isPeopleMode = mode == .people
        var createdPersonID: String?
        edit({ store in
            createdPersonID = try store.createPerson(
                name: trimmedName,
                linking: linkingID,
                workspace: workspace,
                identity: handle.isEmpty ? nil : (platform: platform, identifier: handle),
                rememberMatch: remember
            )
        }, inPopover: true) { [weak self] in
            guard let self else { return }
            self.name = ""
            self.newPersonHandle = ""
            self.closeContactPopovers()
            if isPeopleMode, let createdPersonID {
                self.person = createdPersonID
                self.selected = nil
            }
        }
    }

    func quickCreatePerson(named personName: String, linking alert: InboxEntry) {
        let trimmedTitle = alert.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity: (platform: String, identifier: String)? = ContactSuggestions.looksLikeIdentifier(trimmedTitle)
            ? (platform: ContactSuggestions.defaultPlatform(for: alert.app), identifier: trimmedTitle)
            : nil
        edit({ store in
            _ = try store.createPerson(
                name: personName,
                linking: alert.id,
                workspace: alert.workspaceID,
                identity: identity,
                rememberMatch: false
            )
        }, inPopover: true) { [weak self] in
            self?.closeContactPopovers()
        }
    }

    func linkAlert(_ alertID: Int64, to personID: String?) {
        edit({ try $0.link(alertID, to: personID) }) { [weak self] in
            self?.closeContactPopovers()
        }
    }

    func saveObservedHandle(for alert: InboxEntry, personID: String) {
        let platform = ContactSuggestions.defaultPlatform(for: alert.app)
        let handle = alert.title.trimmingCharacters(in: .whitespacesAndNewlines)
        edit({ try $0.addIdentity(person: personID, platform: platform, identifier: handle) }) { [weak self] in
            self?.dismissedHandleBannerAlertIDs.insert(alert.id)
        }
    }

    func startRename(personID: String, currentName: String) {
        renamingPersonID = personID
        renamePersonDraft = currentName
        popoverError = nil
    }

    func cancelRename() {
        renamingPersonID = nil
        renamePersonDraft = ""
    }

    func commitRename() {
        guard let personID = renamingPersonID else { return }
        let updatedName = renamePersonDraft
        let inPopover = showingContactCardPopover
        edit({ try $0.renamePerson(personID, to: updatedName) }, inPopover: inPopover) { [weak self] in
            self?.renamingPersonID = nil
            self?.renamePersonDraft = ""
        }
    }

    func confirmDeletePerson(_ record: PersonRecord) {
        edit({ try $0.deletePerson(record.id) }) { [weak self] in
            guard let self else { return }
            if self.person == record.id {
                self.person = nil
                self.selected = nil
            }
            self.personToDelete = nil
            self.closeContactPopovers()
        }
    }

    func jumpToPerson(_ id: String) {
        closeContactPopovers()
        workspaceID = nil
        person = id
        selected = nil
        mode = .people
    }

    func addIdentity(to person: String, collapseAfter: Bool = false) {
        let platform = identityApp
        let identifier = identifier
        let inPopover = showingContactCardPopover
        edit({ try $0.addIdentity(person: person, platform: platform, identifier: identifier) }, inPopover: inPopover) { [weak self] in
            self?.identifier = ""
            if collapseAfter { self?.showingAddHandleInline = false }
        }
    }
}

@MainActor
struct WorkflowView<AppsContent: View, RecoveryContent: View>: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var appearance: AppearanceSettings
    @StateObject private var model: WorkflowModel
    @GestureState private var detailDragOffset: CGFloat = 0
    @Environment(\.notifdexAppearanceConfig) private var appearanceConfig
    @Environment(\.colorScheme) private var colorScheme
    let worker: CaptureWorker
    let ready: Bool
    let total: Int
    let apps: [String]
    let appsView: () -> AppsContent
    let recoveryView: () -> RecoveryContent

    init(
        appModel: AppModel,
        appearance: AppearanceSettings,
        worker: CaptureWorker,
        ready: Bool,
        total: Int,
        apps: [String],
        @ViewBuilder appsView: @escaping () -> AppsContent,
        @ViewBuilder recoveryView: @escaping () -> RecoveryContent
    ) {
        self.appModel = appModel
        self.appearance = appearance
        _model = StateObject(wrappedValue: WorkflowModel(worker: worker))
        self.worker = worker
        self.ready = ready
        self.total = total
        self.apps = apps
        self.appsView = appsView
        self.recoveryView = recoveryView
    }

    private var themeTokens: ThemeTokens {
        ThemeTokens(theme: appearanceConfig.colorTheme, dark: colorScheme == .dark)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 860
            VStack(spacing: 0) {
                Rectangle()
                    .fill(themeTokens.hairline)
                    .frame(height: 0.5)
                HStack(alignment: .top, spacing: 0) {
                    if !compact {
                        sidebar
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        globalBanners
                        workflowHeader(compact: compact)
                        if model.mode == .notes {
                            notebook
                        } else if model.mode == .docs {
                            UserGuideView()
                        } else if model.mode == .apps {
                            appsView()
                        } else if model.mode == .recovery {
                            recoveryView()
                        } else if model.mode == .people {
                            if compact {
                                compactContent
                            } else {
                                HSplitView {
                                    feed.frame(minWidth: 250, idealWidth: 550)
                                    inspector(compact: false)
                                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 430)
                                }
                            }
                        } else if geometry.size.width < 700 {
                            compactContent
                        } else {
                            inboxSplit
                        }
                    }
                    .padding(.top, 14)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .sheet(item: $model.matchPreview) { preview in
            matchReview(preview)
        }
        .sheet(item: $model.hideRulePreview) { preview in
            hideRuleReview(preview)
        }
        .sheet(item: $model.noteDraft) { draft in
            NoteEditor(model: model, draft: draft)
        }
        .sheet(item: $model.folderDraft) { draft in
            FolderEditor(model: model, draft: draft)
        }
        .sheet(isPresented: $model.showingNewWorkspace) {
            workspaceEditor
        }
        .alert("Remove template?", isPresented: Binding(
            get: { model.templateRemoval != nil },
            set: { if !$0 { model.templateRemoval = nil } }
        ), presenting: model.templateRemoval) { removal in
            Button("Cancel", role: .cancel) {}
            Button("Remove template", role: .destructive) { model.removeTemplate(removal) }
        } message: { removal in
            Text("Removing \(removal.definition.name) clears this person's stage and milestones.")
        }
        .alert("Delete person?", isPresented: Binding(
            get: { model.personToDelete != nil },
            set: { if !$0 { model.personToDelete = nil } }
        ), presenting: model.personToDelete) { person in
            Button("Cancel", role: .cancel) {}
            Button("Delete person", role: .destructive) { model.confirmDeletePerson(person) }
        } message: { person in
            Text("Deleting \(person.name) removes their handles, matching rules, and person notes. Captured notifications stay in your inbox as unlinked alerts.")
        }
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
            model.closeContactPopovers()
            model.showingAddHandleInline = false
            model.cancelRename()
            if let alert = model.alert {
                model.identityApp = ContactSuggestions.defaultPlatform(for: alert.app)
            }
            let defaultDue = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
            model.due = model.alert?.dueAt.map { Date(timeIntervalSince1970: $0) } ?? defaultDue
            if ready {
                if let alert = model.alert, !alert.isRead { model.markOpened(alert) }
                else { model.load(query: model.query) }
            }
        }
        .onChange(of: showsInspector) { _, visible in
            if !visible { model.inboxDetailWidth = nil }
            if !visible {
                model.hoveringDivider = false
                model.draggingDivider = false
            }
        }
        .onChange(of: model.inboxPresentation.order) { _, _ in
            model.clearSelectionIfCollapsed()
        }
        .onChange(of: model.notebookPersonID) { _, _ in
            if ready, model.mode == .notes { model.load(query: model.query) }
        }
        .onChange(of: model.mode) { previous, next in
            model.selected = nil
            model.search = ""
            model.identifier = ""
            model.name = ""
            model.closeContactPopovers()
            model.showingAddHandleInline = false
            model.cancelRename()
            model.resetLimit()
            if ready, previous.isLibrary || next.isLibrary { model.load(query: model.query) }
        }
    }

    private var showsInspector: Bool {
        // Selection can outlive its visible row when opening an unread alert
        // or removing its flag. People also has a profile without an alert.
        model.mode == .people || model.selected != nil
    }

    @ViewBuilder private var globalBanners: some View {
        if let message = appModel.uiError ?? appModel.state.error {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .notifdexSurface(.card)
        }
        if !appModel.state.ready {
            HStack(spacing: 10) {
                Image(systemName: "bolt.slash")
                    .foregroundStyle(.orange)
                Text("Capture worker is not running.")
                    .font(.callout)
                Spacer()
                Button("Retry starting capture") { appModel.start() }
                    .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .notifdexSurface(.card)
        } else if !appModel.state.permissionGranted {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(themeTokens.accent)
                Text("Allow Notifdex in Privacy & Security → Accessibility.")
                    .font(.callout)
                Spacer()
                Button("Open Accessibility Settings") { appModel.permission() }
                    .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .notifdexSurface(.card)
        }
    }

    private var collectionIndicatorColor: Color {
        if !appModel.state.ready || !appModel.state.permissionGranted || appModel.state.error != nil {
            return Color(red: 0.84, green: 0.28, blue: 0.24)
        }
        if appModel.state.settings?.paused == true {
            return Color(red: 0.82, green: 0.56, blue: 0.24)
        }
        return Color(red: 0.34, green: 0.68, blue: 0.54)
    }

    private var compactCollectionTitle: String {
        if !appModel.state.ready { return "Offline" }
        if !appModel.state.permissionGranted { return "Needs access" }
        if appModel.state.settings?.paused == true { return "Paused" }
        if appModel.state.recovering { return "Recovering…" }
        return "Live"
    }

    private var collectionStatusPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(collectionIndicatorColor)
                    .frame(width: 7, height: 7)
                Text(appModel.state.status).font(.headline)
            }
            Text(appModel.state.lastScan)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("\(appModel.state.total) saved observations")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Paused", isOn: appModel.pauseBinding)
                .toggleStyle(.switch)
                .disabled(!appModel.state.ready || appModel.saving)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var sidebar: some View {
        let tokens = themeTokens
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(WorkflowMode.allCases) { mode in
                if mode == .flagged {
                    Spacer().frame(height: 14)
                }
                if mode == .apps {
                    Spacer(minLength: 16)
                    Rectangle()
                        .fill(tokens.hairline)
                        .frame(height: 0.5)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                sidebarNavButton(mode, tokens: tokens)
            }

            Rectangle()
                .fill(tokens.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            sidebarFooter
        }
        .padding(.top, 12)
        .frame(width: CGFloat(WindowChromeState.sidebarWidth))
        .frame(maxHeight: .infinity)
        .notifdexSurface(.sidebar)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button {
                let next = !appModel.showingCollectionStatus
                if next { appearance.showingStudio = false }
                appModel.showingCollectionStatus = next
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(collectionIndicatorColor)
                        .frame(width: 6, height: 6)
                    Text("\(compactCollectionTitle) · \(total)")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collection status and pause controls")
            .popover(isPresented: $appModel.showingCollectionStatus, arrowEdge: .trailing) {
                collectionStatusPopover
            }

            Spacer(minLength: 0)

            Button {
                let next = !appearance.showingStudio
                if next { appModel.showingCollectionStatus = false }
                appearance.showingStudio = next
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13.5, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Appearance & Settings")
            .help("Appearance, custom background & data folder")
            .popover(isPresented: $appearance.showingStudio, arrowEdge: .trailing) {
                AppearanceStudioView(appearance: appearance, dataDirectory: worker.directory)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func sidebarNavButton(_ mode: WorkflowMode, tokens: ThemeTokens) -> some View {
        let selected = model.mode == mode
        let hovered = model.hoveredMode == mode
        return Button {
            model.mode = mode
        } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(selected ? tokens.accent : Color.clear)
                    .frame(width: 2, height: 16)
                Image(systemName: mode.symbol)
                    .font(.system(size: 14, weight: selected ? .regular : .light))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(width: 18)
                Text(mode.rawValue)
                    .font(.system(size: CGFloat(WindowChromeState.sidebarLabelFontSize), weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer(minLength: 4)
                if mode == .apps && appModel.enabledAppCount > 0 {
                    Text("\(appModel.enabledAppCount)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else if mode == .recovery && appModel.state.recovering {
                    Circle()
                        .fill(tokens.accent)
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .background {
                if selected {
                    Rectangle().fill(tokens.selectionFill)
                } else if hovered {
                    Rectangle().fill(tokens.hoverFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.hoveredMode = mode }
            else if model.hoveredMode == mode { model.hoveredMode = nil }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func searchField(tokens: ThemeTokens) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .light))
                .foregroundStyle(.secondary)
            TextField("Search captured alerts", text: $model.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 5)
        .frame(minWidth: 130, maxWidth: 230)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(model.search.isEmpty ? tokens.hairline : tokens.hairlineStrong)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func workflowHeader(compact: Bool) -> some View {
        let tokens = themeTokens
        let showsHeaderContent = compact
            || !model.mode.isLibrary
            || model.lastHide != nil
            || (model.mode == .hidden && !model.rules.isEmpty)
            || model.error != nil
        if showsHeaderContent {
            VStack(alignment: .leading, spacing: 12) {
                if compact {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Picker("View", selection: $model.mode) {
                            ForEach(WorkflowMode.allCases) { mode in
                                Label(mode.rawValue, systemImage: mode.symbol).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        Spacer(minLength: 12)
                        if !model.mode.isLibrary {
                            searchField(tokens: tokens)
                        }
                        Button {
                            let next = !appModel.showingCollectionStatus
                            if next { appearance.showingStudio = false }
                            appModel.showingCollectionStatus = next
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(collectionIndicatorColor)
                                    .frame(width: 5.5, height: 5.5)
                                Text(compactCollectionTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .help("Collection status and pause controls")
                        .popover(isPresented: $appModel.showingCollectionStatus, arrowEdge: .bottom) {
                            collectionStatusPopover
                        }

                        Button {
                            let next = !appearance.showingStudio
                            if next { appModel.showingCollectionStatus = false }
                            appearance.showingStudio = next
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 12, weight: .light))
                                .foregroundStyle(.secondary)
                                .padding(5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Appearance & Settings")
                        .help("Appearance, custom background & data folder")
                        .popover(isPresented: $appearance.showingStudio, arrowEdge: .bottom) {
                            AppearanceStudioView(appearance: appearance, dataDirectory: worker.directory)
                        }
                    }
                }
                if !model.mode.isLibrary { filterBar(includeSearch: !compact) }
                if let action = model.lastHide {
                    HStack {
                        Text(action.message).foregroundStyle(.secondary)
                        Button("Undo") { model.restore(action) }
                            .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                            .disabled(!ready || model.busy)
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                }
                if model.mode == .hidden && !model.rules.isEmpty { hideRules }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
    }

    private var inboxSplit: some View {
        GeometryReader { geometry in
            let minimumFeedWidth: CGFloat = 250
            let dividerWidth: CGFloat = 12
            let rawMaximum = min(640, geometry.size.width - minimumFeedWidth - dividerWidth)
            let maximumWidth = max(0, rawMaximum)
            let clamped = { (width: CGFloat) in min(maximumWidth, max(min(300, maximumWidth), width)) }
            let startWidth = clamped(model.inboxDetailWidth ?? maximumWidth)
            let width = clamped(startWidth - detailDragOffset)
            let dividerActive = model.hoveringDivider || model.draggingDivider

            HStack(spacing: 0) {
                feed.frame(minWidth: minimumFeedWidth, maxWidth: .infinity)
                if showsInspector {
                    ZStack {
                        Color.black.opacity(0.001)
                        Rectangle()
                            .fill(dividerActive ? themeTokens.accent.opacity(0.85) : themeTokens.hairline)
                            .frame(width: dividerActive ? 2 : 0.5)
                        if dividerActive {
                            Capsule(style: .continuous)
                                .fill(themeTokens.accent)
                                .frame(width: 4, height: 34)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: dividerActive)
                    .frame(width: 18)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background {
                        ResizeCursorArea { inside in
                            model.hoveringDivider = inside
                        }
                    }
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($detailDragOffset) { value, offset, _ in
                            offset = value.translation.width
                        }
                        .onChanged { _ in
                            if !model.draggingDivider { model.draggingDivider = true }
                        }
                        .onEnded { value in
                            model.draggingDivider = false
                            model.inboxDetailWidth = clamped(startWidth - value.translation.width)
                        })
                    .frame(width: dividerWidth)
                    .zIndex(10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Notification detail width")
                    .accessibilityValue(Text("\(Int(width)) points"))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: model.inboxDetailWidth = clamped(width + 24)
                        case .decrement: model.inboxDetailWidth = clamped(width - 24)
                        @unknown default: break
                        }
                    }
                    inspector(compact: false).frame(width: width)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var compactContent: some View {
        if model.mode == .people {
            VSplitView {
                feed.frame(minHeight: 85, idealHeight: 155)
                inspector(compact: true).frame(minHeight: 100)
            }
        } else {
            ZStack {
                // Keep the List alive while showing the inspector so going
                // back returns to the same list and scroll position.
                feed
                    .opacity(showsInspector ? 0 : 1)
                    .allowsHitTesting(!showsInspector)
                    .accessibilityHidden(showsInspector)
                if showsInspector {
                    inspector(compact: true)
                }
            }
        }
    }

    private var notebook: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Notebook", selection: $model.noteCollection) {
                ForEach(NoteCollection.allCases) { collection in
                    Text(collection.rawValue).tag(collection)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!ready || model.busy)

            if model.noteCollection == .mine {
                HStack {
                    Picker("Folder", selection: $model.notebookFolder) {
                        Text("All Notes").tag(NoteFolderFilter.all)
                        Text("Unfiled").tag(NoteFolderFilter.unfiled)
                        ForEach(model.noteFolders) { folder in
                            Text(folder.name).tag(NoteFolderFilter.folder(folder.id))
                        }
                    }
                    .frame(maxWidth: 220)
                    Button("New folder…") { model.openFolderEditor() }
                    if let folder = model.noteFolders.first(where: { $0.id == model.notebookFolder.folderID }) {
                        Button("Edit folder…") { model.openFolderEditor(folder) }
                    }
                    Spacer()
                    Button("New note…") { model.openPersonalNote() }
                }
                let notes = model.personalNotes.filter { model.notebookFolder.includes($0.folderID) }
                List(notes) { note in
                    notebookRow(title: note.title, body: note.body, updatedAt: note.updatedAt) {
                        model.openPersonalNote(note)
                    }
                }
                .notifdexSurface(.inboxList)
                .overlay {
                    if notes.isEmpty { Text("No notes here yet.").foregroundStyle(.secondary).allowsHitTesting(false) }
                }
            } else {
                HStack {
                    Picker("Person", selection: $model.notebookPersonID) {
                        Text("Choose a person").tag(nil as String?)
                        ForEach(model.people) { person in Text(person.name).tag(Optional(person.id)) }
                    }
                    .frame(maxWidth: 280)
                    Spacer()
                    if let person = model.people.first(where: { $0.id == model.notebookPersonID }) {
                        Button("New note…") { model.openNote(personID: person.id, name: person.name) }
                    }
                }
                let notes = model.displayedNotebookPeopleNotes
                List(notes) { note in
                    notebookRow(title: note.title, body: note.body, updatedAt: note.updatedAt) {
                        if let person = model.people.first(where: { $0.id == model.notebookPersonID }) {
                            model.openNote(personID: person.id, name: person.name, note: note)
                        }
                    }
                }
                .notifdexSurface(.inboxList)
                .overlay {
                    if notes.isEmpty {
                        Text(model.notebookPersonID == nil ? "Choose a person to see their notes." : "No notes for this person yet.")
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .disabled(!ready || model.busy)
    }

    private func notebookRow(title: String, body: String, updatedAt: Double, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.isEmpty ? "Untitled" : title).font(.headline).lineLimit(1)
                    Text(body).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Date(timeIntervalSince1970: updatedAt), style: .date)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    private var feed: some View {
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
    }

    private func inspector(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.mode == .people, model.alert != nil {
                Button { model.selected = nil } label: {
                    Label("Back to person", systemImage: "chevron.left")
                }
                .padding(12)
                Divider()
            } else if compact, model.mode != .people {
                Button { model.selected = nil } label: {
                    Label("Back to alerts", systemImage: "chevron.left")
                }
                .padding(12)
                Divider()
            }
            ScrollView { detail.padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                .id(model.mode == .people ? model.selected : nil)
        }
        .notifdexSurface(.inspector)
    }

    private func filterBar(includeSearch: Bool) -> some View {
        let tokens = themeTokens
        return HStack(spacing: 12) {
            if model.mode.hasTriageControls {
                HStack(spacing: 16) {
                    readFilterTab("All", filter: .all, tokens: tokens)
                    readFilterTab("Unread", filter: .unread, tokens: tokens)
                    readFilterTab("Read", filter: .read, tokens: tokens)
                }

                Menu("Sort & group") {
                    Picker("Group by", selection: $model.inboxPresentation.order) {
                        Text("None").tag(InboxPresentation.Order.recent)
                        Text("App").tag(InboxPresentation.Order.byApp)
                    }
                    Picker("Sort", selection: $model.captureOrder) {
                        Text("Newest first").tag(InboxQuery.Order.newestFirst)
                        Text("Oldest first").tag(InboxQuery.Order.oldestFirst)
                    }
                }
                .fixedSize()
            }
            if model.mode.hasTriageControls || model.mode == .saved || model.mode == .hidden {
                let categories = Set(apps.map { $0 == "Twitter" ? "X" : ($0.isEmpty ? "Unknown app" : $0) }).sorted()
                Picker("App", selection: $model.app) {
                    Text("All apps").tag(nil as String?)
                    ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .fixedSize()
            }
            if model.mode == .people {
                let activePerson = model.visiblePeople.first(where: { $0.id == model.person })
                Picker("Workspace", selection: $model.workspaceID) {
                    Text("All People").tag(nil as String?)
                    ForEach(model.workspaces) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 145)
                .onChange(of: model.workspaceID) { _, _ in model.selected = nil }
                Button { model.openWorkspaceEditor() } label: {
                    Label("New workspace", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("Create a workspace")
                .disabled(!ready || model.busy)
                Button {
                    model.openPeopleSwitcherPopover()
                } label: {
                    HStack(spacing: 6) {
                        if let activePerson {
                            PersonMonogram(name: activePerson.name, size: 18, tokens: tokens, prominent: true)
                            Text(activePerson.name)
                                .lineLimit(1)
                        } else {
                            Image(systemName: "person.2")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("Choose a person")
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .regular))
                .disabled(!ready || model.busy)
                .help("Search and switch people")
                .popover(isPresented: $model.showingPeopleSwitcherPopover, arrowEdge: .bottom) {
                    SearchablePersonPopoverView(model: model, purpose: .switchPerson, tokens: tokens, ready: ready)
                }
                Menu("Templates") {
                    Button("Apply Founder Outreach") {
                        if let person = model.person { model.applyFounderOutreach(to: person) }
                    }
                }
                .fixedSize()
                .disabled(!ready || model.busy || model.person == nil || model.cardID != model.person)
                Button {
                    model.openNewPersonPopover(for: nil, inPeopleBar: true)
                } label: {
                    Label("New Person", systemImage: "person.badge.plus")
                }
                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                .disabled(!ready || model.busy)
                .help("Create a new person card")
                .popover(isPresented: $model.showingPeopleNewPersonPopover, arrowEdge: .bottom) {
                    NewPersonPopoverView(model: model, tokens: tokens, ready: ready)
                }
            }
            Spacer(minLength: 8)
            if includeSearch {
                searchField(tokens: tokens)
            }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(tokens.hairline).frame(height: 0.5)
        }
    }

    private var entryList: some View {
        let rows = Array(model.visibleEntries.prefix(model.limit))
        let presentation = switch model.mode {
        case .inbox, .flagged: model.inboxPresentation
        case .saved, .hidden: InboxPresentation(order: .byApp)
        case .people, .today, .notes, .docs, .apps, .recovery: InboxPresentation()
        }
        // SwiftUI may clear a selection when its row leaves the list. Keep the
        // detail open in Inbox and Flagged until the user chooses another item.
        let selection = Binding<Int64?>(
            get: { rows.contains { $0.id == model.selected } ? model.selected : nil },
            set: { id in
                if id != nil || !model.mode.hasTriageControls { model.selected = id }
            }
        )
        return List(selection: selection) {
            ForEach(presentation.sections(for: rows), id: \.app) { section in
                if let app = section.app {
                    Section {
                        if section.expanded { listedRows(section.rows) }
                    } header: {
                        if model.mode.hasTriageControls {
                            Button { model.toggleAppSection(app) } label: {
                                Label(app, systemImage: section.expanded ? "chevron.down" : "chevron.right")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(section.expanded ? "Collapse \(app)" : "Expand \(app)")
                        } else {
                            Text(app)
                        }
                    }
                } else {
                    listedRows(section.rows)
                }
            }
        }
        .notifdexSurface(.inboxList)
        .overlay {
            if rows.isEmpty {
                Text(ready ? "No matching alerts" : "Opening inbox…").foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func listedRows(_ rows: [InboxEntry]) -> some View {
        ForEach(rows) { row in
            entryRow(row, showActions: model.mode.hasTriageControls)
                .notifdexAlertSelection(model.selected == row.id)
                .listRowBackground(Color.clear)
                .tag(row.id)
        }
    }

    private func readFilterTab(_ title: String, filter: InboxQuery.ReadFilter, tokens: ThemeTokens) -> some View {
        let active = model.readFilter == filter
        return Button {
            model.readFilter = filter
        } label: {
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                Rectangle()
                    .fill(active ? tokens.accent : Color.clear)
                    .frame(height: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func entryRow(_ entry: InboxEntry, showActions: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if !entry.isRead {
                    Circle()
                        .fill(themeTokens.accent)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Unread")
                }
                Text(entry.title.isEmpty ? "Notification" : entry.title)
                    .font(.system(size: 13.5, weight: entry.isRead ? .regular : .medium))
                    .foregroundStyle(entry.isRead ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Group {
                    if model.mode == .today, let due = entry.dueAt {
                        Text(Date(timeIntervalSince1970: due).formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text(Date(timeIntervalSince1970: entry.capturedAt).formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            if !entry.body.isEmpty {
                Text(entry.body)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .foregroundStyle(entry.isRead ? Color.secondary.opacity(0.68) : Color.primary.opacity(0.76))
            }
            HStack(spacing: 8) {
                Text(entry.app)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if entry.personID != nil, !entry.personName.isEmpty {
                    let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if entry.personName.caseInsensitiveCompare(trimmedTitle) != .orderedSame {
                        Text("· \(entry.personName)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(themeTokens.accent)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(themeTokens.accent.opacity(0.75))
                            .accessibilityLabel("Linked to \(entry.personName)")
                    }
                }
                Spacer()
                if entry.saved {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(themeTokens.accent)
                        .accessibilityLabel("Saved")
                }
                if showActions {
                    Button {
                        model.edit { try $0.setFlag(entry.id, flagged: !entry.isFlagged) }
                    } label: {
                        Image(systemName: entry.isFlagged ? "flag.fill" : "flag")
                            .font(.system(size: 10.5))
                            .foregroundStyle(entry.isFlagged ? themeTokens.accent : Color.secondary.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(entry.isFlagged ? "Remove flag" : "Flag alert")
                    .help(entry.isFlagged ? "Remove flag" : "Flag alert")
                    .disabled(!ready || model.busy)
                    hideMenu(entry)
                } else if entry.isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(themeTokens.accent)
                        .accessibilityLabel("Flagged")
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func hideMenu(_ entry: InboxEntry) -> some View {
        Menu {
            Button("Hide this alert") { model.hide(.alert(entry.id)) }
            if entry.app != "Unknown app" {
                ForEach(InboxRuleMatch.Field.allCases) { field in
                    let text = field == .title ? entry.title : entry.body
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Hide all with this \(field.rawValue)") {
                            model.reviewHideRule(InboxRuleMatch(app: entry.app, field: field, text: text))
                        }
                    }
                }
            }
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Hide this alert or match its title or body within this app")
        .disabled(!ready || model.busy)
    }

    private var hideRules: some View {
        Menu("Hide rules") {
            ForEach(model.rules) { rule in
                let match = rule.match
                Button("Remove \(match.app) · \(match.field.rawValue.capitalized) · \(match.text)") {
                    model.restore(.rule(match))
                }
            }
        }
        .disabled(!ready || model.busy)
        .help("Remove a hide rule. Other hides still apply.")
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let alert = model.alert {
                alertDetail(alert)
                if model.mode != .people, let id = alert.personID {
                    Divider()
                    personCard(id: id, name: alert.personName, showRecentActivity: true)
                }
            } else if model.mode == .people {
                if let card = model.visiblePeople.first(where: { $0.id == model.person }) {
                    personCard(id: card.id, name: card.name, showRecentActivity: false)
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
        let tokens = themeTokens
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.title.isEmpty ? "Notification" : alert.title)
                        .font(.system(size: 20, weight: .regular, design: .serif))
                    Text("\(alert.app) · \(Date(timeIntervalSince1970: alert.capturedAt).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let personID = alert.personID {
                    linkedContactPill(personID: personID, personName: alert.personName, alert: alert, tokens: tokens)
                }
            }

            alertContactBanners(alert, tokens: tokens)

            if !alert.subtitle.isEmpty { Text(alert.subtitle).textSelection(.enabled) }
            Text(alert.body.isEmpty ? "No preview was captured." : alert.body)
                .textSelection(.enabled)
            HStack {
                if InboxDestination.canOpen(alert.app) {
                    Button("Open in \(alert.app)") { model.open(alert) }
                        .help("Open the app or its inbox")
                }
                Button(alert.isRead ? "Mark unread" : "Mark read") {
                    model.edit { try $0.setRead(alert.id, read: !alert.isRead) }
                }
                Menu("More") {
                    Button(alert.isFlagged ? "Remove flag" : "Flag alert") {
                        model.edit { try $0.setFlag(alert.id, flagged: !alert.isFlagged) }
                    }
                    Button(alert.saved ? "Remove from Saved" : "Save for later") {
                        model.edit { try $0.setSaved(alert.id, saved: !alert.saved) }
                    }
                }
                .fixedSize()
            }
            if !model.workspaces.isEmpty || model.mode == .hidden {
                Divider()
                Text("Context").font(.headline)
                if !model.workspaces.isEmpty {
                    Picker("Alert workspace", selection: Binding(
                        get: { alert.workspaceID },
                        set: { workspace in model.edit { try $0.setAlertWorkspace(alert.id, to: workspace) } }
                    )) {
                        Text("Unassigned").tag(nil as String?)
                        ForEach(model.workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
                    }
                    .help("Route this alert independently of the person's workspace memberships.")
                }
                if model.mode == .hidden {
                    if alert.individuallyHidden {
                        Button("Undo individual hide") { model.restore(.alert(alert.id)) }
                    }
                    if alert.titleFiltered {
                        Button("Remove matching title rule") {
                            model.restore(.rule(InboxRuleMatch(app: alert.app, field: .title, text: alert.title)))
                        }
                    }
                    if alert.bodyFiltered {
                        Button("Remove matching body rule") {
                            model.restore(.rule(InboxRuleMatch(app: alert.app, field: .body, text: alert.body)))
                        }
                    }
                }
            }
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

    private func linkedContactPill(
        personID: String,
        personName: String,
        alert: InboxEntry,
        tokens: ThemeTokens
    ) -> some View {
        Button {
            if model.showingContactCardPopover {
                model.showingContactCardPopover = false
            } else {
                model.openContactCardPopover(for: alert)
            }
        } label: {
            HStack(spacing: 6) {
                PersonMonogram(name: personName, size: 20, tokens: tokens, prominent: true)
                Text(personName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(model.showingContactCardPopover ? tokens.selectionFill : tokens.subtleFill)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(model.showingContactCardPopover ? tokens.accent.opacity(0.6) : tokens.hairline, lineWidth: 0.75)
                    }
            }
        }
        .buttonStyle(.plain)
        .help("View or update \(personName)")
        .accessibilityLabel("Contact card for \(personName)")
        .popover(isPresented: $model.showingContactCardPopover, arrowEdge: .bottom) {
            ContactCardPopoverView(
                model: model,
                personID: personID,
                personName: personName,
                alert: alert,
                tokens: tokens,
                ready: ready
            )
        }
        .popover(isPresented: $model.showingExistingPersonPopover, arrowEdge: .bottom) {
            SearchablePersonPopoverView(
                model: model,
                purpose: .linkAlert(alert),
                tokens: tokens,
                ready: ready
            )
        }
    }

    @ViewBuilder
    private func alertContactBanners(_ alert: InboxEntry, tokens: ThemeTokens) -> some View {
        if alert.personID == nil {
            let suggestion = model.dismissedSuggestionAlertIDs.contains(alert.id)
                ? nil
                : ContactSuggestions.suggest(
                    for: alert,
                    people: model.people,
                    identitiesByPerson: model.allIdentities
                )
            switch suggestion {
            case .single(let match):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 9) {
                        PersonMonogram(name: match.person.name, size: 28, tokens: tokens, prominent: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Possible match: \(match.person.name)")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(suggestionReasonText(match))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            model.dismissedSuggestionAlertIDs.insert(alert.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss suggestion")
                    }
                    HStack(spacing: 8) {
                        Button("Link to \(match.person.name)") {
                            model.linkAlert(alert.id, to: match.person.id)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        Button("Choose another…") {
                            model.openExistingPersonPopover()
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .regular))
                        .popover(isPresented: $model.showingExistingPersonPopover, arrowEdge: .bottom) {
                            SearchablePersonPopoverView(model: model, purpose: .linkAlert(alert), tokens: tokens, ready: ready)
                        }
                        Button("New person…") {
                            model.openNewPersonPopover(for: alert)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                        .popover(isPresented: $model.showingNewPersonPopover, arrowEdge: .bottom) {
                            NewPersonPopoverView(model: model, tokens: tokens, ready: ready)
                        }
                    }
                }
                .padding(10)
                .notifdexSurface(.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.accent.opacity(0.35), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }

            case .ambiguous(let candidates):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "person.2.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(tokens.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(candidates.count) people named “\(alert.title)”")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("Choose which person sent this \(alert.app) alert.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            model.dismissedSuggestionAlertIDs.insert(alert.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss suggestion")
                    }
                    HStack(spacing: 8) {
                        Button("Choose person…") {
                            model.openExistingPersonPopover(prefillQuery: alert.title)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        .popover(isPresented: $model.showingExistingPersonPopover, arrowEdge: .bottom) {
                            SearchablePersonPopoverView(model: model, purpose: .linkAlert(alert), tokens: tokens, ready: ready)
                        }
                        Button("New person…") {
                            model.openNewPersonPopover(for: alert)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .regular))
                        .popover(isPresented: $model.showingNewPersonPopover, arrowEdge: .bottom) {
                            NewPersonPopoverView(model: model, tokens: tokens, ready: ready)
                        }
                    }
                }
                .padding(10)
                .notifdexSurface(.card)

            case nil:
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text("Not linked to a person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("New Person…") {
                        model.openNewPersonPopover(for: alert)
                    }
                    .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                    .popover(isPresented: $model.showingNewPersonPopover, arrowEdge: .bottom) {
                        NewPersonPopoverView(model: model, tokens: tokens, ready: ready)
                    }
                    Button("Add to Existing…") {
                        model.openExistingPersonPopover()
                    }
                    .buttonStyle(NotifdexGlassButtonStyle(emphasis: .regular))
                    .popover(isPresented: $model.showingExistingPersonPopover, arrowEdge: .bottom) {
                        SearchablePersonPopoverView(model: model, purpose: .linkAlert(alert), tokens: tokens, ready: ready)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .notifdexSurface(.card)
            }
        } else if let personID = alert.personID {
            let trimmedTitle = alert.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let identities = model.cardID == personID ? model.identities : (model.allIdentities[personID] ?? [])
            if ContactSuggestions.looksLikeIdentifier(trimmedTitle),
               !ContactSuggestions.hasMatchingHandle(trimmedTitle, app: alert.app, in: identities),
               !model.dismissedHandleBannerAlertIDs.contains(alert.id) {
                let platform = ContactSuggestions.defaultPlatform(for: alert.app)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Add “\(trimmedTitle)” as a \(platform) handle for \(alert.personName)?")
                        .font(.caption.weight(.medium))
                    HStack(spacing: 8) {
                        Button("Add handle") {
                            model.saveObservedHandle(for: alert, personID: personID)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        Button("Dismiss") {
                            model.dismissedHandleBannerAlertIDs.insert(alert.id)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notifdexSurface(.card)
            }

            if alert.personRuleID != nil {
                Label("Linked by a matching rule", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let preview = model.inlineMatchPreview,
                      preview.observationID == alert.id,
                      !model.dismissedRuleBannerAlertIDs.contains(alert.id) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Always link \(preview.app) alerts from “\(preview.title)” to \(preview.personName)?")
                        .font(.caption.weight(.medium))
                    Text(preview.existingCount > 0
                         ? "\(preview.existingCount) existing unlinked \(preview.existingCount == 1 ? "alert also matches" : "alerts also match")."
                         : "Applies to future alerts with this exact app and title.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if preview.existingCount > 0 {
                            Button("Existing & future") {
                                model.confirmMatch(preview, includeExisting: true)
                            }
                            .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                            Button("Future only") {
                                model.confirmMatch(preview, includeExisting: false)
                            }
                            .buttonStyle(NotifdexGlassButtonStyle(emphasis: .regular))
                        } else {
                            Button("Always link") {
                                model.confirmMatch(preview, includeExisting: false)
                            }
                            .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        }
                        Button("Not now") {
                            model.dismissedRuleBannerAlertIDs.insert(alert.id)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notifdexSurface(.card)
            }
        }
    }

    private func suggestionReasonText(_ match: PersonSuggestion) -> String {
        switch match.reason {
        case .savedHandle(let platform):
            return "Matches saved \(platform) handle"
        case .displayName:
            let platforms = Array(Set((model.allIdentities[match.person.id] ?? []).map(\.platform))).sorted()
            if platforms.isEmpty {
                return "Matches existing display name"
            }
            return "Same display name · Saved on \(platforms.joined(separator: ", "))"
        }
    }

    private func hideRuleReview(_ preview: HideRulePreview) -> some View {
        let match = preview.match
        return VStack(alignment: .leading, spacing: 12) {
            Text("Hide all with this \(match.field.rawValue)?").font(.title2)
            LabeledContent("App", value: match.app)
            Text("Exact \(match.field.rawValue)")
                .font(.headline)
            ScrollView {
                Text(verbatim: match.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            Text("Stored alerts that match: \(preview.count)")
            Text("This rule also hides future alerts from \(match.app) with the same \(match.field.rawValue).")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.hideRulePreview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Hide matching alerts") {
                    model.hideRulePreview = nil
                    model.hide(.rule(match))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ready || model.busy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func matchReview(_ preview: PersonMatchPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remember this match?").font(.title2)
            LabeledContent("App", value: preview.app)
            LabeledContent("Exact title", value: preview.title)
            LabeledContent("Link to", value: preview.personName)
            Text("Existing unlinked alerts that match: \(preview.existingCount)")
            Text("People can share a display name. Existing manual links and explicit unlinks take priority.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.matchPreview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Future only") { model.confirmMatch(preview, includeExisting: false) }
                Button("Existing and future") { model.confirmMatch(preview, includeExisting: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var workspaceEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New workspace").font(.title2)
            TextField("Workspace name", text: $model.workspaceName)
            if let error = model.sheetError { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.showingNewWorkspace = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { model.createWorkspace() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func newPerson(linking id: Int64?) -> some View {
        HStack {
            TextField("New person name", text: $model.name)
            Button(id == nil ? "Create" : "Create and link") { model.createPerson(linking: id) }
                .disabled(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func templateProgress(_ assignment: RelationshipTemplateAssignment, for person: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(assignment.definition.name).font(.headline)
                Text("v\(assignment.definition.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove template…") {
                    model.templateRemoval = TemplateRemoval(personID: person, definition: assignment.definition)
                }
            }
            Picker("Stage", selection: Binding(
                get: { assignment.stageID },
                set: { stage in model.edit { try $0.setTemplateStage(stage, for: person) } }
            )) {
                ForEach(assignment.definition.stages) { stage in Text(stage.name).tag(stage.id) }
            }
            ForEach(assignment.definition.milestones) { milestone in
                Toggle(milestone.name, isOn: Binding(
                    get: { assignment.completedMilestones.contains(milestone.id) },
                    set: { completed in
                        model.edit { try $0.setTemplateMilestone(milestone.id, completed: completed, for: person) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .disabled(!ready || model.busy)
    }

    private func workspaceMembershipMenu(for person: String) -> some View {
        let memberships = model.workspaces.filter { model.personWorkspaceIDs.contains($0.id) }
        let summary = memberships.isEmpty ? "None" : memberships.map(\.name).joined(separator: ", ")
        return LabeledContent("Workspaces") {
            Menu(summary) {
                ForEach(model.workspaces) { workspace in
                    Toggle(workspace.name, isOn: Binding(
                        get: { model.personWorkspaceIDs.contains(workspace.id) },
                        set: { isMember in
                            model.edit {
                                try $0.setWorkspaceMembership(person: person, workspace: workspace.id, isMember: isMember)
                            }
                        }
                    ))
                }
                if !model.workspaces.isEmpty { Divider() }
                Button("New workspace…") { model.openWorkspaceEditor() }
            }
            .lineLimit(1)
            .accessibilityLabel("Workspace memberships")
            .accessibilityValue(summary)
            .help(summary)
        }
    }

    private func personCard(id: String, name: String, showRecentActivity: Bool) -> some View {
        let tokens = themeTokens
        let cardIdentities = model.cardID == id ? model.identities : []
        let isRenaming = model.renamingPersonID == id && !model.showingContactCardPopover
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                PersonMonogram(name: name, size: 32, tokens: tokens, prominent: true)
                if isRenaming {
                    TextField("Display name", text: $model.renamePersonDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.commitRename() }
                    Button("Save") { model.commitRename() }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        .disabled(model.renamePersonDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { model.cancelRename() }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                } else {
                    Text(name)
                        .font(.system(size: 18, weight: .regular, design: .serif))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if showRecentActivity {
                        Button {
                            model.jumpToPerson(id)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Open in People")
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                    } else {
                        Menu {
                            Button("Rename…") { model.startRename(personID: id, currentName: name) }
                            Divider()
                            Button("Delete person…", role: .destructive) {
                                model.personToDelete = PersonRecord(id: id, name: name)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Rename or delete person")
                    }
                }
            }
            if model.mode == .people, model.cardID == id {
                workspaceMembershipMenu(for: id)
            }
            if !showRecentActivity || !cardIdentities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Handles").font(.headline)
                        Spacer()
                        if !showRecentActivity {
                            Button {
                                let next = !model.showingAddHandleInline
                                model.showingAddHandleInline = next
                                if next {
                                    model.identityApp = ContactSuggestions.defaultPlatform(for: model.alert?.app ?? "Messages")
                                    model.identifier = ""
                                }
                            } label: {
                                Text(model.showingAddHandleInline ? "Cancel" : "+ Add handle")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(tokens.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if cardIdentities.isEmpty && !model.showingAddHandleInline {
                        Text("No handles saved yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(cardIdentities) { identity in
                        HStack(spacing: 8) {
                            Text("\(identity.platform) · \(identity.identifier)")
                                .font(.callout)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                model.edit { try $0.removeIdentity(identity.id, person: id) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove handle")
                            .accessibilityLabel("Remove \(identity.platform) handle")
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .notifdexSurface(.pill)
                    }
                    if !showRecentActivity && model.showingAddHandleInline {
                        HStack(spacing: 6) {
                            Picker("App", selection: $model.identityApp) {
                                ForEach(ContactSuggestions.supportedPlatforms, id: \.self) { Text($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("Handle or address", text: $model.identifier)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    if !model.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        model.addIdentity(to: id, collapseAfter: true)
                                    }
                                }
                            Button("Add") { model.addIdentity(to: id, collapseAfter: true) }
                                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                                .disabled(model.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            if model.cardID == id && !model.matchRules.isEmpty {
                Text("Matching rules").font(.headline)
                ForEach(model.matchRules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(rule.app) · \(rule.title)")
                            if rule.hasConflict {
                                Text("Paused: this title was linked to another person.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove rule") { model.edit { try $0.removePersonMatchRule(rule.id) } }
                            .help("Remove links made by this rule. Manual links stay.")
                    }
                }
            }
            if model.mode == .people, model.workspaceID != nil {
                Text("Notes and template progress are shared across this person's workspaces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.mode == .people, model.cardID == id, let assignment = model.templateAssignment {
                templateProgress(assignment, for: id)
            }
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                Button("Add note…") { model.openNote(personID: id, name: name) }
            }
            if model.cardID == id && model.notes.isEmpty {
                Text("No notes yet.").foregroundStyle(.secondary)
            }
            ForEach(model.cardID == id ? model.notes : []) { note in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Date(timeIntervalSince1970: note.createdAt).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if !note.title.isEmpty { Text(note.title).font(.headline) }
                        Text(note.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Edit…") { model.openNote(personID: id, name: name, note: note) }
                        .accessibilityLabel("Edit note from \(Date(timeIntervalSince1970: note.createdAt).formatted())")
                }
            }
            if showRecentActivity {
                Text("Recent activity").font(.headline)
                if model.cardID == id && model.timeline.isEmpty {
                    Text("No linked alerts yet.").foregroundStyle(.secondary)
                }
                ForEach(model.cardID == id ? model.timeline : []) { entry in
                    Divider()
                    entryRow(entry)
                }
            }
        }
    }
}

@MainActor
private struct NoteEditor: View {
    @ObservedObject var model: WorkflowModel
    let draft: NoteDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.personName.map { "Note for \($0)" } ?? "My Note")
                .font(.headline)
            TextField("Title", text: $model.noteTitle)
            if draft.personID == nil {
                Picker("Folder", selection: $model.noteFolderID) {
                    Text("Unfiled").tag(nil as String?)
                    ForEach(model.noteFolders) { folder in Text(folder.name).tag(Optional(folder.id)) }
                }
            }
            TextEditor(text: $model.noteBody)
                .font(.body)
                .accessibilityLabel("Note")
                .frame(minHeight: 120)
                .disabled(model.busy)
            if let error = model.sheetError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                if draft.noteID != nil {
                    Button("Delete Note…", role: .destructive) { model.confirmingNoteDeletion = true }
                }
                Spacer()
                Button("Cancel") { model.noteDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.saveNote(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(model.busy)
        }
        .padding()
        .frame(minWidth: 380)
        .interactiveDismissDisabled(model.busy)
        .alert("Delete this note?", isPresented: $model.confirmingNoteDeletion) {
            Button("Delete", role: .destructive) { model.deleteNote(draft) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
@MainActor
private struct FolderEditor: View {
    @ObservedObject var model: WorkflowModel
    let draft: FolderDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.folderID == nil ? "New folder" : "Edit folder").font(.headline)
            TextField("Folder name", text: $model.folderName)
            if let error = model.sheetError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                if draft.folderID != nil {
                    Button("Delete folder…", role: .destructive) { model.confirmingFolderDeletion = true }
                }
                Spacer()
                Button("Cancel") { model.folderDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { model.saveFolder(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 380)
        .disabled(model.busy)
        .interactiveDismissDisabled(model.busy)
        .alert("Delete this folder?", isPresented: $model.confirmingFolderDeletion) {
            Button("Delete folder", role: .destructive) { model.deleteFolder(draft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its notes will move to Unfiled.")
        }
    }
}

@MainActor
private struct ResizeCursorArea: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> ResizeCursorNSView {
        let view = ResizeCursorNSView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ view: ResizeCursorNSView, context: Context) {
        view.onHoverChange = onHoverChange
    }
}

@MainActor
private final class ResizeCursorNSView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep SwiftUI's high-priority DragGesture as the sole mouse-down receiver
        // while AppKit cursor rects and tracking areas remain active across bounds.
        nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}
#endif
