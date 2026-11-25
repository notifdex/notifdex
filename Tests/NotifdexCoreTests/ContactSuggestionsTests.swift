import Foundation
import XCTest
@testable import NotifdexCore

final class ContactSuggestionsTests: XCTestCase {
    private func makeEntry(
        id: Int64 = 1,
        app: String = "Messages",
        title: String,
        personID: String? = nil,
        personName: String = ""
    ) -> InboxEntry {
        InboxEntry(
            id: id,
            app: app,
            title: title,
            subtitle: "",
            body: "Hello",
            capturedAt: 100,
            saved: false,
            dueAt: nil,
            done: false,
            personID: personID,
            personName: personName,
            subject: "",
            individuallyHidden: false,
            titleFiltered: false,
            bodyFiltered: false,
            isRead: false,
            isFlagged: false,
            personRuleID: nil,
            workspaceID: nil
        )
    }

    func testSuggestsSavedHandleBeforeDisplayName() {
        let maya = PersonRecord(id: "p-maya", name: "Maya Lin")
        let alex = PersonRecord(id: "p-alex", name: "Alex Chen")
        let identities: [String: [PersonIdentity]] = [
            maya.id: [PersonIdentity(id: "id-1", platform: "Messages", identifier: "+1 (415) 555-0192")],
            alex.id: [PersonIdentity(id: "id-2", platform: "X", identifier: "alexchen")]
        ]

        let phoneAlert = makeEntry(app: "Messages", title: "+1 415-555-0192")
        let phoneSuggestion = ContactSuggestions.suggest(
            for: phoneAlert,
            people: [maya, alex],
            identitiesByPerson: identities
        )
        XCTAssertEqual(
            phoneSuggestion,
            .single(PersonSuggestion(person: maya, reason: .savedHandle(platform: "Messages")))
        )

        let xAlert = makeEntry(app: "X", title: "@AlexChen")
        let xSuggestion = ContactSuggestions.suggest(
            for: xAlert,
            people: [maya, alex],
            identitiesByPerson: identities
        )
        XCTAssertEqual(
            xSuggestion,
            .single(PersonSuggestion(person: alex, reason: .savedHandle(platform: "X")))
        )
    }

    func testSuggestsUniqueDisplayNameAndFlagsAmbiguousNames() {
        let alex1 = PersonRecord(id: "p-1", name: "Alex Chen")
        let alex2 = PersonRecord(id: "p-2", name: "Alex Chen")
        let alert = makeEntry(app: "Messages", title: "alex chen")

        XCTAssertEqual(
            ContactSuggestions.suggest(for: alert, people: [alex1], identitiesByPerson: [:]),
            .single(PersonSuggestion(person: alex1, reason: .displayName))
        )

        XCTAssertEqual(
            ContactSuggestions.suggest(for: alert, people: [alex1, alex2], identitiesByPerson: [:]),
            .ambiguous([alex1, alex2])
        )

        let linked = makeEntry(app: "Messages", title: "Alex Chen", personID: alex1.id, personName: alex1.name)
        XCTAssertNil(ContactSuggestions.suggest(for: linked, people: [alex1], identitiesByPerson: [:]))

        let blank = makeEntry(app: "Messages", title: "   ")
        XCTAssertNil(ContactSuggestions.suggest(for: blank, people: [alex1], identitiesByPerson: [:]))
    }

    func testIdentifierDetectionInitialsAndDefaultPlatform() {
        XCTAssertTrue(ContactSuggestions.looksLikeIdentifier("+1 (415) 555-0192"))
        XCTAssertTrue(ContactSuggestions.looksLikeIdentifier("415-555-0192"))
        XCTAssertTrue(ContactSuggestions.looksLikeIdentifier("maya@studio.co"))
        XCTAssertTrue(ContactSuggestions.looksLikeIdentifier("@alexchen"))

        XCTAssertFalse(ContactSuggestions.looksLikeIdentifier("Alex Chen"))
        XCTAssertFalse(ContactSuggestions.looksLikeIdentifier("Maya"))
        XCTAssertFalse(ContactSuggestions.looksLikeIdentifier("Liked by Alex"))
        XCTAssertFalse(ContactSuggestions.looksLikeIdentifier("2026"))
        XCTAssertFalse(ContactSuggestions.looksLikeIdentifier("   "))

        XCTAssertEqual(ContactSuggestions.initials(for: "Alex Chen"), "AC")
        XCTAssertEqual(ContactSuggestions.initials(for: "Maya"), "MA")
        XCTAssertEqual(ContactSuggestions.initials(for: "  J. R. Smith "), "JS")
        XCTAssertEqual(ContactSuggestions.initials(for: ""), "?")

        XCTAssertEqual(ContactSuggestions.defaultPlatform(for: "Twitter"), "X")
        XCTAssertEqual(ContactSuggestions.defaultPlatform(for: "Messages"), "Messages")
        XCTAssertEqual(ContactSuggestions.defaultPlatform(for: "WhatsApp"), "WhatsApp")
        XCTAssertEqual(ContactSuggestions.defaultPlatform(for: "Unknown app"), "Messages")
    }

