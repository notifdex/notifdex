import NotifdexCore
import SwiftUI

struct NotesView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showingEditor = false
    @State private var editingNote: PersonalNote?
    @State private var noteTitle = ""
    @State private var noteBody = ""

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.personalNotes.isEmpty {
                    ContentUnavailableView {
                        Label("No Notes Yet", systemImage: "note.text")
                    } description: {
                        Text("Capture quick private notes on your iPhone. With opt-in CloudKit Sync enabled, notes sync with Notifdex on your Mac.")
                    } actions: {
                        Button("New Note") {
                            openNewNote()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(viewModel.personalNotes) { note in
                            Button {
                                editingNote = note
                                noteTitle = note.title
                                noteBody = note.body
                                showingEditor = true
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.title.isEmpty ? "Untitled Note" : note.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(note.body)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(Date(timeIntervalSince1970: note.updatedAt).formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    viewModel.deletePersonalNote(note.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .refreshable { viewModel.reload() }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openNewNote()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                NavigationStack {
                    Form {
                        TextField("Title", text: $noteTitle)
                        TextEditor(text: $noteBody)
                            .frame(minHeight: 180)
                    }
                    .navigationTitle(editingNote == nil ? "New Note" : "Edit Note")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingEditor = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                viewModel.savePersonalNote(
                                    id: editingNote?.id,
                                    folderID: editingNote?.folderID,
                                    title: noteTitle,
                                    body: noteBody
                                )
                                showingEditor = false
                            }
                            .disabled(noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func openNewNote() {
        editingNote = nil
        noteTitle = ""
        noteBody = ""
        showingEditor = true
    }
}
