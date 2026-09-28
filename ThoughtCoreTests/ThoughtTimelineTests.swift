import Foundation
import Testing
@testable import ThoughtCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

private actor RecordingReviewSummaryClient: ReviewSummaryClient {
    private var requests: [ReviewSummaryRequest] = []

    func generateSummary(_ request: ReviewSummaryRequest) async throws -> ReviewSummaryResponse {
        requests.append(request)
        return ReviewSummaryResponse(text: "記録した要約", provider: "test", model: "recording")
    }

    func recordedRequests() -> [ReviewSummaryRequest] { requests }
}

private struct ReviewSummaryTransportCall: Equatable, Sendable {
    let prompt: String
    let modelName: String
    let generationProfile: AIGenerationProfile
}

private actor RecordingReviewSummaryTransport: ReviewSummaryGeneratingTransport {
    private let response: String?
    private let error: ReviewSummaryServiceError?
    private var calls: [ReviewSummaryTransportCall] = []

    init(response: String? = "Firebaseの要約", error: ReviewSummaryServiceError? = nil) {
        self.response = response
        self.error = error
    }

    func generateContent(prompt: String, modelName: String, generationProfile: AIGenerationProfile) async throws -> String? {
        calls.append(ReviewSummaryTransportCall(prompt: prompt, modelName: modelName, generationProfile: generationProfile))
        if let error { throw error }
        return response
    }

    func recordedCalls() -> [ReviewSummaryTransportCall] { calls }
}

@Suite("Thought timeline", .serialized)
struct ThoughtTimelineTests {
    @Test func createSupportsBoundariesAndUnicode() throws {
        let repository = MemoryThoughtRepository()
        var timeline = try ThoughtTimeline(repository: repository)

        #expect(try timeline.post("a")?.body == "a")
        #expect(try timeline.post("日本語")?.body == "日本語")
        #expect(try timeline.post("🚀")?.body == "🚀")
        let maximum = String(repeating: "あ", count: 140)
        #expect(try timeline.post(maximum)?.body == maximum)
        #expect(try timeline.post("") == nil)
        #expect(try timeline.post(" \n\t ") == nil)
        #expect(try timeline.post(String(repeating: "a", count: 141)) == nil)
    }

    @Test func limitsDraftByUserPerceivedCharacters() {
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 141)
        #expect(ThoughtDraft.limited(emoji).count == 140)
    }

    @Test func trimsEdgesAndPreservesUnicode() throws {
        var timeline = try ThoughtTimeline(repository: MemoryThoughtRepository())
        #expect(try timeline.post("  日本語 English 123 🚀\n")?.body == "日本語 English 123 🚀")
    }

    @Test func postingAddsNewThoughtAtTimelineTop() throws {
        var timeline = try ThoughtTimeline(repository: MemoryThoughtRepository())
        try timeline.post("first", now: Date(timeIntervalSince1970: 100))
        try timeline.post("newest", now: Date(timeIntervalSince1970: 200))
        #expect(timeline.thoughts.map(\.body) == ["newest", "first"])
    }

    @Test func timelineLoadsFiftyThoughtPagesOnDemand() throws {
        let records = (0..<105).map { index in
            Thought(body: "thought-\(index)", createdAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let repository = MemoryThoughtRepository(records: records)
        var timeline = try ThoughtTimeline(repository: repository)

        #expect(timeline.thoughts.count == 50)
        #expect(timeline.thoughts.first?.body == "thought-104")
        #expect(timeline.hasMore)

        let secondPage = try timeline.loadMore()
        #expect(secondPage.count == 50)
        #expect(timeline.thoughts.count == 100)
        #expect(timeline.hasMore)

        let finalPage = try timeline.loadMore()
        #expect(finalPage.count == 5)
        #expect(timeline.thoughts.last?.body == "thought-0")
        #expect(!timeline.hasMore)
        #expect(try timeline.loadMore().isEmpty)
    }

    @Test func sqliteTimelinePageUsesStableDateAndIDCursor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let date = Date(timeIntervalSince1970: 200)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        ]
        for (index, id) in ids.enumerated() {
            try repository.create(Thought(id: id, body: "same-date-\(index)", createdAt: date))
        }
        try repository.create(Thought(body: "older", createdAt: Date(timeIntervalSince1970: 100)))

        let firstPage = try repository.fetchTimelinePage(limit: 2, before: nil)
        let secondPage = try repository.fetchTimelinePage(limit: 2, before: firstPage.last)

        #expect(firstPage.map(\.id) == [ids[2], ids[1]])
        #expect(secondPage.map(\.body) == ["same-date-0", "older"])
    }

    @Test func sqliteCreatesReadsAndUsesStableQueryOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let date = Date(timeIntervalSince1970: 200)
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        try repository.create(Thought(id: low, body: "low", createdAt: date))
        try repository.create(Thought(id: high, body: "high", createdAt: date))
        try repository.create(Thought(body: "older", createdAt: Date(timeIntervalSince1970: 100)))

        #expect(try repository.fetchByID(low)?.body == "low")
        #expect(try repository.fetchTimeline().map(\.body) == ["high", "low", "older"])
    }

    @Test func softDeleteSetsTimestampAndExcludesTimeline() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let thought = Thought(body: "delete me")
        let deletion = Date(timeIntervalSince1970: 500)
        try repository.create(thought)

        #expect(try repository.softDelete(id: thought.id, at: deletion))
        #expect(try repository.fetchByID(thought.id)?.deletedAt == deletion)
        #expect(try repository.fetchTimeline().isEmpty)
        #expect(try repository.fetchAll().count == 1)
    }

    @Test func sqliteSurvivesRepositoryRecreation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.repository().create(Thought(body: "persisted 🚀"))
        #expect(try fixture.repository().fetchTimeline().map(\.body) == ["persisted 🚀"])
    }

    @Test func sqliteKeepsOnlyTwoRollingBackups() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        try repository.create(Thought(body: "one"))
        try repository.create(Thought(body: "two"))
        try repository.create(Thought(body: "three"))

        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.appendingPathExtension("backup.1").path))
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.appendingPathExtension("backup.2").path))
        let backupFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.contains(".backup.") }
        #expect(backupFiles.count == 2)
    }

    @Test(arguments: [[], [Thought(body: "migrated 日本語 🚀")]])
    func migratesLegacyJSONIncludingEmptyFile(thoughts: [Thought]) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacyJSON(thoughts)
        let repository = try fixture.repository()
        #expect(try repository.fetchAll().map(\.id) == thoughts.map(\.id))
        #expect(try repository.fetchAll().map(\.body) == thoughts.map(\.body))
        #expect(FileManager.default.fileExists(atPath: fixture.jsonURL.path))
    }

    @Test func runningMigrationTwiceDoesNotDuplicate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let thought = Thought(body: "only once")
        try fixture.writeLegacyJSON([thought])
        #expect(try fixture.repository().fetchAll().count == 1)
        #expect(try fixture.repository().fetchAll().count == 1)
    }

    @Test func failedMigrationRetainsLegacyJSON() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not-json".utf8).write(to: fixture.jsonURL)
        #expect(throws: SQLiteThoughtRepositoryError.self) { try fixture.repository() }
        #expect(FileManager.default.fileExists(atPath: fixture.jsonURL.path))
        #expect(try String(contentsOf: fixture.jsonURL, encoding: .utf8) == "not-json")
    }
}

@Suite("Thought search", .serialized)
struct ThoughtSearchTests {
    @Test func findsLiteralSubstringsNewestFirstAndExcludesOtherAndDeletedThoughts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let oldest = Thought(body: "Search target oldest", createdAt: Date(timeIntervalSince1970: 100))
        let unrelated = Thought(body: "another Thought", createdAt: Date(timeIntervalSince1970: 200))
        let newest = Thought(body: "newest TARGET match", createdAt: Date(timeIntervalSince1970: 300))
        let deleted = Thought(body: "deleted target", createdAt: Date(timeIntervalSince1970: 400))
        for thought in [oldest, unrelated, newest, deleted] { try repository.create(thought) }
        #expect(try repository.softDelete(id: deleted.id, at: Date(timeIntervalSince1970: 500)))

        #expect(try repository.search(query: "target").map(\.id) == [newest.id, oldest.id])
        #expect(try repository.search(query: "missing").isEmpty)
    }

    @Test func trimsWhitespaceAndTreatsLikeMetacharactersLiterally() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let percent = Thought(body: "進捗は100%です")
        let percentWildcardTrap = Thought(body: "進捗は100Xです")
        let underscore = Thought(body: "literal_name")
        let wildcardOnly = Thought(body: "unrelated")
        for thought in [percent, percentWildcardTrap, underscore, wildcardOnly] { try repository.create(thought) }

        #expect(try repository.search(query: "  100% \n").map(\.id) == [percent.id])
        #expect(try repository.search(query: "_").map(\.id) == [underscore.id])
        #expect(try repository.search(query: "  \n\t ").isEmpty)
    }

    @Test func searchesUnicodeWithoutChangingSQLiteContents() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let japanese = Thought(body: "今日は日本語でメモする 🚀", createdAt: Date(timeIntervalSince1970: 100))
        let other = Thought(body: "English note", createdAt: Date(timeIntervalSince1970: 200))
        try repository.create(japanese)
        try repository.create(other)
        let before = try repository.fetchAll()

        #expect(try repository.search(query: "日本語").map(\.id) == [japanese.id])
        #expect(try repository.fetchAll() == before)
    }

    @Test func memoryRepositoryMatchesSearchContract() throws {
        let older = Thought(body: "Mixed CASE keyword", createdAt: Date(timeIntervalSince1970: 100))
        let newer = Thought(body: "keyword 日本語", createdAt: Date(timeIntervalSince1970: 200))
        let deleted = Thought(body: "keyword deleted", deletedAt: Date(timeIntervalSince1970: 300))
        let repository = MemoryThoughtRepository(records: [older, newer, deleted])

        #expect(try repository.search(query: " KEYWORD ").map(\.id) == [newer.id, older.id])
        #expect(try repository.search(query: "日本語").map(\.id) == [newer.id])
    }
}

@Suite("Thought tags", .serialized)
struct ThoughtTagTests {
    @Test func createsAttachesMultipleNormalizesAndRemovesWithoutChangingBody() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let first = Thought(body: "原文は変更しない", createdAt: Date(timeIntervalSince1970: 100))
        let second = Thought(body: "既存タグを付ける", createdAt: Date(timeIntervalSince1970: 200))
        try repository.create(first)
        try repository.create(second)

        let work: ThoughtTag
        switch try repository.addTag(named: "  Work  ", to: first.id, at: Date(timeIntervalSince1970: 300)) {
        case .added(let tag): work = tag
        default: Issue.record("新規タグが作成されませんでした"); return
        }
        #expect(work.name == "Work")
        #expect(work.normalizedName == "work")
        #expect(try repository.addTag(named: "work", to: first.id) == .alreadyAttached(work))
        #expect(try repository.addTag(named: "WORK", to: second.id) == .added(work))

        let unicode: ThoughtTag
        switch try repository.addTag(named: "日本語🚀", to: first.id) {
        case .added(let tag): unicode = tag
        default: Issue.record("Unicodeタグが作成されませんでした"); return
        }
        #expect(try repository.fetchTags(for: first.id).map(\.id) == [work.id, unicode.id])
        #expect(try repository.fetchAllTags().map(\.id) == [work.id, unicode.id])
        #expect(try repository.fetchByID(first.id)?.body == "原文は変更しない")
        #expect(try repository.addTag(named: "  \n ", to: first.id) == .invalidName)

