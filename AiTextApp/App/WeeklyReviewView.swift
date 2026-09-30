import SwiftUI

struct WeeklyReviewListView: View {
    @ObservedObject var store: ThoughtStore
    private var calendar: Calendar { var value = Calendar.current; value.locale = Locale(identifier: "ja_JP"); value.firstWeekday = 2; return value }

    var body: some View {
        List {
            Section {
                Text("完了した月曜日〜日曜日のHuman Thoughtから、一週間の理解と次週プランを作ります。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("過去12週間") {
                ForEach(weeks, id: \.start) { interval in
                    NavigationLink {
                        WeeklyReviewDetailView(store: store, interval: interval, calendar: calendar)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(weekTitle(interval)).font(.headline)
                                Text(store.weeklySummaries.contains { $0.weekStart == interval.start } ? "週間サマリー作成済み" : "未作成")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.weeklySummaries.contains(where: { $0.weekStart == interval.start }) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                    }
                }
            }
        }
        .themedScrollableBackground().themedScreen(.expressive)
        .navigationTitle("週間振り返り").navigationBarTitleDisplayMode(.inline)
    }

    private var weeks: [DateInterval] {
        let latest = WeeklyReviewPeriod.completedWeek(before: Date(), calendar: calendar)
        return (0..<12).compactMap { offset in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: latest.start), let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
    private func weekTitle(_ interval: DateInterval) -> String { "\(shortDate(interval.start))〜\(shortDate(interval.end.addingTimeInterval(-1)))" }
    private func shortDate(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "ja_JP")).month().day()) }
}

struct WeeklyReviewDetailView: View {
    @ObservedObject var store: ThoughtStore
    let interval: DateInterval
    let calendar: Calendar
    @State private var showsSummaryPreview = false
    @State private var showsPlanEditor = false
    @State private var reflectionDraft: KnowledgeDraft?
    @State private var opensReflectionAfterGeneration = false
    @State private var summaryIDBeforeGeneration: UUID?

    var body: some View {
        List {
            Section("対象期間") { Text("\(day(interval.start))〜\(day(interval.end.addingTimeInterval(-1)))") }
            if store.relatedReflectionCount(for: interval.start, weekly: true) > 1 {
                Section { Label("同じ週の振り返り記録が複数あります。", systemImage: "doc.on.doc").foregroundStyle(.orange) }
            }
            if let summary = store.weeklySummary, summary.weekStart == interval.start {
                if let saved = store.savedReflection(for: summary.weekStart, weekly: true) { SavedReflectionSection(draft: saved) }
                else { WeeklySummarySections(summary: summary) }
                Section { Button("編集・保存する") { reflectionDraft = store.reflectionDraft(for: summary) } }
                Section {
                    Button("次週プランの候補を作る") { Task { await store.generateWeeklyPlanDraft(from: summary); if store.weeklyPlanDraft != nil { showsPlanEditor = true } } }
                        .disabled(store.isGeneratingWeeklyReview)
                    if let plan = store.weeklyPlan { WeeklyPlanSections(plan: plan) }
                } header: { Text("次の一週間") }
                Section { Button("この週を再生成") { prepareSummary() }.disabled(store.isGeneratingWeeklyReview) }
            } else {
                Section {
                    Text("この週の週間サマリーはまだありません。").foregroundStyle(.secondary)
                    Button("週間サマリーを作る") { prepareSummary() }.disabled(store.isGeneratingWeeklyReview)
                }
            }
            if store.isGeneratingWeeklyReview { Section { ProgressView("生成しています…") } }
            if let error = store.weeklyReviewError { Section { Text(error).foregroundStyle(.red) } }
        }
        .themedScrollableBackground().themedScreen(.expressive)
        .navigationTitle("週間振り返り").navigationBarTitleDisplayMode(.inline)
        .operationFeedback(store, scope: .weeklyReview, enabled: !showsSummaryPreview && !showsPlanEditor && reflectionDraft == nil)
        .onAppear { store.loadWeeklyReview(interval: interval); store.loadKnowledge() }
        .sheet(item: $reflectionDraft) { ReflectionEditorView(store: store, initialDraft: $0) }
        .sheet(isPresented: $showsSummaryPreview, onDismiss: {
            if opensReflectionAfterGeneration, let summary = store.weeklySummary, summary.weekStart == interval.start, store.weeklyReviewError == nil, summary.id != summaryIDBeforeGeneration { reflectionDraft = store.reflectionDraft(for: summary, reuseSaved: false) }
            opensReflectionAfterGeneration = false
        }) { if let preview = store.weeklySummaryPreview { WeeklySummaryPreviewSheet(store: store, preview: preview, calendar: calendar) } }
        .sheet(isPresented: $showsPlanEditor) { if let draft = store.weeklyPlanDraft { WeeklyPlanEditor(store: store, draft: draft) } }
    }
    private func prepareSummary() { summaryIDBeforeGeneration = store.weeklySummary?.id; opensReflectionAfterGeneration = true; store.prepareWeeklySummary(interval: interval, calendar: calendar); showsSummaryPreview = store.weeklySummaryPreview != nil }
    private func day(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "ja_JP")).year().month().day()) }
}

