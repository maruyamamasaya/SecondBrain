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

    @Test func defaultCatalogV2KeepsStudyAndAddsStudyApp() throws {
        let apps = try SecondBrainDefaultApps.all(createdAt: Date(timeIntervalSince1970: 100))
        #expect(SecondBrainDefaultApps.catalogVersion == 2)
        #expect(SecondBrainDefaultApps.sharedMemoID.uuidString == "40000000-0000-4000-8000-000000000001")
        #expect(SecondBrainDefaultApps.myWikiID.uuidString == "40000000-0000-4000-8000-000000000002")
        #expect(SecondBrainDefaultApps.studyID.uuidString == "40000000-0000-4000-8000-000000000003")
        #expect(SecondBrainDefaultApps.toolID.uuidString == "40000000-0000-4000-8000-000000000004")
        #expect(SecondBrainDefaultApps.studyAppID.uuidString == "40000000-0000-4000-8000-000000000005")
        #expect(apps.map(\.id) == [SecondBrainDefaultApps.sharedMemoID, SecondBrainDefaultApps.myWikiID, SecondBrainDefaultApps.studyID, SecondBrainDefaultApps.studyAppID, SecondBrainDefaultApps.toolID])
        #expect(apps.map(\.name) == ["Shared Memo", "My Wiki", "Study", "Study App", "Tool"])
        #expect(apps.map(\.sortOrder) == [10, 20, 30, 35, 40])
        #expect(apps.map(\.isFavorite) == [true, true, false, false, false])
        #expect(apps[2].launchTarget.storageValue == "https://maruyamamasaya.github.io/study/#/")
        #expect(apps[3].launchTarget.storageValue == "https://study-app-maruyama.maruyama-001.chatgpt.site/")

        let previewFixtures = try SecondBrainAppFixtures.samples()
        #expect(Set(previewFixtures.map(\.id)).isDisjoint(with: Set(apps.map(\.id))))
    }

    @Test func defaultSeedIsMissingOnlyAndDeletionDoesNotRestoreApp() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        do {
            let repository = try fixture.repository()
            let defaults = try repository.fetchAllApps()
            #expect(defaults.map(\.id) == [SecondBrainDefaultApps.sharedMemoID, SecondBrainDefaultApps.myWikiID, SecondBrainDefaultApps.studyID, SecondBrainDefaultApps.studyAppID, SecondBrainDefaultApps.toolID])

            let sharedMemo = try #require(repository.fetchApp(id: SecondBrainDefaultApps.sharedMemoID))
            let edited = try SecondBrainApp(
                id: sharedMemo.id,
                name: "自分用メモ",
                description: "自分で編集した説明",
                icon: "star",
                kind: sharedMemo.kind,
                launchTarget: .webURL("https://example.com/edited?mode=1#section"),
                category: "自分用",
                isFavorite: false,
                sortOrder: 15,
                createdAt: sharedMemo.createdAt,
                updatedAt: sharedMemo.updatedAt.addingTimeInterval(100)
            )
            try repository.updateApp(edited)
            try repository.deleteApp(id: SecondBrainDefaultApps.toolID)
            #expect(try repository.seedDefaultAppsIfNeeded(now: sharedMemo.updatedAt.addingTimeInterval(200)) == 0)
            #expect(try repository.fetchApp(id: sharedMemo.id) == edited)
            #expect(try repository.fetchApp(id: SecondBrainDefaultApps.toolID) == nil)
        }

        let reopened = try fixture.repository()
        #expect(try reopened.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.name == "自分用メモ")
        #expect(try reopened.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.description == "自分で編集した説明")
        #expect(try reopened.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.icon == "star")
        #expect(try reopened.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.launchTarget.storageValue == "https://example.com/edited?mode=1#section")
        #expect(try reopened.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.category == "自分用")
        #expect(try reopened.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.isFavorite == false)
        #expect(try reopened.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.sortOrder == 15)
        #expect(try reopened.fetchApp(id: SecondBrainDefaultApps.toolID) == nil)
        #expect(try reopened.fetchAllApps().count == 4)
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
        #expect(Array(try repository.fetchAllApps().prefix(2).map(\.id)) == [secondID, firstID])
        #expect(try repository.fetchApp(id: secondID)?.isFavorite == true)

        let updated = try SecondBrainApp(id: firstID, name: "Updated", description: "changed", icon: "hammer", kind: .external, launchTarget: .deepLink("github://repositories"), category: "Developer Tools", isFavorite: true, sortOrder: 0, createdAt: createdAt, updatedAt: later)
        try repository.updateApp(updated)
        #expect(Array(try repository.fetchAllApps().prefix(2).map(\.name)) == ["Updated", "First"])
        #expect(try repository.fetchApp(id: firstID) == updated)

        let changedCreation = try SecondBrainApp(id: firstID, name: "Invalid history", kind: .web, launchTarget: .webURL("https://example.com"), createdAt: later, updatedAt: later)
        #expect(throws: SecondBrainAppRepositoryError.createdAtChanged(firstID)) { try repository.updateApp(changedCreation) }
        #expect(throws: SecondBrainAppRepositoryError.duplicateID(firstID)) { try repository.createApp(updated) }
        try repository.deleteApp(id: secondID)
        #expect(try repository.fetchApp(id: secondID) == nil)
        #expect(throws: SecondBrainAppRepositoryError.notFound(secondID)) { try repository.deleteApp(id: secondID) }
    }

    @Test func preservesURLQueriesAndFragmentsThroughSQLiteRoundTrip() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let values = [
            "https://example.com/",
            "https://example.com/path/",
            "https://example.com/#/",
            "https://example.com/#/page",
            "https://example.com/path?mode=1#section"
        ]

        for (index, value) in values.enumerated() {
            let app = try SecondBrainApp(name: "URL \(index)", kind: .web, launchTarget: .webURL(value), sortOrder: 100 + index)
            try repository.createApp(app)
            #expect(try repository.fetchApp(id: app.id)?.launchTarget.storageValue == value)
        }

        #expect(try repository.fetchApp(id: SecondBrainDefaultApps.studyID)?.launchTarget.storageValue == "https://maruyamamasaya.github.io/study/#/")
        #expect(try repository.fetchApp(id: SecondBrainDefaultApps.studyAppID)?.launchTarget.storageValue == "https://study-app-maruyama.maruyama-001.chatgpt.site/")
    }

    @Test func catalogV2AddsOnlyStudyAppToExistingV1Database() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }

        do {
            let repository = try fixture.repository()
            let study = try #require(repository.fetchApp(id: SecondBrainDefaultApps.studyID))
            try repository.updateApp(SecondBrainApp(
                id: study.id,
                name: "編集済みStudy",
                description: study.description,
                icon: study.icon,
                kind: study.kind,
                launchTarget: study.launchTarget,
                category: study.category,
                isFavorite: study.isFavorite,
                sortOrder: study.sortOrder,
                createdAt: study.createdAt,
                updatedAt: study.updatedAt.addingTimeInterval(1)
            ))
        }
        try fixture.prepareCatalogV1()

        let upgraded = try fixture.repository()
        #expect(try upgraded.fetchAllApps().map(\.id) == [SecondBrainDefaultApps.sharedMemoID, SecondBrainDefaultApps.myWikiID, SecondBrainDefaultApps.studyID, SecondBrainDefaultApps.studyAppID, SecondBrainDefaultApps.toolID])
        #expect(try upgraded.fetchApp(id: SecondBrainDefaultApps.studyID)?.name == "編集済みStudy")
        #expect(try upgraded.fetchApp(id: SecondBrainDefaultApps.myWikiID) != nil)
        #expect(try upgraded.fetchApp(id: SecondBrainDefaultApps.studyAppID)?.launchTarget.storageValue == "https://study-app-maruyama.maruyama-001.chatgpt.site/")
        #expect(try fixture.defaultSeedHistoryCount() == 5)
        #expect(try fixture.defaultSeedCatalogVersions() == [1, 2])
    }

    @Test func migratesSchemaV21SeedsMissingDefaultsAndPreservesExistingRecords() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let thought = Thought(id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!, body: "migrationで保持するThought", createdAt: Date(timeIntervalSince1970: 10))

        do {
            let repository = try fixture.repository()
            try repository.create(thought)
            let sharedMemo = try #require(repository.fetchApp(id: SecondBrainDefaultApps.sharedMemoID))
            try repository.updateApp(SecondBrainApp(id: sharedMemo.id, name: "編集済みShared Memo", description: sharedMemo.description, icon: sharedMemo.icon, kind: sharedMemo.kind, launchTarget: .webURL("https://example.com/custom/#/"), category: sharedMemo.category, isFavorite: false, sortOrder: 11, createdAt: sharedMemo.createdAt, updatedAt: sharedMemo.updatedAt.addingTimeInterval(1)))
            #expect(SQLiteThoughtRepository.schemaVersion == 22)
        }
        try fixture.prepareV21KeepingOnlyApp(id: SecondBrainDefaultApps.sharedMemoID)

        let migrated = try fixture.repository()
        #expect(try fixture.sqliteUserVersion() == 22)
        #expect(try migrated.fetchAll().map(\.id).contains(thought.id))
        #expect(try migrated.fetchAllApps().count == 5)
        #expect(try migrated.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.name == "編集済みShared Memo")
        #expect(try migrated.fetchApp(id: SecondBrainDefaultApps.sharedMemoID)?.launchTarget.storageValue == "https://example.com/custom/#/")
        #expect(try migrated.fetchApp(id: SecondBrainDefaultApps.myWikiID) != nil)
        #expect(try fixture.defaultSeedHistoryCount() == 5)
        #expect(try fixture.defaultSeedCatalogVersions() == [2])
        #expect(try fixture.tableColumns("secondbrain_apps").isSuperset(of: ["id", "name", "kind", "launch_target_type", "launch_target_value", "is_favorite", "sort_order"]))
    }

    @Test func migratesSchemaV20ThroughV22WithoutChangingThoughts() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let thought = Thought(body: "v20から保持するThought", createdAt: Date(timeIntervalSince1970: 20))
        do {
            let repository = try fixture.repository()
            try repository.create(thought)
        }
        try fixture.removeAppsTablesAndMarkV20()

        let migrated = try fixture.repository()
        #expect(try fixture.sqliteUserVersion() == 22)
        #expect(try migrated.fetchAll().contains(where: { $0.id == thought.id }))
        #expect(try migrated.fetchAllApps().map(\.id) == [SecondBrainDefaultApps.sharedMemoID, SecondBrainDefaultApps.myWikiID, SecondBrainDefaultApps.studyID, SecondBrainDefaultApps.studyAppID, SecondBrainDefaultApps.toolID])
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

    func prepareV21KeepingOnlyApp(id: UUID) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let sql = "DROP TABLE secondbrain_default_app_seed_history; DELETE FROM secondbrain_apps WHERE id <> '\(id.uuidString)'; PRAGMA user_version = 21;"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func removeAppsTablesAndMarkV20() throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let sql = "DROP TABLE secondbrain_default_app_seed_history; DROP TABLE secondbrain_apps; PRAGMA user_version = 20;"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func prepareCatalogV1() throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let sql = "DELETE FROM secondbrain_default_app_seed_history WHERE app_id = '\(SecondBrainDefaultApps.studyAppID.uuidString)'; DELETE FROM secondbrain_apps WHERE id = '\(SecondBrainDefaultApps.studyAppID.uuidString)'; UPDATE secondbrain_default_app_seed_history SET catalog_version = 1;"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func defaultSeedHistoryCount() throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM secondbrain_default_app_seed_history", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteThoughtRepositoryError.invalidRecord }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func defaultSeedCatalogVersions() throws -> Set<Int> {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT DISTINCT catalog_version FROM secondbrain_default_app_seed_history", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var versions = Set<Int>()
        while sqlite3_step(statement) == SQLITE_ROW {
            versions.insert(Int(sqlite3_column_int(statement, 0)))
        }
        return versions
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