        #expect(try repository.removeTag(id: work.id, from: first.id))
        #expect(try repository.fetchTags(for: first.id) == [unicode])
        #expect(try repository.fetchByID(first.id) == first)
    }

    @Test func fetchesOnlyActiveThoughtsForTheSelectedTagNewestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let older = Thought(body: "older work", createdAt: Date(timeIntervalSince1970: 100))
        let other = Thought(body: "personal", createdAt: Date(timeIntervalSince1970: 200))
        let newest = Thought(body: "newest work", createdAt: Date(timeIntervalSince1970: 300))
        let deleted = Thought(body: "deleted work", createdAt: Date(timeIntervalSince1970: 400))
        for thought in [older, other, newest, deleted] { try repository.create(thought) }

        guard case .added(let work) = try repository.addTag(named: "work", to: older.id) else { return }
        guard case .added(let personal) = try repository.addTag(named: "personal", to: other.id) else { return }
        _ = try repository.addTag(named: work.name, to: newest.id)
        _ = try repository.addTag(named: work.name, to: deleted.id)
        #expect(try repository.softDelete(id: deleted.id, at: Date(timeIntervalSince1970: 500)))

        #expect(try repository.fetchThoughts(taggedWith: work.id).map(\.id) == [newest.id, older.id])
        #expect(try repository.fetchThoughts(taggedWith: personal.id).map(\.id) == [other.id])
        #expect(try repository.fetchTags(for: deleted.id).isEmpty)
    }

    @Test func memoryRepositoryMatchesTagContract() throws {
        let thought = Thought(body: "memory")
        let repository = MemoryThoughtRepository(records: [thought])
        guard case .added(let tag) = try repository.addTag(named: "  Swift  ", to: thought.id) else { return }
        #expect(try repository.addTag(named: "swift", to: thought.id) == .alreadyAttached(tag))
        #expect(try repository.fetchThoughts(taggedWith: tag.id) == [thought])
        #expect(try repository.removeTag(id: tag.id, from: thought.id))
        #expect(try repository.fetchAllTags().isEmpty)
    }

    @Test func migratesV3AndPreservesExistingThoughtBeforeAddingTags() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Thought(body: "v3から保持する原文", createdAt: Date(timeIntervalSince1970: 100))
        try fixture.writeV3Database(thought: original)

        let repository = try fixture.repository()
        #expect(SQLiteThoughtRepository.schemaVersion == 22)
        #expect(try repository.fetchByID(original.id) == original)
        guard case .added(let tag) = try repository.addTag(named: "移行後", to: original.id) else { return }
        #expect(try repository.fetchTags(for: original.id) == [tag])
        #expect(try repository.fetchByID(original.id) == original)
    }
}

@Suite("Thought history", .serialized)
struct ThoughtHistoryTests {
    @Test func conversationCombinesRepliesAndContinuationsSelectsLatestLeafAndKeepsBranches() throws {
        let repository = MemoryThoughtRepository()
        let root = Thought(body: "Root", createdAt: Date(timeIntervalSince1970: 1))
        try repository.create(root)
        let continuation = try #require(try repository.createContinuation(body: "自分の続き", parentThoughtID: root.id, now: Date(timeIntervalSince1970: 2)))
        let branch = try #require(try repository.createHumanReply(body: "会話の分岐", targetThoughtID: root.id, mentionedPersonaID: nil, now: Date(timeIntervalSince1970: 3), thoughtID: UUID(), relationID: UUID()))
        let leaf = try #require(try repository.createHumanReply(body: "最新返信", targetThoughtID: branch.id, mentionedPersonaID: nil, now: Date(timeIntervalSince1970: 4), thoughtID: UUID(), relationID: UUID()))

        let thread = try LoadConversationThread(thoughts: repository, relations: repository)(containing: continuation.id)
        #expect(thread.root == root)
        #expect(Set(thread.nodes.map(\.id)) == Set([root.id, continuation.id, branch.id, leaf.id]))
        #expect(thread.edges.map(\.type).contains(.continues))
        #expect(thread.edges.map(\.type).contains(.repliesTo))
        #expect(thread.currentPath.map(\.id) == [root.id, continuation.id])
        #expect(Set(thread.leaves.map(\.id)) == Set([continuation.id, leaf.id]))
        #expect(thread.lastThought == leaf)
        #expect(thread.nodes.first { $0.id == root.id }?.hasBranches == true)
    }

    @Test func conversationTreeRebuildsFromSQLiteAfterRepositoryReopen() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let root = Thought(body: "永続Root", createdAt: Date(timeIntervalSince1970: 1))
        let replyID: UUID
        do {
            let repository = try fixture.repository()
            try repository.create(root)
            let reply = try #require(try repository.createHumanReply(body: "永続Reply", targetThoughtID: root.id, mentionedPersonaID: nil, now: Date(timeIntervalSince1970: 2), thoughtID: UUID(), relationID: UUID()))
            replyID = reply.id
        }
        let reopened = try fixture.repository()
        let thread = try LoadConversationThread(thoughts: reopened, relations: reopened)(containing: replyID)
        #expect(thread.root.id == root.id)
        #expect(thread.currentPath.map(\.id) == [root.id, replyID])
        #expect(thread.edges.map(\.type) == [.repliesTo])
        #expect(thread.lastThought.id == replyID)
    }

    @Test func createsAndFetchesContinuationInBothDirections() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let parent = Thought(body: "A", createdAt: Date(timeIntervalSince1970: 100))
        let child = Thought(body: "B", createdAt: Date(timeIntervalSince1970: 200))
        try repository.create(parent)
        try repository.create(child)
        let relation = ThoughtRelation(sourceThoughtID: child.id, targetThoughtID: parent.id, createdAt: child.createdAt)
        try repository.create(relation)

        #expect(try repository.fetchContinuationSource(for: child.id) == relation)
        #expect(try repository.fetchContinuations(of: parent.id) == [relation])
        #expect(try repository.fetchBySourceThoughtID(child.id) == [relation])
        #expect(try repository.fetchByTargetThoughtID(parent.id) == [relation])
    }

    @Test func followsAThreeThoughtChainOneStepAtATime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let a = Thought(body: "A", createdAt: Date(timeIntervalSince1970: 100))
        try repository.create(a)
        let b = try #require(try repository.createContinuation(body: "B", parentThoughtID: a.id, now: Date(timeIntervalSince1970: 200)))
        let c = try #require(try repository.createContinuation(body: "C", parentThoughtID: b.id, now: Date(timeIntervalSince1970: 300)))

        let fromA = try #require(repository.fetchContinuations(of: a.id).first)
        let fromB = try #require(repository.fetchContinuations(of: fromA.sourceThoughtID).first)
        #expect(fromA.sourceThoughtID == b.id)
        #expect(fromB.sourceThoughtID == c.id)
        #expect(try repository.fetchTimeline().map(\.body) == ["C", "B", "A"])
        #expect(try ThoughtHistory(
            thoughtRepository: repository,
            relationRepository: repository
        ).entries(containing: b.id).map(\.thought.body) == ["A", "B", "C"])
    }

    @Test func historyIncludesMultipleContinuationsInStableOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let a = Thought(body: "A", createdAt: Date(timeIntervalSince1970: 100))
        try repository.create(a)
        _ = try repository.createContinuation(body: "B", parentThoughtID: a.id, now: Date(timeIntervalSince1970: 200))
        _ = try repository.createContinuation(body: "C", parentThoughtID: a.id, now: Date(timeIntervalSince1970: 300))

        let entries = try ThoughtHistory(
            thoughtRepository: repository,
            relationRepository: repository
        ).entries(containing: a.id)
        #expect(entries.map(\.thought.body) == ["A", "B", "C"])
        #expect(entries.map(\.depth) == [0, 1, 1])
    }

    @Test func relationsPersistAndSurviveParentSoftDeleteWithoutChangingOriginalText() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let created = Date(timeIntervalSince1970: 100)
        let updated = Date(timeIntervalSince1970: 150)
        let parent = Thought(body: "original", createdAt: created, updatedAt: updated)
        let repository = try fixture.repository()
        try repository.create(parent)
        let child = try #require(try repository.createContinuation(body: "next", parentThoughtID: parent.id))
        let unchangedParent = try repository.fetchByID(parent.id)
        #expect(unchangedParent == parent)
        #expect(try repository.softDelete(id: parent.id, at: Date(timeIntervalSince1970: 500)))

        let reopened = try fixture.repository()
        #expect(try reopened.fetchContinuationSource(for: child.id)?.targetThoughtID == parent.id)
        #expect(try reopened.fetchByID(parent.id)?.body == "original")
        #expect(try reopened.fetchByID(parent.id)?.createdAt == created)
        #expect(try reopened.fetchByID(parent.id)?.updatedAt == Date(timeIntervalSince1970: 500))
        #expect(try ThoughtHistory(
            thoughtRepository: reopened,
            relationRepository: reopened
        ).entries(containing: child.id).map { $0.thought.deletedAt != nil } == [true, false])
    }

    @Test func rejectsSelfMissingDuplicateAndCycleRelations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let a = Thought(body: "A")
        let b = Thought(body: "B")
        try repository.create(a)
        try repository.create(b)
        #expect(throws: SQLiteThoughtRepositoryError.selfRelation) {
            try repository.create(ThoughtRelation(sourceThoughtID: a.id, targetThoughtID: a.id))
        }
        #expect(throws: SQLiteThoughtRepositoryError.self) {
            try repository.create(ThoughtRelation(sourceThoughtID: UUID(), targetThoughtID: a.id))
        }
        let relation = ThoughtRelation(sourceThoughtID: b.id, targetThoughtID: a.id)
        try repository.create(relation)
        #expect(throws: SQLiteThoughtRepositoryError.self) { try repository.create(relation) }
        #expect(throws: SQLiteThoughtRepositoryError.cycle) {
            try repository.create(ThoughtRelation(sourceThoughtID: a.id, targetThoughtID: b.id))
        }
    }

    @Test func continuationRollsBackThoughtWhenRelationInsertFails() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let parent = Thought(body: "parent")
        let first = Thought(body: "first")
        let duplicateRelationID = UUID()
        try repository.create(parent)
        _ = try repository.createContinuation(first, parentThoughtID: parent.id, relationID: duplicateRelationID)
        let rejected = Thought(body: "must rollback")

        #expect(throws: SQLiteThoughtRepositoryError.self) {
            try repository.createContinuation(rejected, parentThoughtID: parent.id, relationID: duplicateRelationID)
        }
        #expect(try repository.fetchByID(rejected.id) == nil)
    }

    @Test func migratesV1WithoutChangingAnyThoughtFields() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Thought(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            body: "保持する原文 🚀",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            deletedAt: Date(timeIntervalSince1970: 300)
        )
        try fixture.writeV1Database(thought: original)

        let repository = try fixture.repository()
        #expect(SQLiteThoughtRepository.schemaVersion == 22)
        #expect(try repository.fetchAll() == [original])
        #expect(try repository.fetchBySourceThoughtID(original.id).isEmpty)
    }
}

