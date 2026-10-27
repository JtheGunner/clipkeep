import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct MaintenanceTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let temp: TemporaryDatabase
        let database: Database

        init() throws {
            temp = try TemporaryDatabase()
            database = try temp.open()
        }
    }

    @Test func aPassOnAnEmptyDatabaseDoesNothingAndFailsNothing() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let report = MaintenanceService(database: fixture.database).run(now: base)
        #expect(report == MaintenanceReport())
    }

    @Test func settledSessionsGetTopicsAndAPassCanBeRepeated() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let store = ContentStore(database: fixture.database)
        _ = try store.record(text: "swift actor isolation notes", copiedAt: base)
        _ = try store.record(
            text: "kubectl rollout restart deployment", copiedAt: base.addingTimeInterval(4 * 3_600)
        )
        let service = MaintenanceService(database: fixture.database)
        let later = base.addingTimeInterval(30 * 86_400)
        let first = service.run(now: later)
        #expect(first.failures.isEmpty)
        #expect(first.topicsPlaced == 2)
        #expect(try TopicService(database: fixture.database).topics().count == 2)
        let second = service.run(now: later)
        #expect(second.failures.isEmpty)
        #expect(second.topicsPlaced == 0)
    }

    @Test func missingSessionsAreRebuilt() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        // A bulk import without incremental sessions leaves events unassigned.
        let store = ContentStore(database: fixture.database, sessions: nil)
        _ = try store.record(text: "imported without a session", copiedAt: base)
        let report = MaintenanceService(database: fixture.database).run(now: base)
        #expect(report.sessionsRebuilt)
        #expect(try SessionService(database: fixture.database).sessions().count == 1)
    }

    @Test func deletedItemsAreKeptInsideTheUndoWindowAndPurgedAfterIt() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let store = ContentStore(database: fixture.database)
        let recorded = try store.record(text: "to be deleted", copiedAt: base)
        try ItemActions(database: fixture.database).delete(contentID: recorded.contentID, now: base)
        let service = MaintenanceService(database: fixture.database)
        #expect(service.run(now: base.addingTimeInterval(10 * 86_400)).purged == 0)
        #expect(service.run(now: base.addingTimeInterval(31 * 86_400)).purged == 1)
    }

    @Test func oldContentsGetFingerprints() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let store = ContentStore(database: fixture.database)
        _ = try store.record(text: "an older text without a fingerprint yet", copiedAt: base)
        try fixture.database.write { try $0.execute("UPDATE contents SET simhash = NULL") }
        let report = MaintenanceService(database: fixture.database).run(now: base)
        #expect(report.indexed == 1)
    }

    @Test func aFailingStepDoesNotStopTheOthers() throws {
        let fixture = try Fixture()
        defer { fixture.temp.remove() }
        let store = ContentStore(database: fixture.database)
        _ = try store.record(text: "a settled session needing a topic", copiedAt: base)
        let recorded = try store.record(
            text: "deleted long ago", copiedAt: base.addingTimeInterval(4 * 3_600))
        try ItemActions(database: fixture.database).delete(contentID: recorded.contentID, now: base)
        // Break the topic step only.
        try fixture.database.write {
            try $0.execute(
                "CREATE TRIGGER fail_topics BEFORE INSERT ON topics BEGIN SELECT RAISE(ABORT, 'broken'); END"
            )
        }
        let report = MaintenanceService(database: fixture.database).run(
            now: base.addingTimeInterval(40 * 86_400))
        #expect(report.failures.contains("topics"))
        #expect(report.purged == 1)
    }
}