    func testRenameAndDeletePersonPreserveObservations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try CaptureStore(path: folder.appendingPathComponent("capture.db").path)
        let run = try store.startRun(at: 1)
        try store.record(
            Observation(
                sourceID: "mac",
                sourceEventID: "msg-1",
                capturedAt: 2,
                description: "Messages, Alex, Coffee?, from iPhone",
                title: "Alex",
                body: "Coffee?"
            ),
            runID: run
        )
        let obsID = try XCTUnwrap(store.inbox(InboxQuery()).first?.id)
        let wsID = try store.createWorkspace(name: "Founders")
        let personID = try store.createPerson(name: "Alex", linking: obsID, workspace: wsID)
        try store.addIdentity(person: personID, platform: "Messages", identifier: "+14155550192")
        try store.addPersonNote(person: personID, title: "Intro", body: "Met at demo day", at: 3)
        let preview = try store.previewPersonMatch(for: obsID)
        try store.confirmPersonMatch(preview, includeExisting: true)

        try store.renamePerson(personID, to: "Alex Rivera")
        XCTAssertEqual(try store.people().first?.name, "Alex Rivera")
        XCTAssertEqual(try store.inbox(InboxQuery()).first?.personName, "Alex Rivera")

        XCTAssertThrowsError(try store.renamePerson(personID, to: "   "))
        XCTAssertThrowsError(try store.renamePerson("missing-id", to: "Someone"))

        try store.deletePerson(personID)
        XCTAssertTrue(try store.people().isEmpty)
        XCTAssertTrue(try store.allIdentitiesByPerson().isEmpty)
        let remaining = try store.inbox(InboxQuery())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, obsID)
        XCTAssertNil(remaining.first?.personID)
    }

    func testCreatePersonWithIdentityAndRememberMatchIsAtomic() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try CaptureStore(path: folder.appendingPathComponent("capture.db").path)
        let run = try store.startRun(at: 1)
        try store.record(
            Observation(
                sourceID: "mac",
                sourceEventID: "m1",
                capturedAt: 2,
                description: "Messages, +1 (415) 555-0192, First ping, from iPhone",
                title: "+1 (415) 555-0192",
                body: "First ping"
            ),
            runID: run
        )
        let obs1 = try XCTUnwrap(store.inbox(InboxQuery(search: "First ping")).first?.id)
        let wsID = try store.createWorkspace(name: "Personal")

        let mayaID = try store.createPerson(
            name: "Maya Lin",
            linking: obs1,
            workspace: wsID,
            identity: (platform: "Messages", identifier: "+1 (415) 555-0192"),
            rememberMatch: true
        )
        XCTAssertEqual(try store.identities(for: mayaID).first?.identifier, "+1 (415) 555-0192")
        XCTAssertEqual(try store.personMatchRules(for: mayaID).count, 1)
        XCTAssertEqual(try store.workspaceIDs(for: mayaID), [wsID])

        let grouped = try store.allIdentitiesByPerson()
        XCTAssertEqual(grouped[mayaID]?.count, 1)

        // Future matching alert links automatically via the created rule.
        try store.record(
            Observation(
                sourceID: "mac",
                sourceEventID: "m2",
                capturedAt: 3,
                description: "Messages, +1 (415) 555-0192, Second ping, from iPhone",
                title: "+1 (415) 555-0192",
                body: "Second ping"
            ),
            runID: run
        )
        let linkedAlerts = try store.inbox(InboxQuery(scope: .person(mayaID)))
        XCTAssertEqual(linkedAlerts.count, 2)

        // Duplicate identity must roll back the entire creation without leaving an orphan person.
        XCTAssertThrowsError(
            try store.createPerson(
                name: "Duplicate Maya",
                linking: nil,
                workspace: nil,
                identity: (platform: "Messages", identifier: "+1 (415) 555-0192"),
                rememberMatch: false
            )
        )
        XCTAssertEqual(try store.people().map(\.name), ["Maya Lin"])
    }
}