private struct WeeklySummarySections: View {
    let summary: WeeklySummary
    var body: some View {
        Section("一週間の概要") { Text(summary.content.overview) }
        values("主なテーマ", summary.content.themes)
        values("関心や考えの変化", summary.content.changes)
        values("繰り返し現れた話題", summary.content.recurringTopics)
        values("思考の発展", summary.content.thoughtDevelopments)
        values("印象的なThought", summary.content.notableThoughts)
        values("未解決の問い・気がかり", summary.content.unresolvedQuestions)
        Section("生成情報") { LabeledContent("対象", value: "\(summary.thoughtCount)件"); LabeledContent("生成元", value: "\(summary.provider) / \(summary.model)"); LabeledContent("生成日時", value: summary.createdAt.formatted()) }
    }
    @ViewBuilder private func values(_ title: String, _ values: [String]) -> some View { if !values.isEmpty { Section(title) { ForEach(values, id: \.self) { Text($0) } } } }
}

private struct WeeklyPlanSections: View {
    let plan: WeeklyPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.content.focus).font(.headline)
            ForEach(plan.content.actions, id: \.self) { Label($0, systemImage: "circle") }
            ForEach(plan.content.questions, id: \.self) { Label($0, systemImage: "questionmark.circle") }
            if !plan.content.note.isEmpty { Text(plan.content.note).foregroundStyle(.secondary) }
        }
    }
}

private struct WeeklySummaryPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ThoughtStore
    let preview: WeeklySummaryPreview
    let calendar: Calendar
    var body: some View {
        NavigationStack {
            List {
                if store.isGeneratingWeeklyReview {
                    Section { ProgressView("週間振り返りを生成しています…")
                        Text("完了すると確認・編集画面が開きます。").font(.footnote).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("weeklySummaryGenerationProgress")
                }
                Section("送信内容") { LabeledContent("Human Thought", value: "\(preview.thoughts.count)件"); LabeledContent("文字数", value: "\(preview.thoughts.reduce(0) { $0 + $1.body.count })文字"); LabeledContent("AI", value: "OpenAI / \(ReviewSummaryAIConfiguration.weeklyReviewModelName) / medium") }
                Section("対象Thought") { ForEach(preview.thoughts) { Text($0.body) } }
                if let error = store.weeklyReviewError { Section { Text(error).foregroundStyle(.red) } }
            }
            .operationFeedback(store, scope: .weeklyReview)
            .interactiveDismissDisabled(store.isGeneratingWeeklyReview)
            .navigationTitle("送信前の確認").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() }.disabled(store.isGeneratingWeeklyReview) }; ToolbarItem(placement: .confirmationAction) { Button("生成") { Task { await store.generateWeeklySummary(from: preview, calendar: calendar); if store.weeklySummaryPreview == nil { dismiss() } } }.disabled(store.isGeneratingWeeklyReview) } }
        }
    }
}

private struct WeeklyPlanEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ThoughtStore
    let draft: WeeklyPlanDraft
    @State private var focus: String
    @State private var actions: [String]
    @State private var questions: [String]
    @State private var note: String

    init(store: ThoughtStore, draft: WeeklyPlanDraft) {
        self.store = store; self.draft = draft
        _focus = State(initialValue: draft.content.focus); _actions = State(initialValue: draft.content.actions); _questions = State(initialValue: draft.content.questions); _note = State(initialValue: draft.content.note)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("今週の軸") { TextField("大切にしたいこと", text: $focus, axis: .vertical) }
                Section("小さな行動") { ForEach(actions.indices, id: \.self) { TextField("行動 \($0 + 1)", text: $actions[$0], axis: .vertical) } }
                Section("持ち越す問い") { ForEach(questions.indices, id: \.self) { TextField("問い \($0 + 1)", text: $questions[$0], axis: .vertical) } }
                Section("自由メモ") { TextField("任意", text: $note, axis: .vertical) }
            }
            .operationFeedback(store, scope: .weeklyReview)
            .navigationTitle("次週プランを確認").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("確定") { store.saveWeeklyPlan(draft: draft, content: .init(focus: focus, actions: actions.filter { !$0.isEmpty }, questions: questions.filter { !$0.isEmpty }, note: note)); if store.weeklyReviewError == nil { dismiss() } }.disabled(focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        }
    }
}

struct WeeklySummaryReadOnlyView: View {
    @ObservedObject var store: ThoughtStore
    let summary: WeeklySummary
    @State private var reflectionDraft: KnowledgeDraft?
    var body: some View {
        List {
            if store.relatedReflectionCount(for: summary.weekStart, weekly: true) > 1 {
                Section { Label("同じ週の振り返り記録が複数あります。", systemImage: "doc.on.doc").foregroundStyle(.orange) }
            }
            if let saved = store.savedReflection(for: summary.weekStart, weekly: true) { SavedReflectionSection(draft: saved) }
            else { WeeklySummarySections(summary: summary) }
            Section { Button("編集・保存する") { reflectionDraft = store.reflectionDraft(for: summary) } }
        }
        .themedScrollableBackground().themedScreen(.expressive)
        .navigationTitle("週間サマリー").navigationBarTitleDisplayMode(.inline)
        .onAppear { store.loadKnowledge() }
        .sheet(item: $reflectionDraft) { ReflectionEditorView(store: store, initialDraft: $0) }
    }
}
