#if os(macOS)
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import NotifdexCore
import NotifdexMac

private struct DocumentDraft: Identifiable {
    let id = UUID()
    let documentID: String?
}

@MainActor
private final class DocsModel: ObservableObject {
    @Published var search = ""
    @Published var title = ""
    @Published var body = ""
    @Published var draft: DocumentDraft?
    @Published var showingImport = false
    @Published var confirmingDelete = false
    @Published private(set) var summaries: [DocumentSummary] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    private let worker: CaptureWorker

    init(worker: CaptureWorker) { self.worker = worker }

    var visibleDocuments: [DocumentSummary] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? summaries : summaries.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }

    func load() {
        perform({ try $0.documents() }) { self.summaries = $0 }
    }

    func open(_ document: DocumentSummary) {
        perform({ try $0.document(document.id) }) { value in
            self.edit(id: document.id, title: value.title, body: value.body)
        }
    }

    func edit(id: String? = nil, title: String = "", body: String = "") {
        self.title = title
        self.body = body
        error = nil
        confirmingDelete = false
        draft = DocumentDraft(documentID: id)
    }

    func save(_ draft: DocumentDraft) {
        let title = self.title
        let body = self.body
        let time = Date().timeIntervalSince1970
        perform({ store in
            try store.saveDocument(draft.documentID, title: title, body: body, at: time)
        }) { _ in
            self.draft = nil
            self.load()
        }
    }

    func remove(_ draft: DocumentDraft) {
        guard let id = draft.documentID else { return }
        perform({ store in
            try store.deleteDocument(id)
        }) { _ in
            self.draft = nil
            self.load()
        }
    }

    private func perform<Value>(_ operation: @escaping (CaptureStore) throws -> Value,
                                then: @escaping (Value) -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        worker.withStore(operation) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let value): then(value)
            case .failure(let error): self.error = String(describing: error)
            }
        }
    }

    func importFile(_ result: Result<URL, Error>) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let url = try result.get()
                let content = try await Task.detached(priority: .userInitiated) {
                    try Self.readImport(url)
                }.value
                edit(title: url.deletingPathExtension().lastPathComponent, body: content)
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    private nonisolated static func readImport(_ url: URL) throws -> String {
        guard ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw StoreError(description: "Choose a .txt, .md, or .markdown file.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw StoreError(description: "Choose a regular text file.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = LocalDocument.maximumBodyBytes
        var data = Data()
        while data.count <= limit {
            let chunk = try file.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw StoreError(description: "Documents can contain up to 2 MiB of text.") }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\\0") else {
            throw StoreError(description: "Choose a UTF-8 text file.")
        }
        return text
    }
}

@MainActor
struct SavedDocumentsView: View {
    @StateObject private var model: DocsModel
    let ready: Bool

    init(worker: CaptureWorker, ready: Bool) {
        _model = StateObject(wrappedValue: DocsModel(worker: worker))
        self.ready = ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search document titles", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 270)
                Spacer()
                Button("Import text…") { model.showingImport = true }
                Button("New document…") { model.edit() }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            List(model.visibleDocuments) { document in
                Button {
                    model.open(document)
                } label: {
                    HStack {
                        Text(document.title).lineLimit(1)
                        Spacer()
                        Text(Date(timeIntervalSince1970: document.updatedAt), style: .date)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .notifdexSurface(.inboxList)
            .overlay {
                if model.visibleDocuments.isEmpty {
                    Text(ready ? "No documents here." : "Opening saved documents…")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
        }
        .disabled(!ready || model.busy)
        .task(id: ready) { if ready { model.load() } }
        .fileImporter(isPresented: $model.showingImport,
                      allowedContentTypes: [.plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }) {
            model.importFile($0)
        }
        .sheet(item: $model.draft) { draft in
            editor(draft)
        }
    }

    private func editor(_ draft: DocumentDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.documentID == nil ? "New document" : "Edit document").font(.headline)
            TextField("Title", text: $model.title)
            TextEditor(text: $model.body)
                .font(.body)
                .accessibilityLabel("Document text")
                .frame(minHeight: 220)
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                if draft.documentID != nil {
                    Button("Delete document…", role: .destructive) { model.confirmingDelete = true }
                }
                Spacer()
                Button("Cancel") { model.draft = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { model.save(draft) }.keyboardShortcut(.defaultAction)
                    .disabled(model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 440)
        .disabled(!ready || model.busy)
        .interactiveDismissDisabled(model.busy)
        .alert("Delete this document?", isPresented: $model.confirmingDelete) {
            Button("Delete", role: .destructive) { model.remove(draft) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
#endif
