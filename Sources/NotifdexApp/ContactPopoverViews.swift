#if os(macOS)
import SwiftUI
import NotifdexCore

@MainActor
struct PersonMonogram: View {
    let name: String
    let size: CGFloat
    let tokens: ThemeTokens
    var prominent: Bool = false

    var body: some View {
        let letters = ContactSuggestions.initials(for: name)
        Circle()
            .fill(prominent ? tokens.accent : tokens.accent.opacity(0.16))
            .overlay {
                Circle()
                    .strokeBorder(prominent ? Color.clear : tokens.accent.opacity(0.32), lineWidth: 0.75)
            }
            .overlay {
                Text(letters)
                    .font(.system(size: max(9, size * 0.40), weight: .semibold, design: .rounded))
                    .foregroundStyle(prominent ? tokens.accentText : tokens.accent)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
struct NewPersonPopoverView: View {
    @ObservedObject var model: WorkflowModel
    let platforms: [String]
    let tokens: ThemeTokens
    let ready: Bool

    var body: some View {
        let linkingAlert = model.newPersonLinkingAlertID != nil
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(linkingAlert ? "New Person & Link" : "New Person")
                    .font(.headline)
                Spacer()
                Button {
                    model.showingNewPersonPopover = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Display name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Maya Lin", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            model.submitNewPersonPopover()
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Handle or address (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("App", selection: $model.newPersonPlatform) {
                        ForEach(platforms, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Phone, email, or @handle", text: $model.newPersonHandle)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if !model.workspaces.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Workspace (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Workspace", selection: $model.newPersonWorkspaceID) {
                        Text("None").tag(nil as String?)
                        ForEach(model.workspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            if let alert = model.alert, model.newPersonLinkingAlertID == alert.id,
               alert.app != "Unknown app",
               !alert.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Toggle(isOn: $model.newPersonRememberMatch) {
                    Text("Also link matching \(alert.app) alerts from “\(alert.title)”")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }

            if let error = model.popoverError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    model.showingNewPersonPopover = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(linkingAlert ? "Create & Link" : "Create") {
                    model.submitNewPersonPopover()
                }
                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || model.busy || model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

@MainActor
struct SearchablePersonPopoverView: View {
    enum Purpose {
        case linkAlert(InboxEntry)
        case switchPerson
    }

    @ObservedObject var model: WorkflowModel
    let purpose: Purpose
    let tokens: ThemeTokens
    let ready: Bool

    private var basePeople: [PersonRecord] {
        switch purpose {
        case .linkAlert: return model.people
        case .switchPerson: return model.visiblePeople
        }
    }

    private var trimmedQuery: String {
        model.personSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredPeople: [PersonRecord] {
        let query = trimmedQuery.lowercased()
        guard !query.isEmpty else { return basePeople }
        return basePeople.filter { person in
            if person.name.lowercased().contains(query) { return true }
            let handles = model.allIdentities[person.id] ?? []
            return handles.contains {
                $0.identifier.lowercased().contains(query) || $0.platform.lowercased().contains(query)
            }
        }
    }

    private var titleText: String {
        switch purpose {
        case .linkAlert(let alert):
            return alert.personID == nil ? "Add to Existing Person" : "Change Linked Person"
        case .switchPerson:
            return "Switch Person"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(titleText).font(.headline)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search name or handle…", text: $model.personSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !model.personSearchQuery.isEmpty {
                    Button {
                        model.personSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .notifdexSurface(.pill)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filteredPeople.isEmpty && trimmedQuery.isEmpty {
                        Text("No people yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(filteredPeople) { person in
                        personRow(person)
                    }
                    if case .linkAlert(let alert) = purpose,
                       !trimmedQuery.isEmpty,
                       !filteredPeople.contains(where: { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
                        Divider().padding(.vertical, 4)
                        Button {
                            model.quickCreatePerson(named: trimmedQuery, linking: alert)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(tokens.accent)
                                Text("Create “\(trimmedQuery)” and link")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(tokens.accent)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!ready || model.busy)
                    }
                }
            }
            .frame(maxHeight: 240)

            if case .linkAlert(let alert) = purpose, alert.personID != nil {
                Divider()
                Button(role: .destructive) {
                    model.linkAlert(alert.id, to: nil)
                } label: {
                    Label("Unlink and skip matching rules", systemImage: "link.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(!ready || model.busy)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func personRow(_ person: PersonRecord) -> some View {
        let handles = model.allIdentities[person.id] ?? []
        let handleSummary = handles.prefix(2).map { "\($0.platform) · \($0.identifier)" }.joined(separator: "  ")
        let isSelected: Bool = switch purpose {
        case .linkAlert(let alert): alert.personID == person.id
        case .switchPerson: model.person == person.id
        }

        return Button {
            switch purpose {
            case .linkAlert(let alert):
                model.linkAlert(alert.id, to: person.id)
            case .switchPerson:
                model.person = person.id
                model.selected = nil
                model.identifier = ""
                model.showingPeopleSwitcherPopover = false
            }
        } label: {
            HStack(spacing: 9) {
                PersonMonogram(name: person.name, size: 24, tokens: tokens, prominent: isSelected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !handleSummary.isEmpty {
                        Text(handleSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tokens.selectionFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ready || model.busy)
    }

    private func close() {
        switch purpose {
        case .linkAlert: model.showingExistingPersonPopover = false
        case .switchPerson: model.showingPeopleSwitcherPopover = false
        }
    }
}

@MainActor
struct ContactCardPopoverView: View {
    @ObservedObject var model: WorkflowModel
    let personID: String
    let personName: String
    let alert: InboxEntry
    let platforms: [String]
    let tokens: ThemeTokens
    let ready: Bool

    private var identities: [PersonIdentity] {
        model.cardID == personID ? model.identities : (model.allIdentities[personID] ?? [])
    }

    private var isRenaming: Bool {
        model.renamingPersonID == personID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Monogram + Name / Inline Rename + Open in People
            HStack(alignment: .center, spacing: 10) {
                PersonMonogram(name: personName, size: 34, tokens: tokens, prominent: true)
                VStack(alignment: .leading, spacing: 2) {
                    if isRenaming {
                        HStack(spacing: 6) {
                            TextField("Display name", text: $model.renamePersonDraft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.commitRename() }
                            Button("Save") { model.commitRename() }
                                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                                .disabled(!ready || model.busy || model.renamePersonDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(personName)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Button {
                                model.startRename(personID: personID, currentName: personName)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Rename person")
                            .accessibilityLabel("Rename \(personName)")
                        }
                        Text("\(identities.count) \(identities.count == 1 ? "handle" : "handles") · \(model.notes.count) \(model.notes.count == 1 ? "note" : "notes")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if !isRenaming {
                    Button {
                        model.jumpToPerson(personID)
                    } label: {
                        HStack(spacing: 3) {
                            Text("People")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(NotifdexGlassButtonStyle(emphasis: .regular))
                    .help("Open full profile in People")
                }
            }

            Divider()

            // Handles section with progressive disclosure
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Handles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let next = !model.showingAddHandleInline
                        model.showingAddHandleInline = next
                        if next {
                            model.identityApp = ContactSuggestions.defaultPlatform(for: alert.app)
                            model.identifier = ""
                        }
                    } label: {
                        Text(model.showingAddHandleInline ? "Cancel" : "+ Add \(ContactSuggestions.defaultPlatform(for: alert.app)) handle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(tokens.accent)
                    }
                    .buttonStyle(.plain)
                }

                if identities.isEmpty && !model.showingAddHandleInline {
                    Text("No handles saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !identities.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(identities) { identity in
                            HStack(spacing: 6) {
                                Text("\(identity.platform) · \(identity.identifier)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    model.edit { try $0.removeIdentity(identity.id, person: personID) }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove handle")
                                .accessibilityLabel("Remove \(identity.platform) handle \(identity.identifier)")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .notifdexSurface(.pill)
                        }
                    }
                }

                if model.showingAddHandleInline {
                    HStack(spacing: 6) {
                        Picker("App", selection: $model.identityApp) {
                            ForEach(platforms, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("Handle or address", text: $model.identifier)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                if !model.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    model.addIdentity(to: personID, collapseAfter: true)
                                }
                            }
                        Button("Add") {
                            model.addIdentity(to: personID, collapseAfter: true)
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        .disabled(!ready || model.busy || model.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            // Workspaces section
            if !model.workspaces.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workspaces")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.workspaces) { workspace in
                                let active = model.personWorkspaceIDs.contains(workspace.id)
                                Button {
                                    model.edit {
                                        try $0.setWorkspaceMembership(
                                            person: personID,
                                            workspace: workspace.id,
                                            isMember: !active
                                        )
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        if active {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9.5, weight: .bold))
                                        }
                                        Text(workspace.name)
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(active ? tokens.accentText : Color.primary)
                                    .background {
                                        Capsule(style: .continuous)
                                            .fill(active ? tokens.accent : tokens.subtleFill)
                                            .overlay {
                                                Capsule(style: .continuous)
                                                    .strokeBorder(active ? Color.clear : tokens.hairline, lineWidth: 0.5)
                                            }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            if let error = model.popoverError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Footer actions
            HStack(spacing: 8) {
                Button {
                    model.showingContactCardPopover = false
                    model.openNote(personID: personID, name: personName)
                } label: {
                    Label("Add note…", systemImage: "square.and.pencil")
                }
                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .regular))

                Spacer()

                Button("Change…") {
                    model.openExistingPersonPopover()
                }
                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))

                Button("Unlink") {
                    model.linkAlert(alert.id, to: nil)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
            }
            .disabled(!ready || model.busy)
        }
        .padding(16)
        .frame(width: 340)
    }
}
#endif
