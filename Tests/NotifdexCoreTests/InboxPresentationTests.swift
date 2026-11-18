import XCTest
@testable import NotifdexCore

final class InboxPresentationTests: XCTestCase {
    func testRecentAndGroupedLayoutsKeepTheSameFilteredRows() throws {
        let store = try CaptureStore(path: ":memory:")
        let run = try store.startRun(at: 1)
        for (index, app) in ["Gmail", "Twitter", "Messages", "X"].enumerated() {
            try store.record(Observation(sourceID: "fixture", sourceEventID: String(index),
                                         capturedAt: Double(index + 2),
                                         description: "\(app), Example, Sample, from iPhone",
                                         title: "Example", body: "Sample"), runID: run)
        }
        let rows = try store.inbox(InboxQuery(search: "Sample"))
        var layout = InboxPresentation()
        XCTAssertEqual(layout.sections(for: rows).flatMap(\.rows).map(\.id), rows.map(\.id))
        layout.order = .byApp
        XCTAssertEqual(layout.sections(for: rows).compactMap(\.app), ["Gmail", "Messages", "X"])
        let xRows = rows.filter { $0.app == "X" }.map(\.id)
        XCTAssertEqual(layout.sections(for: rows).last?.rows.map(\.id), xRows)

        layout.toggle("X")
        let collapsed = try XCTUnwrap(layout.sections(for: rows).last)
        XCTAssertFalse(collapsed.expanded)
        XCTAssertEqual(collapsed.rows.map(\.id), xRows)
        layout.order = .recent
        XCTAssertTrue(layout.sections(for: rows)[0].expanded)
        XCTAssertEqual(layout.sections(for: rows)[0].rows.map(\.id), rows.map(\.id))
        layout.order = .byApp
        XCTAssertEqual(layout.sections(for: rows).last?.expanded, false)
        layout.toggle("X")
        XCTAssertEqual(layout.sections(for: rows).last?.expanded, true)
    }
}