@Suite("Thought history review", .serialized)
struct ThoughtHistoryReviewTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func fetchesTodayAndYesterdayUsingInclusiveExclusiveBoundaries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let today = ThoughtReviewPeriod.today(containing: now, calendar: calendar)
        let yesterday = ThoughtReviewPeriod.yesterday(containing: now, calendar: calendar)
        let atYesterdayStart = Thought(body: "yesterday start", createdAt: yesterday.start)
        let atTodayStart = Thought(body: "today start", createdAt: today.start)
        let beforeTodayEnd = Thought(body: "today end minus", createdAt: today.end.addingTimeInterval(-0.001))
        let atTodayEnd = Thought(body: "excluded end", createdAt: today.end)
        for thought in [atYesterdayStart, atTodayStart, beforeTodayEnd, atTodayEnd] {
            try repository.create(thought)
        }

        #expect(try repository.fetchThoughts(from: today.start, to: today.end).map(\.body) == ["today start", "today end minus"])
        #expect(try repository.fetchThoughts(from: yesterday.start, to: yesterday.end).map(\.body) == ["yesterday start"])
    }

    @Test func fetchesPastSevenDaysWithoutLoadingOlderThoughts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let period = ThoughtReviewPeriod.pastSevenDays(containing: now, calendar: calendar)
        try repository.create(Thought(body: "included start", createdAt: period.start))
        try repository.create(Thought(body: "too old", createdAt: period.start.addingTimeInterval(-1)))
        try repository.create(Thought(body: "included latest", createdAt: period.end.addingTimeInterval(-1)))

        #expect(try repository.fetchThoughts(from: period.start, to: period.end).map(\.body) == ["included start", "included latest"])
    }

    @Test func reviewIsStableAscendingExcludesDeletedAndLeavesTimelineDescending() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let date = Date(timeIntervalSince1970: 500)
        let low = Thought(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, body: "low", createdAt: date)
        let high = Thought(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, body: "high", createdAt: date)
        let deleted = Thought(body: "deleted", createdAt: date.addingTimeInterval(1))
        try repository.create(high)
        try repository.create(low)
        try repository.create(deleted)
        #expect(try repository.softDelete(id: deleted.id, at: date.addingTimeInterval(2)))

        #expect(try repository.fetchThoughts(from: date, to: date.addingTimeInterval(10)).map(\.body) == ["low", "high"])
        #expect(try repository.fetchTimeline().map(\.body) == ["high", "low"])
    }

    @Test func continuationCountsAreFetchedForReviewThoughtsInOneCall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let parent = Thought(body: "parent")
        try repository.create(parent)
        _ = try repository.createContinuation(body: "one", parentThoughtID: parent.id)
        _ = try repository.createContinuation(body: "two", parentThoughtID: parent.id)

        #expect(try repository.fetchContinuationCounts(for: [parent.id]) == [parent.id: 2])
        #expect(try repository.fetchContinuationCounts(for: []).isEmpty)
    }

    @Test func calculatesAllReviewPeriodsAcrossMonthAndYearBoundaries() throws {
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        let now = mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 15, minute: 30))!

        #expect(ThoughtReviewPeriod.today(containing: now, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 9)))
        #expect(ThoughtReviewPeriod.yesterday(containing: now, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 8)))
        #expect(ThoughtReviewPeriod.pastSevenDays(containing: now, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 3)))
        #expect(ThoughtReviewPeriod.currentWeek(containing: now, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 7)))
        #expect(ThoughtReviewPeriod.pastThirtyDays(containing: now, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2026, month: 8, day: 11)))
        #expect(ThoughtReviewPeriod.currentMonth(containing: now, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        #expect(ThoughtReviewPeriod.day(containing: now, calendar: mondayCalendar).end == mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 10)))
        let tomorrow = mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: 10))
        #expect(ThoughtReviewPeriod.currentWeek(containing: now, calendar: mondayCalendar).end == tomorrow)
        #expect(ThoughtReviewPeriod.pastThirtyDays(containing: now, calendar: mondayCalendar).end == tomorrow)
        #expect(ThoughtReviewPeriod.currentMonth(containing: now, calendar: mondayCalendar).end == tomorrow)

        let january = mondayCalendar.date(from: DateComponents(year: 2027, month: 1, day: 5, hour: 12))!
        #expect(ThoughtReviewPeriod.pastSevenDays(containing: january, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2026, month: 12, day: 30)))
        #expect(ThoughtReviewPeriod.pastThirtyDays(containing: january, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2026, month: 12, day: 7)))
        #expect(ThoughtReviewPeriod.currentMonth(containing: january, calendar: mondayCalendar).start == mondayCalendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
    }

    @Test func reviewPeriodsRespectCalendarTimezoneBoundaries() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 15, minute: 30))!
        let today = ThoughtReviewPeriod.today(containing: instant, calendar: tokyo)
        #expect(tokyo.component(.day, from: today.start) == 10)
        #expect(today.start == tokyo.startOfDay(for: instant))
        #expect(today.end == tokyo.date(byAdding: .day, value: 1, to: tokyo.startOfDay(for: instant)))
        #expect(ThoughtReviewPeriod.currentMonth(containing: instant, calendar: tokyo).start == tokyo.dateInterval(of: .month, for: instant)?.start)
    }

    @Test func filtersReviewInSQLiteByDateAndOneTag() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let start = Date(timeIntervalSince1970: 1_000)
        let older = Thought(body: "work older", createdAt: start)
        let otherTag = Thought(body: "personal", createdAt: start.addingTimeInterval(10))
        let newer = Thought(body: "work newer", createdAt: start.addingTimeInterval(20))
        let deleted = Thought(body: "work deleted", createdAt: start.addingTimeInterval(30))
        let outside = Thought(body: "work outside", createdAt: start.addingTimeInterval(100))
        for thought in [older, otherTag, newer, deleted, outside] { try repository.create(thought) }
        guard case .added(let work) = try repository.addTag(named: "work", to: older.id) else { return }
        _ = try repository.addTag(named: work.name, to: newer.id)
        _ = try repository.addTag(named: work.name, to: deleted.id)
        _ = try repository.addTag(named: work.name, to: outside.id)
        guard case .added(let personal) = try repository.addTag(named: "personal", to: otherTag.id) else { return }
        #expect(try repository.softDelete(id: deleted.id, at: start.addingTimeInterval(40)))

        let end = start.addingTimeInterval(50)
        #expect(try repository.fetchThoughts(from: start, to: end).map(\.id) == [older.id, otherTag.id, newer.id])
        #expect(try repository.fetchThoughts(from: start, to: end, taggedWith: work.id).map(\.id) == [older.id, newer.id])
        #expect(try repository.fetchThoughts(from: start, to: end, taggedWith: personal.id).map(\.id) == [otherTag.id])
    }

    @Test func tagFilteredDisplayDoesNotChangeAISummaryPeriodScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let interval = DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let tagged = Thought(body: "tagged", createdAt: Date(timeIntervalSince1970: 120))
        let untagged = Thought(body: "untagged", createdAt: Date(timeIntervalSince1970: 140))
        try repository.create(tagged)
        try repository.create(untagged)
        guard case .added(let tag) = try repository.addTag(named: "review", to: tagged.id) else { return }

        #expect(try repository.fetchThoughts(from: interval.start, to: interval.end, taggedWith: tag.id) == [tagged])
        let preview = try PrepareReviewSummary(repository: repository)(interval: interval)
        #expect(preview.thoughts.map(\.id) == [tagged.id, untagged.id])
    }

    @Test func promptContainsOnlyOrderedBodiesAndNoInternalIdentifiers() throws {
        let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let thoughts = [
            Thought(id: firstID, body: "最初の本文", createdAt: Date(timeIntervalSince1970: 100)),
            Thought(body: "次の本文", createdAt: Date(timeIntervalSince1970: 200))
        ]

        let prompt = try ReviewSummaryPrompt.make(thoughts: thoughts)

        #expect(prompt.contains("1. 最初の本文\n2. 次の本文"))
        #expect(!prompt.contains(firstID.uuidString))
        #expect(!prompt.contains("createdAt"))
        #expect(!prompt.contains("SQLite"))
        #expect(throws: ReviewSummaryError.noThoughts) {
            try ReviewSummaryPrompt.make(thoughts: [])
        }
    }

    @Test func previewUsesExactReviewPeriodAndReportsPayloadCounts() throws {
        let repository = MemoryThoughtRepository()
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let today = ThoughtReviewPeriod.today(containing: now, calendar: calendar)
        let yesterday = ThoughtReviewPeriod.yesterday(containing: now, calendar: calendar)
        let sevenDays = ThoughtReviewPeriod.pastSevenDays(containing: now, calendar: calendar)
        let values = [
            Thought(body: "七日前", createdAt: sevenDays.start.addingTimeInterval(1)),
            Thought(body: "昨日", createdAt: yesterday.start.addingTimeInterval(1)),
            Thought(body: "今日", createdAt: today.start.addingTimeInterval(1)),
            Thought(body: "対象外", createdAt: sevenDays.start.addingTimeInterval(-1))
        ]
        for thought in values { try repository.create(thought) }
        let prepare = PrepareReviewSummary(repository: repository)

        let todayPreview = try prepare(interval: today)
        let yesterdayPreview = try prepare(interval: yesterday)
        let sevenDayPreview = try prepare(interval: sevenDays)
        let selectedDatePreview = try prepare(interval: ThoughtReviewPeriod.day(
            containing: yesterday.start.addingTimeInterval(100), calendar: calendar
        ))

        #expect(todayPreview.thoughts.map(\.body) == ["今日"])
        #expect(yesterdayPreview.thoughts.map(\.body) == ["昨日"])
        #expect(sevenDayPreview.thoughts.map(\.body) == ["七日前", "昨日", "今日"])
        #expect(selectedDatePreview.thoughts.map(\.body) == ["昨日"])
        #expect(sevenDayPreview.thoughtCount == 3)
        #expect(sevenDayPreview.thoughtCharacterCount == "七日前昨日今日".count)
        #expect(sevenDayPreview.payloadCharacterCount == sevenDayPreview.request.prompt.count)
        #expect(!sevenDayPreview.request.prompt.contains("対象外"))
    }

    @Test func preparingOrCancellingDoesNotCallAIAndSubmissionUsesFrozenRequestOnce() async throws {
        let repository = MemoryThoughtRepository(records: [Thought(body: "確認した本文")])
        let interval = DateInterval(start: .distantPast, end: .distantFuture)
        let preview = try PrepareReviewSummary(repository: repository)(interval: interval)
        let client = RecordingReviewSummaryClient()
        let beforeSubmission = await client.recordedRequests()
        #expect(beforeSubmission.isEmpty)

        _ = try await GenerateReviewSummary(client: client, repository: repository)(preview: preview)

        let submitted = await client.recordedRequests()
        #expect(submitted == [preview.request])
        #expect(try repository.fetchSummaries(from: interval.start, to: interval.end).count == 1)
    }

    @Test func previewRejectsAnEmptyPeriodBeforeSubmission() throws {
        let repository = MemoryThoughtRepository()
        let interval = DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        #expect(throws: ReviewSummaryError.noThoughts) {
            try PrepareReviewSummary(repository: repository)(interval: interval)
        }
    }

    @Test func stalePreviewIsRejectedBeforeTheAIClientCanBeCalled() async throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 300)
        )
        let repository = MemoryThoughtRepository(records: [
            Thought(body: "確認時の本文", createdAt: Date(timeIntervalSince1970: 150))
        ])
        let preview = try PrepareReviewSummary(repository: repository)(interval: interval)
        try repository.create(Thought(body: "確認後に追加", createdAt: Date(timeIntervalSince1970: 200)))
        let client = RecordingReviewSummaryClient()

        #expect(throws: ReviewSummaryError.stalePreview) {
            try ValidateReviewSummaryPreview(repository: repository)(preview)
        }

        let requests = await client.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test func generatedSummariesAreSavedSeparatelyAndCanBeRegenerated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 500)
        )
        let thoughts = [Thought(body: "原文は変えない", createdAt: Date(timeIntervalSince1970: 200))]
        try repository.create(thoughts[0])
        let preview = try PrepareReviewSummary(repository: repository)(interval: interval)
        let generator = GenerateReviewSummary(
            client: MockReviewSummaryClient(text: "主な話題: 1回目"),
            repository: repository
        )
        _ = try await generator(preview: preview, now: Date(timeIntervalSince1970: 300))
        let regenerated = GenerateReviewSummary(
            client: MockReviewSummaryClient(text: "主な話題: 2回目"),
            repository: repository
        )
        _ = try await regenerated(preview: preview, now: Date(timeIntervalSince1970: 400))

        let reopened = try fixture.repository()
        let summaries = try reopened.fetchSummaries(from: interval.start, to: interval.end)
        #expect(summaries.map(\.content) == ["主な話題: 2回目", "主な話題: 1回目"])
        #expect(summaries.allSatisfy { $0.thoughtCount == 1 && $0.promptVersion == ReviewSummaryPrompt.version })
        #expect(try reopened.fetchByID(thoughts[0].id)?.body == "原文は変えない")
    }

    @Test func firebaseClientPassesTheCanonicalPromptAndRecordsActualProviderAndModel() async throws {
        let transport = RecordingReviewSummaryTransport()
        let client = FirebaseReviewSummaryClient(transport: transport)
        let request = ReviewSummaryRequest(prompt: "PrepareReviewSummaryが確定したpayload")

        let response = try await client.generateSummary(request)

        #expect(await transport.recordedCalls() == [ReviewSummaryTransportCall(
            prompt: request.prompt,
            modelName: ReviewSummaryAIConfiguration.modelName,
            generationProfile: .reviewSummary
        )])
        #expect(response.text == "Firebaseの要約")
        #expect(response.provider == ReviewSummaryAIConfiguration.providerName)
        #expect(response.model == ReviewSummaryAIConfiguration.modelName)
    }

    @Test func providerRouterUsesTheProviderFrozenIntoTheRequest() async throws {
        let router = ProviderRoutingReviewSummaryClient(
            gemini: MockReviewSummaryClient(response: .init(text: "Gemini", provider: AIProvider.gemini.rawValue, model: AIProvider.gemini.defaultModel)),
            openAI: MockReviewSummaryClient(response: .init(text: "OpenAI", provider: AIProvider.openAI.rawValue, model: AIProvider.openAI.defaultModel))
        )

        let response = try await router.generateSummary(.init(prompt: "OpenAIで生成", provider: .openAI))

        #expect(response.text == "OpenAI")
        #expect(response.provider == AIProvider.openAI.rawValue)
        #expect(response.model == ReviewSummaryAIConfiguration.openAIModelName)
    }

    @Test func firebaseClientRejectsEmptyResponsesAndPreservesTypedServiceErrors() async {
        let request = ReviewSummaryRequest(prompt: "payload")
        let emptyClient = FirebaseReviewSummaryClient(
            transport: RecordingReviewSummaryTransport(response: nil)
        )
        await #expect(throws: ReviewSummaryError.emptyResponse) {
            try await emptyClient.generateSummary(request)
        }

        for error in [
            ReviewSummaryServiceError.firebaseNotConfigured,
            .network, .rateLimited, .api, .appCheck
        ] {
            let client = FirebaseReviewSummaryClient(
                transport: RecordingReviewSummaryTransport(error: error)
            )
            await #expect(throws: error) {
                try await client.generateSummary(request)
            }
        }

        let unavailable = UnavailableReviewSummaryClient(error: .firebaseNotConfigured)
        await #expect(throws: ReviewSummaryServiceError.firebaseNotConfigured) {
            try await unavailable.generateSummary(request)
        }
    }

    @Test func firebaseErrorsAreClassifiedWithoutCallingTheSDK() {
        #expect(ReviewSummaryServiceError.classify(
            domain: NSURLErrorDomain, code: -1009, description: "offline"
        ) == .network)
        #expect(ReviewSummaryServiceError.classify(
            domain: "FirebaseAILogic", code: 429, description: "RESOURCE_EXHAUSTED"
        ) == .rateLimited)
        #expect(ReviewSummaryServiceError.classify(
            domain: "FIRAppCheckErrorDomain", code: 1, description: "attestation failed"
        ) == .appCheck)
        #expect(ReviewSummaryServiceError.classify(
            domain: "FirebaseCore", code: 1, description: "GoogleService-Info.plist missing"
        ) == .firebaseNotConfigured)
        #expect(ReviewSummaryServiceError.classify(
            domain: "FirebaseAILogic", code: 500, description: "server error"
        ) == .api)
    }

    @Test func deletesExactlyOneSummaryWithoutAffectingThoughtsOrOtherPeriods() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let thought = Thought(body: "削除してはいけない原文", createdAt: Date(timeIntervalSince1970: 150))
        try repository.create(thought)
        let firstPeriod = DateInterval(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)
        )
        let otherPeriod = DateInterval(
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 300)
        )
        let older = ReviewSummary(
            periodStart: firstPeriod.start, periodEnd: firstPeriod.end,
            content: "古い要約", createdAt: Date(timeIntervalSince1970: 160),
            provider: "mock", model: "mock", promptVersion: 1, thoughtCount: 1
        )
        let latest = ReviewSummary(
            periodStart: firstPeriod.start, periodEnd: firstPeriod.end,
            content: "最新要約", createdAt: Date(timeIntervalSince1970: 170),
            provider: "mock", model: "mock", promptVersion: 1, thoughtCount: 1
        )
        let anotherPeriodSummary = ReviewSummary(
            periodStart: otherPeriod.start, periodEnd: otherPeriod.end,
            content: "別期間", createdAt: Date(timeIntervalSince1970: 250),
            provider: "mock", model: "mock", promptVersion: 1, thoughtCount: 1
        )
        for summary in [older, latest, anotherPeriodSummary] { try repository.save(summary) }

        #expect(try repository.fetchSummary(id: latest.id) == latest)
        #expect(try repository.deleteSummary(id: latest.id))
        #expect(try repository.fetchSummary(id: latest.id) == nil)
        #expect(try repository.fetchSummaries(from: firstPeriod.start, to: firstPeriod.end) == [older])
        #expect(try repository.fetchByID(thought.id)?.body == "削除してはいけない原文")
        #expect(try repository.fetchSummaries(from: otherPeriod.start, to: otherPeriod.end) == [anotherPeriodSummary])
        #expect(try repository.fetchSummary(id: anotherPeriodSummary.id) == anotherPeriodSummary)

        #expect(try repository.deleteSummary(id: older.id))
        #expect(try repository.fetchSummaries(from: firstPeriod.start, to: firstPeriod.end).isEmpty)
        #expect(try repository.deleteSummary(id: UUID()) == false)
        #expect(try repository.fetchByID(thought.id) == thought)
        #expect(try repository.fetchSummaries(from: otherPeriod.start, to: otherPeriod.end) == [anotherPeriodSummary])
    }
}

