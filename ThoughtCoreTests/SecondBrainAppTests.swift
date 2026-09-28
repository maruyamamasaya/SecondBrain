import Foundation
import Testing
@testable import ThoughtCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

@Suite("Apps / Tools Hub")
struct SecondBrainAppTests {
    @Test func validatesNamesOrderingURLsAndKindCombinations() throws {
        #expect(throws: SecondBrainAppValidationError.emptyName) {
            try SecondBrainApp(name: " \n ", kind: .web, launchTarget: .webURL("https://example.com"))
        }
        #expect(throws: SecondBrainAppValidationError.invalidSortOrder) {
            try SecondBrainApp(name: "Invalid order", kind: .web, launchTarget: .webURL("https://example.com"), sortOrder: -1)
        }
        #expect(throws: SecondBrainAppValidationError.invalidURL) {
            try SecondBrainApp(name: "Invalid URL", kind: .web, launchTarget: .webURL("not a url"))
        }
        #expect(throws: SecondBrainAppValidationError.insecureWebURL) {
            try SecondBrainApp(name: "HTTP Web", kind: .web, launchTarget: .webURL("http://example.com"))
        }
        #expect(throws: SecondBrainAppValidationError.nonLocalURL) {
            try SecondBrainApp(name: "Remote Local Web", kind: .localWeb, launchTarget: .localURL("http://example.com"))
        }
        #expect(throws: SecondBrainAppValidationError.dangerousScheme) {
            try SecondBrainApp(name: "Dangerous", kind: .external, launchTarget: .deepLink("javascript:alert(1)"))
        }
        #expect(throws: SecondBrainAppValidationError.incompatibleLaunchTarget) {
            try SecondBrainApp(name: "Mismatch", kind: .native, launchTarget: .webURL("https://example.com"))
        }

        let local = try SecondBrainApp(name: "Local", kind: .localWeb, launchTarget: .localURL("http://192.168.1.10:8080"))
        let secureWeb = try SecondBrainApp(name: "Secure", kind: .web, launchTarget: .webURL("https://example.com/tool"))
        let deepLink = try SecondBrainApp(name: "External", kind: .external, launchTarget: .deepLink("github://notifications"))
        #expect(local.kind == .localWeb)
        #expect(secureWeb.launchTarget.storageKind == .webURL)
        #expect(deepLink.launchTarget.storageValue == "github://notifications")
    }

    @Test func fixturesAreStableAndAreNotAutomaticallySeeded() throws {
        let apps = try SecondBrainAppFixtures.samples()
        #expect(apps.map(\.name) == ["HomeMuseum", "Baby Media", "GitHub Monitor"])
        #expect(apps.map(\.sortOrder) == [0, 1, 2])
        #expect(apps[1].kind == .localWeb)

        let fixture = try AppFixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        #expect(try repository.fetchAllApps().isEmpty)
    }

    @Test func sqliteCreatesUpdatesOrdersFavoritesAndDeletesApps() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let createdAt = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let firstID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let first = try SecondBrainApp(id: firstID, name: "Later", kind: .web, launchTarget: .webURL("https://example.com/later"), sortOrder: 2, createdAt: createdAt)
        let second = try SecondBrainApp(id: secondID, name: "First", kind: .localWeb, launchTarget: .localURL("http://localhost:3000"), isFavorite: true, sortOrder: 1, createdAt: createdAt)

        try repository.createApp(first)
        try repository.createApp(second)
        #expect(try repository.fetchAllApps().map(\.id) == [secondID, firstID])
        #expect(try repository.fetchApp(id: secondID)?.isFavorite == true)

        let updated = try SecondBrainApp(id: firstID, name: "Updated", description: "changed", icon: "hammer", kind: .external, launchTarget: .deepLink("github://repositories"), category: "Developer Tools", isFavorite: true, sortOrder: 0, createdAt: createdAt, updatedAt: later)
        try repository.updateApp(updated)
        #expect(try repository.fetchAllApps().map(\.name) == ["Updated", "First"])
        #expect(try repository.fetchApp(id: firstID) == updated)

        let changedCreation = try SecondBrainApp(id: firstID, name: "Invalid history", kind: .web, launchTarget: .webURL("https://example.com"), createdAt: later, updatedAt: later)
        #expect(throws: SecondBrainAppRepositoryError.createdAtChanged(firstID)) { try repository.updateApp(changedCreation) }
        #expect(throws: SecondBrainAppRepositoryError.duplicateID(firstID)) { try repository.createApp(updated) }
        try repository.deleteApp(id: secondID)
        #expect(try repository.fetchApp(id: secondID) == nil)
        #expect(throws: SecondBrainAppRepositoryError.notFound(secondID)) { try repository.deleteApp(id: secondID) }
    }

    @Test func migratesSchemaV20WithoutChangingThoughtsOrSeedingApps() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let thought = Thought(id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!, body: "migrationで保持するThought", createdAt: Date(timeIntervalSince1970: 10))

        do {
            let repository = try fixture.repository()
            try repository.create(thought)
            #expect(SQLiteThoughtRepository.schemaVersion == 21)
        }
        try fixture.removeAppsTableAndMarkV20()

        let migrated = try fixture.repository()
        #expect(try fixture.sqliteUserVersion() == 21)
        #expect(try migrated.fetchAll().map(\.id).contains(thought.id))
        #expect(try migrated.fetchAllApps().isEmpty)
        #expect(try fixture.tableColumns("secondbrain_apps").isSuperset(of: ["id", "name", "kind", "launch_target_type", "launch_target_value", "is_favorite", "sort_order"]))
    }
}

private struct AppFixture {
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("thought-timeline.sqlite3") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("secondbrain-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func repository() throws -> SQLiteThoughtRepository {
        try SQLiteThoughtRepository(databaseURL: databaseURL)
    }

    func removeAppsTableAndMarkV20() throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let sql = "DROP TABLE secondbrain_apps; PRAGMA user_version = 20;"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func tableColumns(_ table: String) throws -> Set<String> {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }
        return columns
    }

    func sqliteUserVersion() throws -> Int32 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteThoughtRepositoryError.invalidRecord }
        return sqlite3_column_int(statement, 0)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
