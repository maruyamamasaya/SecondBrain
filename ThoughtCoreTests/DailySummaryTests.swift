import Foundation
import Testing
@testable import ThoughtCore

@Suite("Daily Summary")
struct DailySummaryTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }

    @Test func preparesExactlyOneLocalDayAndExcludesDeletedThoughts() throws {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!
        let active = Thought(body: "対象", createdAt: start.addingTimeInterval(60), updatedAt: start)
        let deleted = Thought(body: "削除済み", createdAt: start.addingTimeInterval(120), updatedAt: start, deletedAt: start.addingTimeInterval(180))
        let outside = Thought(body: "翌日", createdAt: calendar.date(byAdding: .day, value: 1, to: start)!, updatedAt: start)
        let repository = MemoryThoughtRepository(records: [active, deleted, outside])
        let preview = try PrepareDailySummary(thoughts: repository, tags: repository, relations: repository)(day: start.addingTimeInterval(3_600), calendar: calendar)
        #expect(preview.interval.start == start)
        #expect(preview.interval.end == calendar.date(byAdding: .day, value: 1, to: start))
        #expect(preview.thoughts == [active])
        #expect(!preview.request.prompt.contains("削除済み"))
        #expect(!preview.request.prompt.contains("翌日"))
    }

    @Test func emptyDayCannotPrepare() {
        let repository = MemoryThoughtRepository()
        #expect(throws: ReviewSummaryError.noThoughts) {
            try PrepareDailySummary(thoughts: repository, tags: repository, relations: repository)(day: Date(), calendar: calendar)
        }
    }

    @Test func savesOneFormalSummaryAndDoesNotApplyTagCandidates() async throws {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!
        let thought = Thought(body: "比較して次を決める", createdAt: start.addingTimeInterval(60), updatedAt: start)
        let repository = MemoryThoughtRepository(records: [thought])
        let preview = try PrepareDailySummary(thoughts: repository, tags: repository, relations: repository)(day: start, calendar: calendar)
        let json = #"{"overview":"概要","themes":["仕事"],"existingTagCandidates":[],"newTagCandidates":["検討"],"thoughtPatterns":["比較・検討型"],"deepDives":["選択肢"],"concerns":["判断"],"thoughtFlow":"比較から決定","continuationCandidates":["検証"],"carryOvers":["実行"]}"#
        let summary = try await GenerateDailySummary(client: MockReviewSummaryClient(text: json), repository: repository)(preview: preview, now: start.addingTimeInterval(500))
        #expect(try repository.fetchDailySummary(dayStart: start) == summary)
        #expect(summary.content.newTagCandidates == ["検討"])
        #expect(try repository.fetchTags(for: thought.id).isEmpty)
    }

    @Test func sqliteDailySummarySurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timeline.sqlite3")
        let first = try SQLiteThoughtRepository(databaseURL: url)
        let start = calendar.startOfDay(for: Date())
        let thought = Thought(body: "保存確認", createdAt: start.addingTimeInterval(60), updatedAt: start)
        try first.create(thought)
        let preview = try PrepareDailySummary(thoughts: first, tags: first, relations: first)(day: start, calendar: calendar)
        let json = #"{"overview":"保存済み","themes":[],"existingTagCandidates":[],"newTagCandidates":[],"thoughtPatterns":[],"deepDives":[],"concerns":[],"thoughtFlow":"","continuationCandidates":[],"carryOvers":[]}"#
        _ = try await GenerateDailySummary(client: MockReviewSummaryClient(text: json), repository: first)(preview: preview)
        let reopened = try SQLiteThoughtRepository(databaseURL: url)
        #expect(try reopened.fetchDailySummary(dayStart: start)?.content.overview == "保存済み")
        #expect(SQLiteThoughtRepository.schemaVersion == 11)
    }
}
