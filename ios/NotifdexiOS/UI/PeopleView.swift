import NotifdexCore
import SwiftUI

struct PeopleView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showingNewPerson = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.people.isEmpty {
                    ContentUnavailableView {
                        Label("No People Yet", systemImage: "person.2")
                    } description: {
                        Text("Link alerts across X, Gmail, WeChat, and Messages to a person to keep their timeline and notes together.")
                    } actions: {
                        Button("New Person") {
                            newName = ""
                            showingNewPerson = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(viewModel.people) { person in
                        NavigationLink {
                            PersonProfileView(person: person, viewModel: viewModel)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(NotifdexTheme.prussian.opacity(0.16))
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Text(String(person.name.prefix(1)).uppercased())
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(NotifdexTheme.prussian)
                                    )
                                Text(person.name)
                                    .font(.body.weight(.medium))
                            }
                        }
                    }
                    .refreshable { viewModel.reload() }
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newName = ""
                        showingNewPerson = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Person", isPresented: $showingNewPerson) {
                TextField("Display Name", text: $newName)
                Button("Create") {
                    viewModel.createPerson(name: newName)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct PersonProfileView: View {
    let person: PersonRecord
    @ObservedObject var viewModel: AppViewModel
    @State private var showingAddNote = false
    @State private var noteTitle = ""
    @State private var noteBody = ""

    var body: some View {
        let notes = viewModel.personNotes(for: person.id)
        let alerts = viewModel.alerts(for: person.id)

        List {
            Section {
                if notes.isEmpty {
                    Text("No notes yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            if !note.title.isEmpty {
                                Text(note.title)
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text(note.body)
                                .font(.subheadline)
                            Text(Date(timeIntervalSince1970: note.updatedAt).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .swipeActions {
                            Button(role: .destructive) {
                                viewModel.deletePersonNote(note.id, personID: person.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    noteTitle = ""
                    noteBody = ""
                    showingAddNote = true
                } label: {
                    Label("Add Note", systemImage: "square.and.pencil")
                }
            } header: {
                Text("Notes")
            }

            Section("Linked Alerts (\(alerts.count))") {
                if alerts.isEmpty {
                    Text("No linked notifications yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(alerts) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.app)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(NotifdexTheme.color(for: entry.app))
                                Spacer()
                                Text(Date(timeIntervalSince1970: entry.capturedAt), style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.title.isEmpty ? entry.app : entry.title)
                                .font(.subheadline.weight(.medium))
                            Text(entry.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(person.name)
        .sheet(isPresented: $showingAddNote) {
            NavigationStack {
                Form {
                    TextField("Title (optional)", text: $noteTitle)
                    TextEditor(text: $noteBody)
                        .frame(minHeight: 140)
                }
                .navigationTitle("Note for \(person.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddNote = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            viewModel.addPersonNote(personID: person.id, title: noteTitle, body: noteBody)
                            showingAddNote = false
                        }
                        .disabled(noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}
