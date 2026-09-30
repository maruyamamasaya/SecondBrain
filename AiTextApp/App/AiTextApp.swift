import SwiftUI

@main
struct AiTextApp: App {
    @StateObject private var store: ThoughtStore
    @StateObject private var themeController = ThemeController()

    init() {
        // UI tests use an isolated repository so automation never touches a
        // person's Application Support database.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-reflection-save") {
            // Isolated SQLite fixture: no production database or GitHub destination.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("reflection-ui-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repository = try! SQLiteThoughtRepository(databaseURL: root.appendingPathComponent("db.sqlite3"))
            let today = Calendar.current.startOfDay(for: Date())
            try? repository.create(Thought(body: "今日を振り返るための記録", createdAt: Date()))
            var journal = KnowledgeDraft(title: "保存待ちの日記", type: .journal, source: .dailyThoughts, createdAt: today, body: "端末に残る日記本文")
            journal.knowledgePath = ReflectionSave.path(for: journal); journal.syncStatus = .failed
            try? repository.saveKnowledgeDraft(journal)
            let defaults = UserDefaults(suiteName: "reflection-ui-\(UUID().uuidString)")!
            let writer: any ReflectionWriting = ProcessInfo.processInfo.arguments.contains("--ui-testing-save-success") ? UITestReflectionWriter() : GitHubReflectionWriter()
            let manager = ExternalBrainManager(rootURL: root.appendingPathComponent("cache"), defaults: defaults, reflectionWriter: writer)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-save-success") {
                manager.repository = .init(owner: "ui-test", repository: "isolated", branch: "main")
            }
            _store = StateObject(wrappedValue: ThoughtStore(repository: repository, summaryClient: MockReviewSummaryClient(text: "{\"overview\":\"生成された振り返り\",\"themes\":[\"今日の記録\"]}"), externalBrainManager: manager, userDefaults: defaults))
        } else if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let repository: MemoryThoughtRepository
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-reply-collapse") {
                let root = Thought(body: "折りたたみ元", createdAt: Date(timeIntervalSince1970: 1))
                repository = MemoryThoughtRepository(records: [root])
                if let firstReply = try? repository.createHumanReply(
                    body: "最初の返信",
                    targetThoughtID: root.id,
                    mentionedPersonaID: nil,
                    now: Date(timeIntervalSince1970: 2),
                    thoughtID: UUID(),
                    relationID: UUID()
                ) {
                    _ = try? repository.createHumanReply(
                        body: "2件目の返信",
                        targetThoughtID: firstReply.id,
                        mentionedPersonaID: nil,
                        now: Date(timeIntervalSince1970: 3),
                        thoughtID: UUID(),
                        relationID: UUID()
                    )
                }
            } else {
                repository = MemoryThoughtRepository()
            }
            let mio = Persona(displayName: "Mio", handle: "mio", kind: .ai)
            try? repository.createAIPersona(mio, configuration: .init(personaID: mio.id, role: "対話相手", instructions: "短く自然に返信する", autoReplyEnabled: true))
            _store = StateObject(wrappedValue: ThoughtStore(repository: repository, summaryClient: MockReviewSummaryClient(text: "一緒に考えてみましょう。")))
        } else {
            var restoreError: String?
            let fileManager = FileManager.default
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            let databaseURL = support.appendingPathComponent("ThoughtTimeline/thought-timeline.sqlite3")
            do {
                _ = try RestoreCoordinator.applyPendingRestoreIfNeeded(
                    databaseURL: databaseURL,
                    applicationSupportDirectory: support,
                    fileManager: fileManager
                )
            } catch {
                restoreError = "Restoreを適用できなかったため、元のデータを維持しました。\n\(error.localizedDescription)"
            }
            _store = StateObject(wrappedValue: ThoughtStore(
                summaryClient: ReviewSummaryClientFactory.makeProductionClient(),
                startupError: restoreError
            ))
        }
    }

    var body: some Scene {
        WindowGroup {
            ThemeHost(controller: themeController) {
                MainTabView(store: store)
            }
            .environmentObject(themeController)
        }
    }
}

/// Only injected into the isolated UI fixture. Never makes a network request.
private struct UITestReflectionWriter: ReflectionWriting {
    func save(path: String, markdown: String, expectedSHA: String?, configuration: ExternalBrainRepositoryConfiguration, token: String) async throws -> String {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return "ui-test-saved-sha"
    }
}
