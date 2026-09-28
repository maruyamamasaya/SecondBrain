import Foundation
import Testing
@testable import ThoughtCore

@Suite("週間振り返り")
struct WeeklyReviewTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "ja_JP"); value.timeZone = TimeZone(identifier: "Asia/Tokyo")!; value.firstWeekday = 2
        return value
    }

    @Test func completedWeekIsPreviousMondayThroughSunday() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
        let interval = WeeklyReviewPeriod.completedWeek(before: date, calendar: calendar)
        #expect(interval.start == calendar.date(from: DateComponents(year: 2026, month: 9, day: 7)))
        #expect(interval.end == calendar.date(from: DateComponents(year: 2026, month: 9, day: 14)))
    }

    @Test func previewUsesHumanThoughtsAndTerraProfile() throws {
        let interval = WeeklyReviewPeriod.week(containing: calendar.date(from: DateComponents(year: 2026, month: 9, day: 8))!, calendar: calendar)
        let repository = MemoryThoughtRepository()
        let human = Thought(body: "今週の設計を考えた", createdAt: interval.start.addingTimeInterval(60))
        try repository.create(human)
        let ai = Persona(displayName: "AI", handle: "weekly_ai", kind: .ai, createdAt: interval.start, updatedAt: interval.start)
        try repository.createAIPersona(ai, configuration: .init(personaID: ai.id, role: "補助", instructions: "短く"))
        try repository.create(Thought(body: "AIの発言", createdAt: interval.start.addingTimeInterval(120)), authorPersonaID: ai.id)
        let preview = try PrepareWeeklySummary(repository: repository)(interval: interval, calendar: calendar)
        #expect(preview.thoughts == [human])
        #expect(preview.request.provider == .openAI)
        #expect(preview.request.model == ReviewSummaryAIConfiguration.weeklyReviewModelName)
        #expect(preview.request.generationProfile == .weeklySummary)
        #expect(preview.request.generationProfile.reasoningEffort == .medium)
        #expect(preview.request.generationProfile.maxOutputTokens == 8_192)
        #expect(!preview.request.prompt.contains("AIの発言"))
    }

    @Test func summaryReplacesSameWeekAndPlanRequiresExplicitSave() async throws {
        let repository = MemoryThoughtRepository()
        let interval = WeeklyReviewPeriod.completedWeek(before: Date(), calendar: calendar)
        try repository.create(Thought(body: "振り返る", createdAt: interval.start.addingTimeInterval(60)))
        let preview = try PrepareWeeklySummary(repository: repository)(interval: interval, calendar: calendar)
        let summaryJSON = #"{"overview":"概要","themes":["設計"],"changes":[],"recurringTopics":[],"thoughtDevelopments":[],"notableThoughts":[],"unresolvedQuestions":["次は何か"]}"#
        let first = try await GenerateWeeklySummary(client: MockReviewSummaryClient(text: summaryJSON), repository: repository)(preview: preview)
        _ = try await GenerateWeeklySummary(client: MockReviewSummaryClient(text: summaryJSON), repository: repository)(preview: preview)
        #expect(try repository.fetchWeeklySummaries().count == 1)

        let planJSON = #"{"focus":"小さく進める","actions":["試す"],"questions":["何を残すか"],"note":""}"#
        let draft = try await GenerateWeeklyPlanDraft(client: MockReviewSummaryClient(text: planJSON))(summary: first)
        #expect(try repository.fetchWeeklyPlan(targetWeekStart: draft.targetInterval.start) == nil)
        #expect(draft.content.actions.count == 1)
        let plan = WeeklyPlan(targetWeekStart: draft.targetInterval.start, targetWeekEnd: draft.targetInterval.end, sourceSummaryID: first.id, content: draft.content, provider: draft.provider, model: draft.model, promptVersion: WeeklyPlanPrompt.version)
        try repository.saveWeeklyPlan(plan)
        #expect(try repository.fetchWeeklyPlan(targetWeekStart: draft.targetInterval.start) == plan)
    }

    @Test func sqliteRoundTripsWeeklySummaryAndPlan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try SQLiteThoughtRepository(databaseURL: directory.appendingPathComponent("test.sqlite3"))
        let interval = WeeklyReviewPeriod.completedWeek(before: Date(), calendar: calendar)
        let summary = WeeklySummary(weekStart: interval.start, weekEnd: interval.end, content: .init(overview: "概要", themes: [], changes: [], recurringTopics: [], thoughtDevelopments: [], notableThoughts: [], unresolvedQuestions: []), provider: "openai", model: "gpt-5.6-terra", promptVersion: 1, thoughtCount: 2)
        try repository.saveWeeklySummary(summary)
        #expect(try repository.fetchWeeklySummary(weekStart: interval.start) == summary)
        let plan = WeeklyPlan(targetWeekStart: interval.end, targetWeekEnd: calendar.date(byAdding: .weekOfYear, value: 1, to: interval.end)!, sourceSummaryID: summary.id, content: .init(focus: "軸", actions: ["行動"], questions: ["問い"]), provider: "openai", model: "gpt-5.6-terra", promptVersion: 1)
        try repository.saveWeeklyPlan(plan)
        #expect(try repository.fetchWeeklyPlan(targetWeekStart: interval.end) == plan)
        #expect(SQLiteThoughtRepository.schemaVersion == 21)
    }
}