@Suite("Thought export")
struct ThoughtExporterTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func markdownForZeroThoughts() throws {
        let exporter = makeExporter([])
        #expect(try String(decoding: exporter.data(for: .markdown), as: UTF8.self) == "# Thought Export\n\n")
    }

    @Test func markdownForOneJapaneseAndEmojiThought() throws {
        let thought = Thought(body: "日本語の原文 🚀", createdAt: date("2026-09-07T15:32:00Z"))
        let markdown = try String(decoding: makeExporter([thought]).data(for: .markdown), as: UTF8.self)
        #expect(markdown == "# Thought Export\n\n## 2026-09-07\n\n### 15:32\n\n日本語の原文 🚀\n")
    }

    @Test func markdownGroupsDaysAndUsesStableNewestFirstOrder() throws {
        let sameDate = date("2026-09-07T14:48:00Z")
        let low = Thought(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, body: "low", createdAt: sameDate)
        let high = Thought(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, body: "high", createdAt: sameDate)
        let older = Thought(body: "昨日", createdAt: date("2026-09-06T23:01:00Z"))
        let markdown = try String(decoding: makeExporter([older, low, high]).data(for: .markdown), as: UTF8.self)
        #expect(markdown.range(of: "high")!.lowerBound < markdown.range(of: "low")!.lowerBound)
        #expect(markdown.range(of: "low")!.lowerBound < markdown.range(of: "## 2026-09-06")!.lowerBound)
        #expect(markdown.contains("### 23:01\n\n昨日"))
    }

    @Test func exportsDecodableJSONWithCanonicalFieldsAndUnicode() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let created = date("2026-09-07T15:32:00Z")
        let updated = date("2026-09-07T16:00:00Z")
        let thought = Thought(id: id, body: "日本語 🚀", createdAt: created, updatedAt: updated)
        let data = try makeExporter([thought]).data(for: .json)
        let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([Thought].self, from: data)

        #expect(decoded == [thought])
        #expect(decoded.first?.id == id)
        #expect(decoded.first?.body == "日本語 🚀")
        #expect(decoded.first?.createdAt == created)
        #expect(text.contains("\"deletedAt\" : null"))
    }

    @Test func exportExcludesSoftDeletedThoughts() throws {
        let active = Thought(body: "active")
        let deleted = Thought(body: "deleted", deletedAt: .now)
        let decoded = try JSONDecoder.withISO8601.decode([Thought].self, from: makeExporter([active, deleted]).data(for: .json))
        #expect(decoded.map(\.id) == [active.id])
    }

    private func makeExporter(_ thoughts: [Thought]) -> ThoughtExporter {
        ThoughtExporter(repository: MemoryThoughtRepository(records: thoughts), timeZone: utc)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}

@Suite("Review summary export")
struct ReviewSummaryExporterTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func markdownAndJSONRepresentOnlyTheSelectedSummary() throws {
        let repository = MemoryThoughtRepository(records: [
            Thought(body: "PRIVATE_THOUGHT_BODY", createdAt: Date(timeIntervalSince1970: 100))
        ])
        let selected = ReviewSummary(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 86_400),
            content: "選択したAI要約",
            createdAt: Date(timeIntervalSince1970: 3_600),
            provider: "firebase-ai-logic",
            model: "gemini-test",
            promptVersion: 1,
            thoughtCount: 4
        )
        let other = ReviewSummary(
            periodStart: selected.periodStart,
            periodEnd: selected.periodEnd,
            content: "別の履歴",
            provider: "mock",
            model: "other",
            promptVersion: 1,
            thoughtCount: 1
        )
        try repository.save(selected)
        try repository.save(other)
        let before = try repository.fetchSummaries(from: selected.periodStart, to: selected.periodEnd)
        let exporter = ReviewSummaryExporter(repository: repository, timeZone: utc)
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-summary-export-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let markdown = String(decoding: try exporter.data(for: selected.id, format: .markdown), as: UTF8.self)
        let json = try exporter.data(for: selected.id, format: .json)
        let writtenURL = try exporter.write(summaryID: selected.id, format: .json, to: outputDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ReviewSummaryExportDocument.self, from: json)

        #expect(markdown.contains("# AI Review Summary"))
        #expect(markdown.contains("- Period: 1970-01-01"))
        #expect(markdown.contains("- Generated At: 1970-01-01T01:00:00Z"))
        #expect(markdown.contains("- Thought Count: 4"))
        #expect(markdown.contains("- Provider: firebase-ai-logic"))
        #expect(markdown.contains("- Model: gemini-test"))
        #expect(markdown.contains("選択したAI要約"))
        #expect(!markdown.contains("別の履歴"))
        #expect(!markdown.contains("PRIVATE_THOUGHT_BODY"))
        #expect(!markdown.contains("メモ（古い順）"))
        #expect(!markdown.contains("API_KEY"))

        #expect(document.schemaVersion == ReviewSummaryExportDocument.currentSchemaVersion)
        #expect(document.summaryId == selected.id)
        #expect(document.period == .init(start: selected.periodStart, endExclusive: selected.periodEnd))
        #expect(document.summary == selected.content)
        #expect(document.generatedAt == selected.createdAt)
        #expect(document.thoughtCount == selected.thoughtCount)
        #expect(document.provider == selected.provider)
        #expect(document.model == selected.model)
        #expect(!String(decoding: json, as: UTF8.self).contains("PRIVATE_THOUGHT_BODY"))
        #expect(!String(decoding: json, as: UTF8.self).contains("prompt"))
        #expect(try repository.fetchSummaries(from: selected.periodStart, to: selected.periodEnd) == before)
        #expect(try repository.fetchTimeline().map(\.body) == ["PRIVATE_THOUGHT_BODY"])
        #expect(exporter.fileName(for: selected, format: .markdown) == "review-summary-1970-01-01-aaaaaaaa.md")
        #expect(writtenURL.lastPathComponent == "review-summary-1970-01-01-aaaaaaaa.json")
        #expect(try Data(contentsOf: writtenURL) == json)
    }

    @Test func deletedSummaryCannotBeExported() throws {
        let repository = MemoryThoughtRepository()
        let summary = ReviewSummary(
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 86_400),
            content: "削除対象",
            provider: "mock",
            model: "mock",
            promptVersion: 1,
            thoughtCount: 1
        )
        try repository.save(summary)
        #expect(try repository.deleteSummary(id: summary.id))
        let exporter = ReviewSummaryExporter(repository: repository, timeZone: utc)
        #expect(throws: ReviewSummaryExportError.summaryNotFound) {
            try exporter.data(for: summary.id, format: .json)
        }
    }
}

@Suite("External disaster recovery backup", .serialized)
struct ExternalBackupTests {
    @Test func createsManifestAndRotatesExactlyTwoGenerations() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let destination = fixture.directory.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let repository = try fixture.repository()
        let service = ExternalBackupService(repository: repository, appVersion: "1.2", buildVersion: "34")

        try repository.create(Thought(body: "one")); let first = try service.createBackup(in: destination)
        try repository.create(Thought(body: "two")); _ = try service.createBackup(in: destination)
        try repository.create(Thought(body: "three")); _ = try service.createBackup(in: destination)

        let root = destination.appendingPathComponent("AiText Backup")
        #expect(first.backupFormatVersion == 1)
        #expect(first.sqliteUserVersion == SQLiteThoughtRepository.schemaVersion)
        #expect(first.databaseFileSize > 0)
        #expect(first.files.first?.sha256?.count == 64)
        #expect(try repositoryBodies(at: root.appendingPathComponent("latest")) == ["three", "two", "one"])
        #expect(try repositoryBodies(at: root.appendingPathComponent("previous")) == ["two", "one"])
        let visibleGenerations = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }
        #expect(Set(visibleGenerations) == ["latest", "previous"])
        _ = try ExternalBackupService.validateBackup(at: root.appendingPathComponent("latest"), maximumSchemaVersion: SQLiteThoughtRepository.schemaVersion)
    }

    @Test func failedBackupDoesNotDamageExistingLatest() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let destination = fixture.directory.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let repository = try fixture.repository()
        let service = ExternalBackupService(repository: repository, appVersion: "1", buildVersion: "1")
        try repository.create(Thought(body: "safe")); _ = try service.createBackup(in: destination)
        let latest = destination.appendingPathComponent("AiText Backup/latest")
        let inaccessible = fixture.directory.appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: inaccessible)
        #expect(throws: Error.self) { try service.createBackup(in: inaccessible) }
        #expect(try repositoryBodies(at: latest) == ["safe"])
    }

    @Test func rejectsInvalidManifestAndCorruptSQLiteWithoutChangingCurrentDatabase() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let current = try fixture.repository(); try current.create(Thought(body: "current"))
        let generation = fixture.directory.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        try Data("bad json".utf8).write(to: generation.appendingPathComponent("manifest.json"))
        #expect(throws: ExternalBackupError.invalidManifest) {
            try RestoreCoordinator.stageRestore(from: generation, applicationSupportDirectory: fixture.directory)
        }
        #expect(try current.fetchTimeline().map(\.body) == ["current"])

        let files = fixture.directory.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let service = ExternalBackupService(repository: current, appVersion: "1", buildVersion: "1")
        _ = try service.createBackup(in: files)
        let latest = files.appendingPathComponent("AiText Backup/latest")
        try Data("not sqlite".utf8).write(to: latest.appendingPathComponent(ExternalBackupService.databaseFileName))
        #expect(throws: ExternalBackupError.self) {
            try RestoreCoordinator.stageRestore(from: latest, applicationSupportDirectory: fixture.directory.appendingPathComponent("Support"))
        }
        #expect(try current.fetchTimeline().map(\.body) == ["current"])
    }

    @Test func restorePreservesThoughtRelationSoftDeleteAndSchema() throws {
        let sourceFixture = try Fixture(); defer { sourceFixture.remove() }
        let source = try sourceFixture.repository()
        let parent = Thought(body: "parent", createdAt: Date(timeIntervalSince1970: 100))
        try source.create(parent)
        let child = try #require(try source.createContinuation(body: "child", parentThoughtID: parent.id, now: Date(timeIntervalSince1970: 200)))
        _ = try source.softDelete(id: parent.id, at: Date(timeIntervalSince1970: 300))
        let files = sourceFixture.directory.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        _ = try ExternalBackupService(repository: source, appVersion: "1", buildVersion: "1").createBackup(in: files)

        let restored = try Fixture(); defer { restored.remove() }
        do {
            let existing = try restored.repository()
            try existing.create(Thought(body: "replace me"))
        }
        let generation = files.appendingPathComponent("AiText Backup/latest")
        _ = try RestoreCoordinator.stageRestore(from: generation, applicationSupportDirectory: restored.directory)
        #expect(try RestoreCoordinator.applyPendingRestoreIfNeeded(databaseURL: restored.databaseURL, applicationSupportDirectory: restored.directory))
        let repository = try restored.repository()
        #expect(try repository.fetchAll().map(\.body) == ["child", "parent"])
        #expect(try repository.fetchByID(parent.id)?.deletedAt == Date(timeIntervalSince1970: 300))
        #expect(try repository.fetchContinuationSource(for: child.id)?.targetThoughtID == parent.id)
        #expect(try ThoughtHistory(thoughtRepository: repository, relationRepository: repository).entries(containing: child.id).map(\.thought.body) == ["parent", "child"])
        #expect(try sqliteUserVersion(at: restored.databaseURL) == SQLiteThoughtRepository.schemaVersion)
    }

    @Test func localAnalyticsSummarizesThirtyDaysAndIsReadOnly() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let calendar = analyticsCalendar()
        let now = analyticsDate(2026, 9, 9, 12, 0, calendar: calendar)
        let values = [
            Thought(body: "today", createdAt: analyticsDate(2026, 9, 9, 8, 0, calendar: calendar)),
            Thought(body: "today second", createdAt: analyticsDate(2026, 9, 9, 20, 0, calendar: calendar)),
            Thought(body: "six days", createdAt: analyticsDate(2026, 9, 3, 9, 0, calendar: calendar)),
            Thought(body: "old edge", createdAt: analyticsDate(2026, 8, 11, 10, 0, calendar: calendar)),
            Thought(body: "outside", createdAt: analyticsDate(2026, 8, 10, 23, 59, calendar: calendar)),
            Thought(body: "deleted", createdAt: analyticsDate(2026, 9, 9, 10, 0, calendar: calendar))
        ]
        for thought in values { try repository.create(thought) }
        _ = try repository.softDelete(id: values[5].id, at: now)
        let before = try repository.fetchAll()

        let analytics = try LoadThoughtAnalytics(repository: repository, calendar: calendar)(containing: now)

        #expect(analytics.summary.todayCount == 2)
        #expect(analytics.summary.pastSevenDaysCount == 3)
        #expect(analytics.summary.pastThirtyDaysCount == 4)
        #expect(analytics.summary.activeDayCount == 3)
        #expect(analytics.summary.averagePerActiveDay == 4.0 / 3.0)
        #expect(analytics.dailyCounts.count == 30)
        #expect(analytics.dailyCounts.first?.count == 1)
        #expect(analytics.dailyCounts.last?.count == 2)
        #expect(try repository.fetchAll() == before)
        #expect(SQLiteThoughtRepository.schemaVersion == 22)
    }

    @Test func emptyLocalAnalyticsReturnsZeroFilledDistributions() throws {
        let repository = MemoryThoughtRepository()
        let calendar = analyticsCalendar()
        let analytics = try LoadThoughtAnalytics(repository: repository, calendar: calendar)(
            containing: analyticsDate(2026, 9, 9, 12, 0, calendar: calendar)
        )
        #expect(analytics.summary == .init(todayCount: 0, pastSevenDaysCount: 0, pastThirtyDaysCount: 0, activeDayCount: 0))
        #expect(analytics.summary.averagePerActiveDay == 0)
        #expect(analytics.dailyCounts.count == 30)
        #expect(analytics.dailyCounts.allSatisfy { $0.count == 0 })
        #expect(analytics.weekdayCounts.count == 7)
        #expect(analytics.timeOfDayCounts.map(\.count) == [0, 0, 0, 0])
        #expect(analytics.topTags.isEmpty)
        #expect(analytics.thoughtsWithContinuationsCount == 0)
    }

    @Test func localAnalyticsRespectsTimezoneWeekdaysAndTimeBoundaries() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let calendar = analyticsCalendar()
        let now = analyticsDate(2026, 9, 9, 23, 59, calendar: calendar)
        let boundaryTimes = [(5, 59), (6, 0), (11, 59), (12, 0), (17, 59), (18, 0), (23, 59), (0, 0)]
        for (index, value) in boundaryTimes.enumerated() {
            try repository.create(Thought(
                body: "boundary \(index)",
                createdAt: analyticsDate(2026, 9, 9, value.0, value.1, calendar: calendar)
            ))
        }
        try repository.create(Thought(
            body: "previous local day",
            createdAt: analyticsDate(2026, 9, 8, 23, 59, calendar: calendar)
        ))

        let analytics = try LoadThoughtAnalytics(repository: repository, calendar: calendar)(containing: now)

        #expect(analytics.timeOfDayCounts.map(\.count) == [2, 2, 2, 3])
        let wednesday = calendar.component(.weekday, from: analyticsDate(2026, 9, 9, 12, 0, calendar: calendar))
        let tuesday = calendar.component(.weekday, from: analyticsDate(2026, 9, 8, 12, 0, calendar: calendar))
        #expect(analytics.weekdayCounts.first { $0.weekday == wednesday }?.count == 8)
        #expect(analytics.weekdayCounts.first { $0.weekday == tuesday }?.count == 1)
        #expect(analytics.dailyCounts.suffix(2).map(\.count) == [1, 8])
    }

    @Test func localAnalyticsRanksTagsAndExcludesDeletedAndOutsideThoughts() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let calendar = analyticsCalendar()
        let now = analyticsDate(2026, 9, 9, 12, 0, calendar: calendar)
        let first = Thought(body: "first", createdAt: analyticsDate(2026, 9, 9, 8, 0, calendar: calendar))
        let second = Thought(body: "second", createdAt: analyticsDate(2026, 9, 8, 8, 0, calendar: calendar))
        let deleted = Thought(body: "deleted", createdAt: analyticsDate(2026, 9, 7, 8, 0, calendar: calendar))
        let outside = Thought(body: "outside", createdAt: analyticsDate(2026, 8, 1, 8, 0, calendar: calendar))
        for thought in [first, second, deleted, outside] { try repository.create(thought) }
        guard case .added(let alpha) = try repository.addTag(named: "Alpha", to: first.id, at: now),
              case .added(let beta) = try repository.addTag(named: "ベータ", to: first.id, at: now) else {
            Issue.record("tags should be created")
            return
        }
        _ = try repository.addTag(named: "Alpha", to: second.id, at: now)
        _ = try repository.addTag(named: "ベータ", to: second.id, at: now)
        _ = try repository.addTag(named: "除外", to: deleted.id, at: now)
        _ = try repository.addTag(named: "期間外", to: outside.id, at: now)
        _ = try repository.softDelete(id: deleted.id, at: now)

        let analytics = try LoadThoughtAnalytics(repository: repository, calendar: calendar)(containing: now)

        #expect(analytics.topTags.map(\.tag.id) == [alpha.id, beta.id])
        #expect(analytics.topTags.map(\.count) == [2, 2])
    }

    @Test func localAnalyticsCountsOnlyActiveInPeriodContinuationParents() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let calendar = analyticsCalendar()
        let now = analyticsDate(2026, 9, 9, 12, 0, calendar: calendar)
        let parent = Thought(body: "parent", createdAt: analyticsDate(2026, 9, 7, 8, 0, calendar: calendar))
        let child = Thought(body: "child", createdAt: analyticsDate(2026, 9, 8, 8, 0, calendar: calendar))
        let deletedChild = Thought(body: "deleted child", createdAt: analyticsDate(2026, 9, 9, 8, 0, calendar: calendar))
        for thought in [parent, child, deletedChild] { try repository.create(thought) }
        try repository.create(ThoughtRelation(sourceThoughtID: child.id, targetThoughtID: parent.id, createdAt: child.createdAt))
        try repository.create(ThoughtRelation(sourceThoughtID: deletedChild.id, targetThoughtID: parent.id, createdAt: deletedChild.createdAt))
        _ = try repository.softDelete(id: deletedChild.id, at: now)

        let analytics = try LoadThoughtAnalytics(repository: repository, calendar: calendar)(containing: now)
        #expect(analytics.thoughtsWithContinuationsCount == 1)
    }

    private func analyticsCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func analyticsDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func repositoryBodies(at generation: URL) throws -> [String] {
        let database = generation.appendingPathComponent(ExternalBackupService.databaseFileName)
        return try SQLiteThoughtRepository(databaseURL: database).fetchAll().map(\.body)
    }

    private func sqliteUserVersion(at url: URL) throws -> Int32 {
        var database: OpaquePointer?; guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { throw ExternalBackupError.invalidSQLite("test open") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?; sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ExternalBackupError.invalidSQLite("test pragma") }
        return sqlite3_column_int(statement, 0)
    }
}

@Suite("Personas", .serialized)
struct PersonaTests {
    @Test func handlesNormalizeValidateRemainUniqueAndKeepActorIdentity() throws {
        #expect(ActorHandle.normalize("Masaya_01") == "masaya_01")
        #expect(ActorHandle.normalize("ab") == nil)
        #expect(ActorHandle.normalize("日本語") == nil)
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        var human = try repository.fetchDefaultHumanPersona()
        let humanID = human.id
        human.handle = ActorHandle.normalize("Masaya")!
        try repository.updatePersona(human)
        let ai = Persona(displayName: "Developer AI", handle: "dev_ai", kind: .ai)
        try repository.createAIPersona(ai, configuration: .init(personaID: ai.id, role: "開発", instructions: "短く"))
        #expect(try repository.fetchDefaultHumanPersona().handle == "masaya")
        #expect(try repository.fetchDefaultHumanPersona().id == humanID)
        #expect(try repository.fetchPersonas(includeInactive: false).contains { $0.id == ai.id && $0.handle == "dev_ai" })
        #expect(throws: SQLiteThoughtRepositoryError.self) {
            try repository.createPersona(Persona(displayName: "Duplicate", handle: "MASAYA", kind: .human))
        }
    }

    @Test func aiPersonaCreateReportsPersonaUniqueConstraintAndRollsBack() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let first = Persona(displayName: "First", handle: "same_handle", kind: .ai)
        try repository.createAIPersona(first, configuration: .init(personaID: first.id, role: "整理", instructions: "短く"))
        let duplicate = Persona(displayName: "Duplicate", handle: "SAME_HANDLE", kind: .ai)

        do {
            try repository.createAIPersona(duplicate, configuration: .init(personaID: duplicate.id, role: "整理", instructions: "短く"))
            Issue.record("UNIQUE制約違反が成功扱いになりました")
        } catch let error as AIPersonaPersistenceError {
            guard case .personaInsert(let message) = error else {
                Issue.record("Persona INSERT以外の段階として報告されました: \(error)")
                return
            }
            #expect(message.contains("UNIQUE constraint failed: personas.handle"))
        }
        #expect(!(try repository.fetchPersonas(includeInactive: true)).contains { $0.id == duplicate.id })
        #expect(try repository.fetchAIConfigurations()[duplicate.id] == nil)
    }

    @Test func aiPersonaCreateReportsConfigurationForeignKeyAndRollsBackPersona() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let persona = Persona(displayName: "Mismatch", handle: "mismatch_ai", kind: .ai)

        do {
            try repository.createAIPersona(persona, configuration: .init(personaID: UUID(), role: "整理", instructions: "短く"))
            Issue.record("Foreign Key制約違反が成功扱いになりました")
        } catch let error as AIPersonaPersistenceError {
            guard case .configurationUpsert(let message) = error else {
                Issue.record("AI Configuration UPSERT以外の段階として報告されました: \(error)")
                return
            }
            #expect(message.contains("FOREIGN KEY constraint failed"))
        }
        #expect(!(try repository.fetchPersonas(includeInactive: true)).contains { $0.id == persona.id })
    }

    @Test func migratesLegacyUniqueAccountWithoutLosingPersonasConfigurationsMentionsOrAuthors() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let existingAI = Persona(displayName: "Navi", handle: "navi", kind: .ai)
        let mentionedThought = Thought(body: "@navi 確認")
        do {
            let repository = try fixture.repository()
            try repository.createAIPersona(existingAI, configuration: .init(personaID: existingAI.id, role: "案内", instructions: "簡潔に"))
            try repository.create(mentionedThought, authorPersonaID: Persona.defaultHumanID, mentions: [
                .init(thoughtID: mentionedThought.id, personaID: existingAI.id, handleSnapshot: "navi", rangeLocation: 0, rangeLength: 5)
            ])
        }
        try fixture.installLegacyUniquePersonaAccountSchema()

        do {
            let migrated = try fixture.repository()
            let mio = Persona(displayName: "Mio", handle: "mio_ai", kind: .ai)
            let vespera = Persona(displayName: "Vespera", handle: "vespera", kind: .ai)
            try migrated.createAIPersona(mio, configuration: .init(personaID: mio.id, role: "対話", instructions: "短く"))
            try migrated.createAIPersona(vespera, configuration: .init(personaID: vespera.id, role: "洞察", instructions: "短く"))

            #expect(try fixture.personaAccountIDs() == Set(["user-001"]))
            #expect(try migrated.fetchAIConfigurations().keys.count == 3)
            #expect(try migrated.fetchMentionedPersonas(for: [mentionedThought.id])[mentionedThought.id]?.id == existingAI.id)
            #expect(try migrated.fetchPersona(for: mentionedThought.id)?.id == Persona.defaultHumanID)

            var edited = mio
            edited.displayName = "Mio Updated"
            edited.handle = "mio_updated"
            try migrated.updatePersona(edited)
            #expect(try migrated.fetchPersonas(includeInactive: false).contains { $0.id == mio.id && $0.handle == "mio_updated" })
            #expect(try migrated.deactivatePersona(id: vespera.id, at: Date()))

            #expect(throws: SQLiteThoughtRepositoryError.self) {
                try migrated.createPersona(Persona(displayName: "Duplicate", handle: "NAVI", kind: .ai))
            }
        }

        let reopened = try fixture.repository()
        #expect(try reopened.fetchPersonas(includeInactive: true).count == 4)
        #expect(try reopened.fetchPersonas(includeInactive: false).count == 3)
        #expect(try reopened.fetchAIConfigurations()[existingAI.id]?.role == "案内")
        #expect(try fixture.sqliteUserVersion() == SQLiteThoughtRepository.schemaVersion)
        #expect(try fixture.hasUniquePersonaAccountIndex() == false)
    }

    @Test func humanAndAIMentionsPersistSnapshotsRangesAndSurviveHandleChange() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        var human = try repository.fetchDefaultHumanPersona(); human.handle = "masaya"; try repository.updatePersona(human)
        var ai = Persona(displayName: "Developer AI", handle: "dev_ai", kind: .ai)
        try repository.createAIPersona(ai, configuration: .init(personaID: ai.id, role: "開発", instructions: "短く"))
        let thought = Thought(body: "@masaya @dev_ai 確認")
        try repository.create(thought, authorPersonaID: human.id, mentions: [
            .init(thoughtID: thought.id, personaID: human.id, handleSnapshot: "masaya", rangeLocation: 0, rangeLength: 7),
            .init(thoughtID: thought.id, personaID: ai.id, handleSnapshot: "dev_ai", rangeLocation: 8, rangeLength: 7)
        ])
        ai.handle = "review_ai"; try repository.updatePersona(ai)
        let mentions = try repository.fetchMentions(for: [thought.id])[thought.id] ?? []
        #expect(mentions.map(\.personaID) == [human.id, ai.id])
        #expect(mentions.map(\.handleSnapshot) == ["masaya", "dev_ai"])
        #expect(try repository.fetchMentionedPersonas(for: [thought.id])[thought.id] != nil)
    }

    @Test func existingAndNewThoughtsUseDefaultHumanAndProfilePersists() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = Thought(body: "移行前")
        try fixture.writeV1Database(thought: existing)

        let repository = try fixture.repository()
        let initial = try repository.fetchDefaultHumanPersona()
        #expect(initial.id == Persona.defaultHumanID)
        #expect(initial.displayName == "自分")
        #expect(try repository.fetchPersona(for: existing.id)?.id == initial.id)

        let icon = Data([0x01, 0x02, 0x03])
        var updated = initial
        updated.displayName = "ススム"
        updated.iconData = icon
        updated.iconMIMEType = "image/jpeg"
        updated.updatedAt = Date(timeIntervalSince1970: 500)
        try repository.updatePersona(updated)

        let newThought = Thought(body: "移行後")
        try repository.create(newThought)
        let ai = Persona(displayName: "整理役", kind: .ai, createdAt: Date(timeIntervalSince1970: 600))
        try repository.createPersona(ai)
        let aiThought = Thought(body: "AIからの投稿")
        try repository.create(aiThought, authorPersonaID: ai.id)
        let reopened = try fixture.repository()
        #expect(try reopened.fetchDefaultHumanPersona().displayName == "ススム")
        #expect(try reopened.fetchDefaultHumanPersona().iconData == icon)
        #expect(try reopened.fetchPersona(for: newThought.id)?.id == Persona.defaultHumanID)
        #expect(try reopened.fetchPersona(for: aiThought.id) == ai)
        #expect(try reopened.fetchPersonas(includeInactive: false).map(\.id).contains(ai.id))
        #expect(try reopened.deactivatePersona(id: ai.id, at: Date(timeIntervalSince1970: 700)))
        #expect(!(try reopened.fetchPersonas(includeInactive: false)).map(\.id).contains(ai.id))
        #expect(try reopened.fetchPersona(for: aiThought.id)?.displayName == "整理役")
        #expect(try reopened.deactivatePersona(id: Persona.defaultHumanID, at: Date()) == false)
    }


    @Test func authoredThoughtRollsBackWhenPersonaIsMissing() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let thought = Thought(body: "保存されない")
        #expect(throws: SQLiteThoughtRepositoryError.self) { try repository.create(thought, authorPersonaID: UUID()) }
        #expect(try repository.fetchByID(thought.id) == nil)
    }

    @Test func explicitPreviewGeneratesAndAtomicallySavesAIAuthoredThought() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let persona = Persona(displayName: "問いかけ役", kind: .ai)
        let configuration = AIPersonaConfiguration(personaID: persona.id, role: "視点を増やす", instructions: "短く問いかける")
        try repository.createAIPersona(persona, configuration: configuration)
        let preview = try AIPostPrompt.prepare(persona: persona, configuration: configuration, userRequest: "今日の記録に反応して")
        let thoughtID = UUID(), now = Date(timeIntervalSince1970: 800)
        let thought = try await GenerateAIPost(client: MockReviewSummaryClient(text: "別の見方もありそう。"), repository: repository)(preview: preview, now: now, thoughtID: thoughtID)
        #expect(thought.body == "別の見方もありそう。")
        #expect(try repository.fetchPersona(for: thoughtID)?.id == persona.id)
        #expect(preview.request.prompt.contains("送信を押す") == false)
    }

    @Test func repairsMissingColumnsInExistingV13DatabaseWithoutLosingAIPostData() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let persona = Persona(displayName: "既存AI", kind: .ai)
        let configuration = AIPersonaConfiguration(personaID: persona.id, role: "記録", instructions: "短く")
        let thoughtID = UUID()
        do {
            let repository = try fixture.repository()
            try repository.createAIPersona(persona, configuration: configuration)
            let preview = try AIPostPrompt.prepare(persona: persona, configuration: configuration, userRequest: "既存データ")
            _ = try await GenerateAIPost(client: MockReviewSummaryClient(text: "保持されるAI投稿"), repository: repository)(preview: preview, now: Date(timeIntervalSince1970: 800), thoughtID: thoughtID)
        }
        try fixture.removeDefensivelyMigratedColumnsAndMarkV13()

        do {
            let repaired = try fixture.repository()
            #expect(try fixture.tableColumns("ai_post_generations").isSuperset(of: ["thought_id", "persona_id", "user_request", "provider", "model", "prompt_version", "generated_at", "generation_kind", "reply_target_thought_id"]))
            #expect(try fixture.tableColumns("ai_api_usage").isSuperset(of: ["id", "started_at", "finished_at", "feature", "persona_id", "provider", "model", "status", "input_characters", "output_characters", "input_tokens", "output_tokens", "total_tokens", "latency_milliseconds", "external_brain_used", "retrieved_chunk_count", "error_category", "source_type"]))
            #expect(try fixture.tableColumns("knowledge_documents").isSuperset(of: ["status", "superseded_by_knowledge_id", "superseded_at", "archived_at", "retrieval_count", "last_retrieved_at"]))
            #expect(try repaired.fetchAIConfigurations()[persona.id]?.autoReplyEnabled == true)
            #expect(try repaired.fetchAIConfigurations()[persona.id]?.provider == .gemini)
            let generation = try repaired.fetchAIPostGeneration(for: thoughtID)
            #expect(generation?.kind == .standalone)
            #expect(generation?.replyTargetThoughtID == nil)
            #expect(try repaired.fetchByID(thoughtID)?.body == "保持されるAI投稿")
            #expect(try fixture.sqliteUserVersion() == SQLiteThoughtRepository.schemaVersion)
        }

        let reopened = try fixture.repository()
        #expect(try reopened.fetchAIPostGeneration(for: thoughtID)?.kind == .standalone)
    }

    @Test func repairsLegacyRelationConstraintEvenWhenDatabaseClaimsCurrentSchema() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let parent = Thought(body: "既存Thought", createdAt: Date(timeIntervalSince1970: 100))
        do {
            let repository = try fixture.repository()
            try repository.create(parent)
            _ = try repository.createContinuation(body: "既存Continuation", parentThoughtID: parent.id, now: Date(timeIntervalSince1970: 200))
        }
        try fixture.replaceRelationTableWithLegacyConstraintAndMarkV14()

        let repaired = try fixture.repository()
        let reply = try repaired.createHumanReply(
            body: "修復後の返信",
            targetThoughtID: parent.id,
            mentionedPersonaID: nil,
            now: Date(timeIntervalSince1970: 300),
            thoughtID: UUID(),
            relationID: UUID()
        )

        #expect(reply?.body == "修復後の返信")
        #expect(try repaired.fetchAIReplies(to: parent.id).map(\.body).contains("修復後の返信"))
        #expect(try fixture.sqliteUserVersion() == SQLiteThoughtRepository.schemaVersion)
    }

    @Test func detectsMissingCriticalTableEvenWhenDatabaseClaimsCurrentSchema() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        do { _ = try fixture.repository() }
        try fixture.dropTagsTableAndMarkCurrent()

        #expect(throws: SQLiteThoughtRepositoryError.self) {
            _ = try fixture.repository()
        }
    }

    @Test func overlongAIResponseIsNeverPosted() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let persona = Persona(displayName: "長文AI", kind: .ai)
        let configuration = AIPersonaConfiguration(personaID: persona.id, role: "補助", instructions: "簡潔に")
        try repository.createAIPersona(persona, configuration: configuration)
        let preview = try AIPostPrompt.prepare(persona: persona, configuration: configuration, userRequest: "投稿して")
        await #expect(throws: AIPostError.responseTooLong) { try await GenerateAIPost(client: MockReviewSummaryClient(text: String(repeating: "あ", count: 141)), repository: repository)(preview: preview) }
        #expect(try repository.fetchTimeline().isEmpty)
    }

    @Test func aiPersonaProviderPersistsAndFreezesIntoGenerationRequest() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let persona = Persona(displayName: "OpenAI Persona", kind: .ai)
        let configuration = AIPersonaConfiguration(
            personaID: persona.id,
            role: "整理",
            instructions: "簡潔に",
            provider: .openAI
        )
        try repository.createAIPersona(persona, configuration: configuration)

        let reopened = try fixture.repository()
        let saved = try #require(reopened.fetchAIConfigurations()[persona.id])
        let preview = try AIPostPrompt.prepare(persona: persona, configuration: saved, userRequest: "投稿して")

        #expect(saved.provider == .openAI)
        #expect(preview.request.provider == .openAI)
        #expect(preview.request.generationProfile == .concisePersona)
        #expect(preview.request.generationProfile.reasoningEffort == .low)
        #expect(preview.request.generationProfile.maxOutputTokens == 1_024)
        #expect(try fixture.sqliteUserVersion() == SQLiteThoughtRepository.schemaVersion)
    }

    @Test func mentionIsStoredAtomicallyByPersonaIDWithoutStartingAI() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let ai = Persona(displayName: "整理役", kind: .ai)
        try repository.createAIPersona(ai, configuration: AIPersonaConfiguration(personaID: ai.id, role: "整理", instructions: "短く"))
        let thought = Thought(body: "@文字列ではなく関連で保存")
        try repository.create(thought, authorPersonaID: Persona.defaultHumanID, mentionedPersonaID: ai.id)
        #expect(try repository.fetchMentionedPersonas(for: [thought.id])[thought.id]?.id == ai.id)
        #expect(try repository.fetchPersona(for: thought.id)?.kind == .human)

        let invalid = Thought(body: "無効なメンション")
        #expect(throws: SQLiteThoughtRepositoryError.self) { try repository.create(invalid, authorPersonaID: Persona.defaultHumanID, mentionedPersonaID: UUID()) }
        #expect(try repository.fetchByID(invalid.id) == nil)
    }

    @Test func replyPromptContainsOnlyPersonaAndTargetContext() throws {
        let persona = Persona(displayName: "ノア", kind: .ai)
        let configuration = AIPersonaConfiguration(personaID: persona.id, role: "思考整理", instructions: "否定せず別視点を返す")
        let target = Thought(body: "最近、開発ツールを作りすぎている気がする")
        let context = AIReplyContext(entries: [AIReplyContextEntry(thought: target, author: Persona(displayName: "自分", kind: .human))], targetThoughtID: target.id, relations: [])
        let preview = try AIThoughtReplyPrompt.prepare(persona: persona, configuration: configuration, targetThought: target, userRequest: "意見をください", context: context)
        #expect(preview.request.prompt.contains("ノア")); #expect(preview.request.prompt.contains(configuration.role)); #expect(preview.request.prompt.contains(configuration.instructions)); #expect(preview.request.prompt.contains(target.body)); #expect(preview.request.prompt.contains("140文字以内"))
        #expect(preview.request.prompt.contains("意見をください")); #expect(preview.request.prompt.contains("[Human: 自分]")); #expect(preview.request.prompt.contains("返信対象:"))
    }

    @Test func replyRejectsEmptyOverlongInactiveAndDeletedInputs() async throws {
        let repository = MemoryThoughtRepository()
        let persona = Persona(displayName: "ノア", kind: .ai)
        let configuration = AIPersonaConfiguration(personaID: persona.id, role: "整理", instructions: "短く")
        try repository.createAIPersona(persona, configuration: configuration)
        let target = Thought(body: "考えを整理したい")
        try repository.create(target)
        let context = try repository.loadAIReplyContext(targetThoughtID: target.id, maximumEntries: 5)
        let preview = try AIThoughtReplyPrompt.prepare(persona: persona, configuration: configuration, targetThought: target, userRequest: "返信して", context: context)
        await #expect(throws: AIPostError.emptyResponse) { try await GenerateAIThoughtReply(client: MockReviewSummaryClient(text: "  \n"), repository: repository)(preview: preview) }
        await #expect(throws: AIPostError.responseTooLong) { try await GenerateAIThoughtReply(client: MockReviewSummaryClient(text: String(repeating: "あ", count: 141)), repository: repository)(preview: preview) }
        var inactive = persona; inactive.deletedAt = Date()
        #expect(throws: AIPostError.inactivePersona) { try AIThoughtReplyPrompt.prepare(persona: inactive, configuration: configuration, targetThought: target, userRequest: "返信して", context: context) }
        var deleted = target; deleted.deletedAt = Date()
        let deletedContext = AIReplyContext(entries: [AIReplyContextEntry(thought: deleted, author: Persona(displayName: "自分", kind: .human))], targetThoughtID: deleted.id, relations: [])
        #expect(throws: AIPostError.invalidRequest) { try AIThoughtReplyPrompt.prepare(persona: persona, configuration: configuration, targetThought: deleted, userRequest: "返信して", context: deletedContext) }
        #expect(try repository.fetchTimeline().count == 1)
    }

    @Test func generatedReplyPersistsRelationMetadataAndRejectsDuplicateForSameHumanReply() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let repository = try fixture.repository()
        let personaDate = Date(timeIntervalSince1970: 900)
        let persona = Persona(displayName: "ノア", kind: .ai, createdAt: personaDate, updatedAt: personaDate)
        let configuration = AIPersonaConfiguration(personaID: persona.id, role: "整理", instructions: "短く", updatedAt: personaDate)
        try repository.createAIPersona(persona, configuration: configuration)
        let target = Thought(body: "この考えどう思う？", createdAt: Date(timeIntervalSince1970: 1_000))
        try repository.create(target, authorPersonaID: Persona.defaultHumanID, mentionedPersonaID: persona.id)
        let context = try repository.loadAIReplyContext(targetThoughtID: target.id, maximumEntries: 5)
        #expect(context.entries.last?.thought == target)
        let preview = try AIThoughtReplyPrompt.prepare(persona: persona, configuration: configuration, targetThought: target, userRequest: "返信して", context: context)
        let firstID = UUID()
        _ = try await GenerateAIThoughtReply(client: MockReviewSummaryClient(text: "一つ目の返信"), repository: repository)(preview: preview, now: Date(timeIntervalSince1970: 10), thoughtID: firstID)
        await #expect(throws: AIPostError.duplicateReply) { try await GenerateAIThoughtReply(client: MockReviewSummaryClient(text: "二つ目の返信"), repository: repository)(preview: preview) }
        #expect(try repository.fetchAIReplies(to: target.id).map(\.id) == [firstID])
        #expect(try repository.fetchBySourceThoughtID(firstID).first?.type == .repliesTo)
        let generation = try repository.fetchAIPostGeneration(for: firstID)
        #expect(generation?.kind == .reply); #expect(generation?.replyTargetThoughtID == target.id); #expect(generation?.personaID == persona.id)
        #expect(try repository.fetchContinuations(of: target.id).isEmpty)
    }

    @Test func differentAIPersonasCanReplyOnceEachToTheSameThought() async throws {
        let repository = MemoryThoughtRepository()
        let mio = Persona(displayName: "Mio", handle: "mio", kind: .ai)
        let navi = Persona(displayName: "Navi", handle: "navi", kind: .ai)
        try repository.createAIPersona(mio, configuration: .init(personaID: mio.id, role: "対話", instructions: "簡潔に"))
        try repository.createAIPersona(navi, configuration: .init(personaID: navi.id, role: "案内", instructions: "簡潔に"))
        let target = Thought(body: "@mio @navi どう思う？")
        try repository.create(target, authorPersonaID: Persona.defaultHumanID, mentions: [
            .init(thoughtID: target.id, personaID: mio.id, handleSnapshot: "mio", rangeLocation: 0, rangeLength: 4),
            .init(thoughtID: target.id, personaID: navi.id, handleSnapshot: "navi", rangeLocation: 5, rangeLength: 5)
        ])
        for persona in [mio, navi] {
            let context = try repository.loadAIReplyContext(targetThoughtID: target.id, maximumEntries: 5)
            let preview = try AIThoughtReplyPrompt.prepare(persona: persona, configuration: try #require(repository.fetchAIConfigurations()[persona.id]), targetThought: target, userRequest: "返信", context: context)
            _ = try await GenerateAIThoughtReply(client: MockReviewSummaryClient(text: "\(persona.displayName)の返信"), repository: repository)(preview: preview)
        }
        #expect(try repository.fetchAIReplies(to: target.id).count == 2)
        #expect(try repository.fetchMentions(for: [target.id])[target.id]?.count == 2)
    }

    @Test func replyGenerationStopsWhenTargetWasDeletedAfterPreview() async throws {
        let repository = MemoryThoughtRepository()
        let persona = Persona(displayName: "ノア", kind: .ai)
        let configuration = AIPersonaConfiguration(personaID: persona.id, role: "整理", instructions: "短く")
        try repository.createAIPersona(persona, configuration: configuration)
        let target = Thought(body: "対象"); try repository.create(target)
        let preview = try AIThoughtReplyPrompt.prepare(persona: persona, configuration: configuration, targetThought: target, userRequest: "返信して", context: repository.loadAIReplyContext(targetThoughtID: target.id, maximumEntries: 5))
        _ = try repository.softDelete(id: target.id, at: Date())
        await #expect(throws: ReviewSummaryError.stalePreview) { try await GenerateAIThoughtReply(client: MockReviewSummaryClient(text: "保存されない"), repository: repository)(preview: preview) }
        #expect(try repository.fetchTimeline().isEmpty)
    }

    @Test func replyContextUsesOnlyReplyChainLatestFiveInOldestFirstOrder() throws {
        let thoughts = (0..<7).map { Thought(body: "会話\($0)", createdAt: Date(timeIntervalSince1970: Double($0))) }
        var relations = (1..<7).map { ThoughtRelation(sourceThoughtID: thoughts[$0].id, targetThoughtID: thoughts[$0 - 1].id, type: .repliesTo, createdAt: thoughts[$0].createdAt) }
        relations.append(ThoughtRelation(sourceThoughtID: thoughts[6].id, targetThoughtID: thoughts[0].id, type: .continues))
        let repository = MemoryThoughtRepository(records: thoughts, relations: relations)
        let context = try repository.loadAIReplyContext(targetThoughtID: thoughts[6].id, maximumEntries: 5)
        #expect(context.entries.map(\.thought.id) == Array(thoughts[2...6]).map(\.id))
        #expect(context.entries.map(\.author.kind).allSatisfy { $0 == .human })
        #expect(context.relations.allSatisfy { $0.type == .repliesTo })
    }

    @Test func replyContextSkipsDeletedThoughtAndStopsAtCycleWithoutDuplicates() throws {
        var a = Thought(body: "A"), b = Thought(body: "B"), c = Thought(body: "C")
        b.deletedAt = Date()
        let relations = [
            ThoughtRelation(sourceThoughtID: b.id, targetThoughtID: a.id, type: .repliesTo),
            ThoughtRelation(sourceThoughtID: c.id, targetThoughtID: b.id, type: .repliesTo),
            ThoughtRelation(sourceThoughtID: a.id, targetThoughtID: c.id, type: .repliesTo)
        ]
        let repository = MemoryThoughtRepository(records: [a, b, c], relations: relations)
        let context = try repository.loadAIReplyContext(targetThoughtID: c.id, maximumEntries: 5)
        #expect(context.entries.map(\.thought.id) == [a.id, c.id])
        #expect(Set(context.entries.map(\.thought.id)).count == context.entries.count)
    }

    @Test func replyContextPreservesHumanAndInactiveAIAuthors() throws {
        let repository = MemoryThoughtRepository()
        let human = Thought(body: "Human"); try repository.create(human)
        var ai = Persona(displayName: "Architect", kind: .ai)
        try repository.createPersona(ai)
        let aiThought = Thought(body: "AI"); try repository.create(aiThought, authorPersonaID: ai.id)
        try repository.create(ThoughtRelation(sourceThoughtID: aiThought.id, targetThoughtID: human.id, type: .repliesTo))
        ai.deletedAt = Date(); try repository.updatePersona(ai)
        let context = try repository.loadAIReplyContext(targetThoughtID: aiThought.id, maximumEntries: 5)
        #expect(context.entries.map(\.author.kind) == [.human, .ai])
        #expect(context.entries.last?.author.displayName == "Architect")
    }

    @Test func changedReplyContextRejectsStalePreviewBeforeGeneration() async throws {
        let repository = MemoryThoughtRepository()
        let persona = Persona(displayName: "ノア", kind: .ai)
        let configuration = AIPersonaConfiguration(personaID: persona.id, role: "整理", instructions: "短く")
        try repository.createAIPersona(persona, configuration: configuration)
        let parent = Thought(body: "親"), target = Thought(body: "対象")
        try repository.create(parent); try repository.create(target)
        let preview = try AIThoughtReplyPrompt.prepare(persona: persona, configuration: configuration, targetThought: target, userRequest: "返信して", context: repository.loadAIReplyContext(targetThoughtID: target.id, maximumEntries: 5))
        try repository.create(ThoughtRelation(sourceThoughtID: target.id, targetThoughtID: parent.id, type: .repliesTo))
        await #expect(throws: ReviewSummaryError.stalePreview) { try await GenerateAIThoughtReply(client: MockReviewSummaryClient(text: "呼ばれない"), repository: repository)(preview: preview) }
        #expect(try repository.fetchTimeline().count == 2)
    }

    @Test func inactiveReplyPersonaStopsBeforeGeneration() async throws {
        let repository = MemoryThoughtRepository()
        let persona = Persona(displayName: "ノア", kind: .ai)
        let actualConfiguration = AIPersonaConfiguration(personaID: persona.id, role: "整理", instructions: "短く")
        try repository.createAIPersona(persona, configuration: actualConfiguration)
        let target = Thought(body: "対象"); try repository.create(target)
        let preview = try AIThoughtReplyPrompt.prepare(persona: persona, configuration: actualConfiguration, targetThought: target, userRequest: "返信して", context: repository.loadAIReplyContext(targetThoughtID: target.id, maximumEntries: 5))
        _ = try repository.deactivatePersona(id: persona.id, at: Date())
        await #expect(throws: AIPostError.inactivePersona) { try await GenerateAIThoughtReply(client: MockReviewSummaryClient(text: "呼ばれない"), repository: repository)(preview: preview) }
        #expect(try repository.fetchTimeline().map(\.id) == [target.id])
    }

    @Test func humanReplyToAIContinuesReplyChainAndMentionsThatAI() throws {
        let repository = MemoryThoughtRepository()
        let ai = Persona(displayName: "Architect", kind: .ai); try repository.createPersona(ai)
        let root = Thought(body: "Human"); try repository.create(root)
        let aiReply = Thought(body: "AI"); try repository.create(aiReply, authorPersonaID: ai.id); try repository.create(ThoughtRelation(sourceThoughtID: aiReply.id, targetThoughtID: root.id, type: .repliesTo))
        let humanReply = try repository.createHumanReply(body: "Human again", targetThoughtID: aiReply.id, mentionedPersonaID: ai.id, now: Date(), thoughtID: UUID(), relationID: UUID())!
        let context = try repository.loadAIReplyContext(targetThoughtID: humanReply.id, maximumEntries: 5)
        #expect(context.entries.map(\.thought.id) == [root.id, aiReply.id, humanReply.id])
        #expect(context.entries.map(\.author.kind) == [.human, .ai, .human])
        #expect(try repository.fetchMentionedPersonas(for: [humanReply.id])[humanReply.id]?.id == ai.id)
        #expect(try repository.fetchContinuations(of: aiReply.id).isEmpty)
    }

    @Test func generatedReplyWaitsForPreviewPublicationAndSupportsAnotherHumanTurn() async throws {
        let repository = MemoryThoughtRepository()
        let ai = Persona(displayName: "Architect", kind: .ai)
        let configuration = AIPersonaConfiguration(personaID: ai.id, role: "設計", instructions: "簡潔に", autoReplyEnabled: true)
        try repository.createAIPersona(ai, configuration: configuration)
        let firstHuman = Thought(body: "最初の質問")
        try repository.create(firstHuman, authorPersonaID: Persona.defaultHumanID, mentionedPersonaID: ai.id)
        let preview = try AIThoughtReplyPrompt.prepare(persona: ai, configuration: configuration, targetThought: firstHuman, userRequest: "返信して", context: repository.loadAIReplyContext(targetThoughtID: firstHuman.id, maximumEntries: 5))
        let generator = GenerateAIThoughtReply(client: MockReviewSummaryClient(text: "AIの返答"), repository: repository)
        let draft = try await generator.generate(preview: preview)
        #expect(try repository.fetchAIReplies(to: firstHuman.id).isEmpty)
        let aiReply = try generator.publish(draft: draft)
        let secondHuman = try repository.createHumanReply(body: "もう少し教えて", targetThoughtID: aiReply.id, mentionedPersonaID: ai.id, now: Date(), thoughtID: UUID(), relationID: UUID())!
        let nextContext = try repository.loadAIReplyContext(targetThoughtID: secondHuman.id, maximumEntries: 5)
        #expect(nextContext.entries.map(\.author.kind) == [.human, .ai, .human])
        #expect(nextContext.entries.map(\.thought.body) == ["最初の質問", "AIの返答", "もう少し教えて"])
        #expect((try repository.fetchAIConfigurations()[ai.id])?.autoReplyEnabled == true)
    }
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct Fixture {
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("thought-timeline.sqlite3") }
    var jsonURL: URL { directory.appendingPathComponent("thoughts.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func repository() throws -> SQLiteThoughtRepository {
        try SQLiteThoughtRepository(databaseURL: databaseURL, legacyJSONURL: jsonURL)
    }

    func writeLegacyJSON(_ thoughts: [Thought]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(thoughts).write(to: jsonURL)
    }

    func writeV1Database(thought: Thought) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let escapedBody = thought.body.replacingOccurrences(of: "'", with: "''")
        let deleted = thought.deletedAt.map { String($0.timeIntervalSince1970) } ?? "NULL"
        let sql = """
            CREATE TABLE thoughts (id TEXT PRIMARY KEY NOT NULL, body TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL NULL);
            CREATE TABLE migrations (name TEXT PRIMARY KEY NOT NULL, completed_at REAL NOT NULL);
            INSERT INTO thoughts VALUES ('\(thought.id.uuidString)', '\(escapedBody)', \(thought.createdAt.timeIntervalSince1970), \(thought.updatedAt.timeIntervalSince1970), \(deleted));
            PRAGMA user_version = 1;
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func writeV3Database(thought: Thought) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let escapedBody = thought.body.replacingOccurrences(of: "'", with: "''")
        let sql = """
            CREATE TABLE thoughts (id TEXT PRIMARY KEY NOT NULL, body TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL NULL);
            CREATE TABLE migrations (name TEXT PRIMARY KEY NOT NULL, completed_at REAL NOT NULL);
            CREATE TABLE thought_relations (id TEXT PRIMARY KEY NOT NULL, source_thought_id TEXT NOT NULL REFERENCES thoughts(id), target_thought_id TEXT NOT NULL REFERENCES thoughts(id), relation_type TEXT NOT NULL CHECK (relation_type = 'continues'), created_at REAL NOT NULL, CHECK (source_thought_id <> target_thought_id), UNIQUE (source_thought_id, target_thought_id, relation_type));
            CREATE TABLE review_summaries (id TEXT PRIMARY KEY NOT NULL, period_start REAL NOT NULL, period_end REAL NOT NULL, content TEXT NOT NULL, created_at REAL NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, prompt_version INTEGER NOT NULL, thought_count INTEGER NOT NULL CHECK (thought_count > 0), CHECK (period_start < period_end));
            INSERT INTO thoughts VALUES ('\(thought.id.uuidString)', '\(escapedBody)', \(thought.createdAt.timeIntervalSince1970), \(thought.updatedAt.timeIntervalSince1970), NULL);
            PRAGMA user_version = 3;
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func removeDefensivelyMigratedColumnsAndMarkV13() throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let sql = """
            PRAGMA foreign_keys = OFF;
            DROP INDEX IF EXISTS ai_post_generations_reply_target_idx;
            ALTER TABLE ai_post_generations RENAME TO ai_post_generations_current;
            CREATE TABLE ai_post_generations (
                thought_id TEXT PRIMARY KEY NOT NULL REFERENCES thoughts(id),
                persona_id TEXT NOT NULL REFERENCES personas(id),
                user_request TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                prompt_version INTEGER NOT NULL,
                generated_at REAL NOT NULL
            );
            INSERT INTO ai_post_generations (thought_id, persona_id, user_request, provider, model, prompt_version, generated_at)
                SELECT thought_id, persona_id, user_request, provider, model, prompt_version, generated_at
                FROM ai_post_generations_current;
            DROP TABLE ai_post_generations_current;
            CREATE INDEX ai_post_generations_persona_idx ON ai_post_generations(persona_id, generated_at DESC);
            DROP TABLE ai_api_usage;
            ALTER TABLE ai_persona_configurations DROP COLUMN provider;
            ALTER TABLE knowledge_documents DROP COLUMN status;
            ALTER TABLE knowledge_documents DROP COLUMN superseded_by_knowledge_id;
            ALTER TABLE knowledge_documents DROP COLUMN superseded_at;
            ALTER TABLE knowledge_documents DROP COLUMN archived_at;
            ALTER TABLE knowledge_documents DROP COLUMN retrieval_count;
            ALTER TABLE knowledge_documents DROP COLUMN last_retrieved_at;
            PRAGMA user_version = 13;
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func replaceRelationTableWithLegacyConstraintAndMarkV14() throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let sql = """
            PRAGMA foreign_keys = OFF;
            ALTER TABLE thought_relations RENAME TO thought_relations_current;
            CREATE TABLE thought_relations (
                id TEXT PRIMARY KEY NOT NULL,
                source_thought_id TEXT NOT NULL REFERENCES thoughts(id),
                target_thought_id TEXT NOT NULL REFERENCES thoughts(id),
                relation_type TEXT NOT NULL CHECK (relation_type = 'continues'),
                created_at REAL NOT NULL,
                CHECK (source_thought_id <> target_thought_id),
                UNIQUE (source_thought_id, target_thought_id, relation_type)
            );
            INSERT INTO thought_relations SELECT * FROM thought_relations_current;
            DROP TABLE thought_relations_current;
            CREATE INDEX thought_relations_source_idx ON thought_relations(source_thought_id);
            CREATE INDEX thought_relations_target_idx ON thought_relations(target_thought_id);
            PRAGMA user_version = 14;
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func dropTagsTableAndMarkCurrent() throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let sql = """
            PRAGMA foreign_keys = OFF;
            DROP TABLE thought_tags;
            DROP TABLE tags;
            PRAGMA user_version = 15;
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func installLegacyUniquePersonaAccountSchema() throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        let sql = """
            UPDATE personas
            SET account_id = CASE
                WHEN id = '\(Persona.defaultHumanID.uuidString)' THEN 'user-001'
                ELSE 'legacy-' || lower(substr(replace(id, '-', ''), 1, 8))
            END;
            CREATE UNIQUE INDEX personas_account_id_unique ON personas(account_id);
            PRAGMA user_version = 17;
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    func personaAccountIDs() throws -> Set<String> {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT DISTINCT account_id FROM personas", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var values = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { values.insert(String(cString: text)) }
        }
        return values
    }

    func hasUniquePersonaAccountIndex() throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw SQLiteThoughtRepositoryError.open("test setup")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA index_list(personas)", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_int(statement, 2) != 0, let nameText = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: nameText)
            if name.contains("account_id") { return true }
        }
        return false
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
