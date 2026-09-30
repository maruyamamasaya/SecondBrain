import SwiftUI

enum JapaneseCalendarFormatting {
    static let locale = Locale(identifier: "ja_JP")
    static var calendar: Calendar { var value = Calendar.current; value.locale = locale; return value }
    static func month(_ date: Date) -> String { format(date, template: "yyyyMMMM") }
    static func day(_ date: Date) -> String { format(date, template: "MMMd") }
    static func longDay(_ date: Date) -> String { format(date, template: "yyyyMMMMdEEEE") }
    private static func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

struct DailySummarySections: View {
    let summary: DailySummary
    @ObservedObject var store: ThoughtStore
    var allowsTagChanges = true
    var body: some View {
        Section("概要") { Text(summary.content.overview) }
        valueSection("主なテーマ", summary.content.themes)
        if !summary.content.tagGroups.isEmpty {
            Section("タグ別（確定タグ）") { ForEach(summary.content.tagGroups, id: \.tagName) { group in VStack(alignment: .leading, spacing: 4) { Text("#\(group.tagName)").font(.headline); Text(group.summary); if !group.themes.isEmpty { Text(group.themes.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }; Text("\(group.thoughtCount)件").font(.caption2).foregroundStyle(.secondary) } } }
        }
        if !summary.content.aiInteractions.isEmpty {
            Section("AIとの対話（旧仕様の保存内容）") { ForEach(summary.content.aiInteractions, id: \.personaName) { interaction in VStack(alignment: .leading, spacing: 4) { Text(interaction.personaName).font(.headline); Text(interaction.summary); if !interaction.topics.isEmpty { Text(interaction.topics.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) } } } }
        }
        valueSection("思考パターン", summary.content.thoughtPatterns)
        valueSection("深掘りしていた内容", summary.content.deepDives)
        valueSection("悩み / 検討", summary.content.concerns)
        Section("思考の流れ") { Text(summary.content.thoughtFlow) }
        if !summary.content.timeOfDayInsights.isEmpty {
            Section("時間帯の傾向") { ForEach(summary.content.timeOfDayInsights, id: \.period) { value in VStack(alignment: .leading, spacing: 4) { Text(value.period).font(.headline); Text(value.insight) } } }
        }
        valueSection("継続候補", summary.content.continuationCandidates)
        valueSection("明日以降への持ち越し", summary.content.carryOvers)
        if !summary.content.existingTagCandidates.isEmpty || !summary.content.newTagCandidates.isEmpty {
            Section("AIタグ候補（1日）") { if !summary.content.existingTagCandidates.isEmpty { LabeledContent("確定タグからの候補", value: summary.content.existingTagCandidates.joined(separator: "、")) }; if !summary.content.newTagCandidates.isEmpty { LabeledContent("新規候補", value: summary.content.newTagCandidates.joined(separator: "、")) } }
        }
        if !summary.content.thoughtTagSuggestions.isEmpty {
            Section("AIタグ候補") {
                ForEach(Array(summary.content.thoughtTagSuggestions.enumerated()), id: \.offset) { _, suggestion in
                    if let thoughtID = suggestion.thoughtID, let thought = store.dailySummaryDayThoughts.first(where: { $0.id == thoughtID }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("#\(suggestion.tagName)").font(.headline)
                            Text(thought.body)
                            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                            if isAttached(suggestion.tagName, to: thoughtID) {
                                Text("追加済み").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            } else if allowsTagChanges {
                                Button("追加") { store.addTag(named: suggestion.tagName, to: thoughtID) }
                                    .buttonStyle(.bordered).accessibilityLabel("\(thought.body)に\(suggestion.tagName)タグを追加")
                            }
                        }
                    }
                }
            }
        }
        Section("生成情報") {
            LabeledContent("生成日時", value: summary.createdAt.formatted())
            LabeledContent("生成元", value: "\(summary.provider) / \(summary.model)")
            LabeledContent("対象", value: "\(summary.thoughtCount)件の思考メモ")
            LabeledContent("仕様", value: summary.promptVersion >= 3 ? "Human Thoughtのみ" : "旧仕様")
        }
    }

    @ViewBuilder private func valueSection(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty { Section(title) { ForEach(values, id: \.self) { Text($0) } } }
    }

    private func isAttached(_ name: String, to thoughtID: UUID) -> Bool {
        let normalized = ThoughtTag.normalize(name)
        return (store.tagsByThoughtID[thoughtID] ?? []).contains { $0.normalizedName == normalized }
    }
}

struct SummaryLibraryView: View {
    @ObservedObject var store: ThoughtStore

    var body: some View {
        Group {
            if store.dailySummaries.isEmpty && store.weeklySummaries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("まだサマリーはありません")
                        .font(.headline)
                    Text("作成したサマリーがここに新しい順で並びます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
            } else {
                List {
                    if !store.weeklySummaries.isEmpty {
                        Section("週間") {
                            ForEach(store.weeklySummaries) { summary in
                                NavigationLink { WeeklySummaryReadOnlyView(store: store, summary: summary) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack { Label("週間", systemImage: "calendar.badge.clock").font(.caption.weight(.semibold)).foregroundStyle(.tint); Spacer(); Text("\(summary.thoughtCount)件").font(.caption).foregroundStyle(.secondary) }
                                        Text(summary.weekStart.formatted(.dateTime.locale(Locale(identifier: "ja_JP")).year().month().day()) + "〜" + summary.weekEnd.addingTimeInterval(-1).formatted(.dateTime.locale(Locale(identifier: "ja_JP")).month().day())).font(.headline)
                                        Text(summary.content.overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    if !store.dailySummaries.isEmpty {
                        Section("デイリー") {
                            ForEach(store.dailySummaries) { summary in
                                NavigationLink { SummaryReadOnlyDetailView(store: store, summary: summary) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack { Label("デイリー", systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(.tint); Spacer(); Text("\(summary.thoughtCount)件").font(.caption).foregroundStyle(.secondary) }
                                        Text(JapaneseCalendarFormatting.longDay(summary.dayStart)).font(.headline)
                                        Text(summary.content.overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }.padding(.vertical, 4)
                                }.accessibilityIdentifier("summaryLibraryItem_\(summary.id.uuidString)")
                            }
                        }
                    }
                }
                .themedScrollableBackground()
            }
        }
        .themedScreen(.expressive)
        .navigationTitle("サマリー")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SummaryReadOnlyDetailView: View {
    @ObservedObject var store: ThoughtStore
    let summary: DailySummary
    @State private var reflectionDraft: KnowledgeDraft?

    var body: some View {
        List {
            Section {
                Label("デイリーサマリー", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if store.relatedReflectionCount(for: summary.dayStart) > 1 {
                Section { Label("この日を元にした記録が複数あります。", systemImage: "doc.on.doc").foregroundStyle(.orange) }
            }
            if let saved = store.savedReflection(for: summary.dayStart) { SavedReflectionSection(draft: saved) }
            else { DailySummarySections(summary: summary, store: store, allowsTagChanges: false) }
            Section { Button("編集・保存する") { reflectionDraft = store.reflectionDraft(for: summary) } }
        }
        .themedScrollableBackground()
        .themedScreen(.expressive)
        .navigationTitle(JapaneseCalendarFormatting.day(summary.dayStart))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.loadDailySummary(for: summary.dayStart); store.loadKnowledge() }
        .sheet(item: $reflectionDraft) { ReflectionEditorView(store: store, initialDraft: $0) }
    }
}

struct DailySummaryCalendarView: View {
    private enum GridCellID: Hashable {
        case weekday(Int)
        case leadingSpacer(Int)
        case day(Date)
    }

    private struct GridCell<Value>: Identifiable {
        let id: GridCellID
        let value: Value
    }

    @ObservedObject var store: ThoughtStore
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    private let calendar = JapaneseCalendarFormatting.calendar
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    Spacer()
                    Text(JapaneseCalendarFormatting.month(month)).font(.headline)
                    Spacer()
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                }
                .padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(weekdayCells) { cell in
                        Text(cell.value).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(dayCells) { cell in
                        if let day = cell.value {
                            NavigationLink {
                                DailySummaryDetailView(store: store, day: day)
                            } label: {
                                dayCell(day)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityText(day))
                        } else {
                            Color.clear.frame(height: 52)
                        }
                    }
                }
                .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 8) {
                    legend("checkmark.circle.fill", "要約済み", .green)
                    legend("circle.fill", "Thoughtあり / 未要約", .orange)
                    legend("circle", "Thoughtなし", .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
        }
        .navigationTitle("デイリーサマリー")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = calendar.firstWeekday - 1
        return Array(symbols[index...] + symbols[..<index])
    }

    private var weekdayCells: [GridCell<String>] {
        weekdaySymbols.enumerated().map { GridCell(id: .weekday($0.offset), value: $0.element) }
    }

    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return [] }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }.map(Optional.some)
    }

    private var dayCells: [GridCell<Date?>] {
        days.enumerated().map { index, day in
            GridCell(
                id: day.map { .day(calendar.startOfDay(for: $0)) } ?? .leadingSpacer(index),
                value: day
            )
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let status = status(for: day)
        return VStack(spacing: 5) {
            Text("\(calendar.component(.day, from: day))").font(.body.weight(calendar.isDateInToday(day) ? .bold : .regular))
            Image(systemName: status.icon).font(.caption).foregroundStyle(status.color)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(calendar.isDateInToday(day) ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay { if calendar.isDateInToday(day) { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1) } }
        .contentShape(Rectangle())
    }

    private func status(for day: Date) -> (icon: String, color: Color, text: String) {
        if store.dailySummaries.contains(where: { calendar.isDate($0.dayStart, inSameDayAs: day) }) { return ("checkmark.circle.fill", .green, "要約済み") }
        if store.thoughts.contains(where: { store.isHumanAuthored($0) && calendar.isDate($0.createdAt, inSameDayAs: day) }) { return ("circle.fill", .orange, "あなたのThoughtあり、未要約") }
        return ("circle", .secondary, "Thoughtなし")
    }

    private func accessibilityText(_ day: Date) -> String { "\(JapaneseCalendarFormatting.longDay(day))、\(status(for: day).text)" }
    private func moveMonth(_ value: Int) { if let next = calendar.date(byAdding: .month, value: value, to: month) { month = next } }
    private func legend(_ icon: String, _ text: String, _ color: Color) -> some View { Label(text, systemImage: icon).font(.subheadline).foregroundStyle(color) }
}

struct JournalCalendarView: View {
    private enum GridCellID: Hashable { case weekday(Int), leadingSpacer(Int), day(Date) }
    private struct GridCell<Value>: Identifiable { let id: GridCellID; let value: Value }

    @ObservedObject var store: ThoughtStore
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var entries: [ExternalBrainJournalEntry] = []
    @State private var isSyncing = false
    @State private var syncMessage: String?
    private let calendar = JapaneseCalendarFormatting.calendar
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    Spacer()
                    Text(JapaneseCalendarFormatting.month(month)).font(.headline)
                    Spacer()
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                }
                .padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(weekdayCells) { Text($0.value).font(.caption).foregroundStyle(.secondary) }
                    ForEach(dayCells) { cell in
                        if let day = cell.value {
                            NavigationLink { JournalDayDetailView(store: store, day: day) } label: { dayCell(day) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(JapaneseCalendarFormatting.longDay(day))、日記\(entries(for: day).count)件")
                        } else {
                            Color.clear.frame(height: 52)
                        }
                    }
                }
                .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Label("日記あり", systemImage: "book.closed.fill").foregroundStyle(.purple)
                    Label("日記なし", systemImage: "circle").foregroundStyle(.secondary)
                    if let syncMessage { Text(syncMessage).font(.footnote).foregroundStyle(.secondary) }
                    if !store.externalBrainManager.repository.isConfigured || !store.externalBrainManager.hasToken {
                        Text("GitHub設定とTokenを保存すると同期できます。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
        }
        .navigationTitle("日記")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await synchronize() } } label: {
                    if isSyncing { ProgressView() } else { Label("同期", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(isSyncing || !store.externalBrainManager.repository.isConfigured || !store.externalBrainManager.hasToken)
                .accessibilityIdentifier("journalSyncButton")
            }
        }
        .onAppear { store.loadKnowledge(); entries = store.journalEntries() }
        .onChange(of: store.knowledgeDrafts) { _ in entries = store.journalEntries() }
    }

    private var weekdayCells: [GridCell<String>] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = calendar.firstWeekday - 1
        return Array(symbols[index...] + symbols[..<index]).enumerated().map { GridCell(id: .weekday($0.offset), value: $0.element) }
    }
    private var dayCells: [GridCell<Date?>] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return [] }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let days = Array(repeating: Optional<Date>.none, count: leading) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }.map(Optional.some)
        return days.enumerated().map { GridCell(id: $0.element.map { .day(calendar.startOfDay(for: $0)) } ?? .leadingSpacer($0.offset), value: $0.element) }
    }
    private func entries(for day: Date) -> [ExternalBrainJournalEntry] {
        let value = KnowledgeDraftPath.dateString(day)
        return entries.filter { $0.date == value }
    }
    private func dayCell(_ day: Date) -> some View {
        let hasJournal = !entries(for: day).isEmpty
        return VStack(spacing: 5) {
            Text("\(calendar.component(.day, from: day))").font(.body.weight(calendar.isDateInToday(day) ? .bold : .regular))
            Image(systemName: hasJournal ? "book.closed.fill" : "circle").font(.caption).foregroundStyle(hasJournal ? .purple : .secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(calendar.isDateInToday(day) ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay { if calendar.isDateInToday(day) { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1) } }
        .contentShape(Rectangle())
    }
    private func moveMonth(_ value: Int) { if let next = calendar.date(byAdding: .month, value: value, to: month) { month = next } }
    private func synchronize() async {
        isSyncing = true; syncMessage = nil
        await store.externalBrainManager.synchronize()
        entries = store.journalEntries()
        syncMessage = store.externalBrainManager.message
        isSyncing = false
    }
}

private struct JournalDayDetailView: View {
    @ObservedObject var store: ThoughtStore
    let day: Date
    @State private var editingDraft: KnowledgeDraft?
    @State private var journalInput: KnowledgeDraftInput?
    private var entries: [ExternalBrainJournalEntry] { store.journalEntries().filter { $0.date == KnowledgeDraftPath.dateString(day) } }

    var body: some View {
        List {
            if entries.count > 1 {
                Section { Label("この日の日記が\(entries.count)件あります。", systemImage: "doc.on.doc") }
            }
            if !JournalDuplicateDetection.groups(entries).isEmpty {
                Section { Label("同じ本文の日記が複数あります。各記録の内容とGitHub情報を確認してください。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if entries.isEmpty {
                Section { Text("この日の日記はありません。").foregroundStyle(.secondary) }
            } else {
                ForEach(entries) { entry in
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(entry.title, systemImage: "book.closed.fill").font(.headline).foregroundStyle(.primary)
                                Spacer()
                                Text(statusLabel(entry.status)).font(.caption.weight(.semibold)).foregroundStyle(.purple)
                                    .padding(.horizontal, 9).padding(.vertical, 4).background(Color.purple.opacity(0.12), in: Capsule())
                            }
                            JournalMarkdownView(markdown: entry.body)
                            if let draft = store.editableJournal(entry) {
                                Button(draft.syncStatus == .synced ? "編集する" : "編集・保存する") { editingDraft = draft }
                            }

                            DisclosureGroup("GitHub情報") {
                                Text(entry.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle(JapaneseCalendarFormatting.day(day))
        .onAppear { store.loadKnowledge(); store.loadDailySummary(for: day) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("日記を作る") { journalInput = store.journalDraftInput(for: day) }
                    .disabled(store.dailySummaryDayThoughts.isEmpty)
                    .accessibilityIdentifier("createJournalFromCalendarButton")
            }
        }
        .sheet(isPresented: Binding(get: { journalInput != nil }, set: { if !$0 { journalInput = nil } })) {
            if let input = journalInput { KnowledgeDraftFlowView(store: store, input: input, initialType: .journal) }
        }
        .sheet(item: $editingDraft) { ReflectionEditorView(store: store, initialDraft: $0) }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusLabel(_ status: String) -> String {
        switch status.lowercased() { case "active": "保存済み"; case "draft": "下書き"; case "pending": "送信待ち"; default: status }
    }
}

struct JournalMarkdownView: View {
    let markdown: String
    private var lines: [String] { markdown.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            Text(inline(String(trimmed.dropFirst(4)))).font(.subheadline.weight(.semibold)).padding(.top, 3)
        } else if trimmed.hasPrefix("## ") {
            Text(inline(String(trimmed.dropFirst(3)))).font(.headline).padding(.top, 6)
        } else if trimmed.hasPrefix("# ") {
            Text(inline(String(trimmed.dropFirst(2)))).font(.title3.weight(.bold)).padding(.bottom, 2)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.purple); Text(inline(String(trimmed.dropFirst(2)))) }
        } else if let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text(String(trimmed[..<range.upperBound]).trimmingCharacters(in: .whitespaces)); Text(inline(String(trimmed[range.upperBound...]))) }
        } else if trimmed.hasPrefix("> ") {
            Text(inline(String(trimmed.dropFirst(2)))).italic().foregroundStyle(.secondary).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.purple.opacity(0.45)).frame(width: 3) }
        } else if trimmed == "---" {
            Divider()
        } else {
            Text(inline(trimmed)).font(.body).lineSpacing(4)
        }
    }

    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
}

struct DailySummaryDetailView: View {
    @ObservedObject var store: ThoughtStore
    let day: Date
    @State private var reflectionDraft: KnowledgeDraft?
    @State private var opensReflectionAfterGeneration = false
    @State private var summaryIDBeforeGeneration: UUID?
    @State private var draftInput: KnowledgeDraftInput?
    @State private var draftType: KnowledgeDraftType = .knowledge

    var body: some View {
        List {
            Section { Text("あなたのThoughtをもとに生成").font(.subheadline).foregroundStyle(.secondary) }
            Section {
                LabeledContent("あなたのThought", value: "\(store.dailySummaryDayThoughts.count)件")
                LabeledContent("あなたの継続Thought", value: "\(store.dailySummaryDayContinuationCount)件")
                LabeledContent("既存タグ", value: store.dailySummaryDayTags.isEmpty ? "なし" : store.dailySummaryDayTags.joined(separator: "、"))
            }
            if store.relatedReflectionCount(for: day) > 1 {
                Section { Label("この日を元にした記録が複数あります。既存の下書きも確認してください。", systemImage: "doc.on.doc").foregroundStyle(.orange) }
            }
            if let summary = store.dailySummary {
                if let saved = store.savedReflection(for: summary.dayStart) { SavedReflectionSection(draft: saved) }
                else { DailySummarySections(summary: summary, store: store) }
                Section("操作") {
                    Button("この日を再生成") { summaryIDBeforeGeneration = store.dailySummary?.id; opensReflectionAfterGeneration = true; store.prepareDailySummary(for: day) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(store.dailySummaryDayThoughts.isEmpty || store.isGeneratingDailySummary)
                        .accessibilityIdentifier("regenerateDailySummaryButton")
                    Text("送信前プレビューで内容を確認します。新しい生成が成功した場合だけ、現在のSummaryを置き換えます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("日記を作る") { openJournalDraft() }
                        .disabled(store.dailySummaryDayThoughts.isEmpty)
                        .accessibilityIdentifier("createJournalDraftButton")
                    Button("編集・保存する") { reflectionDraft = store.reflectionDraft(for: summary) }
                }
            } else {
                Section {
                    Button("この日をまとめる") { summaryIDBeforeGeneration = store.dailySummary?.id; opensReflectionAfterGeneration = true; store.prepareDailySummary(for: day) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(store.dailySummaryDayThoughts.isEmpty)
                        .accessibilityIdentifier("prepareDailySummaryButton")
                    Button("日記を作る") { openJournalDraft() }
                        .disabled(store.dailySummaryDayThoughts.isEmpty)
                        .accessibilityIdentifier("createJournalDraftButton")
                }
            }
            if let error = store.dailySummaryError { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(JapaneseCalendarFormatting.day(day))
        .navigationBarTitleDisplayMode(.inline)
        .operationFeedback(store, scope: .dailyReview, enabled: store.dailySummaryPreview == nil && reflectionDraft == nil && draftInput == nil)
        .onAppear { store.loadDailySummary(for: day); store.loadKnowledge() }
        .sheet(item: Binding(get: { store.dailySummaryPreview }, set: { if $0 == nil { store.cancelDailySummaryPreview() } }), onDismiss: {
            if opensReflectionAfterGeneration, let summary = store.dailySummary, summary.dayStart == Calendar.current.startOfDay(for: day), store.dailySummaryError == nil, summary.id != summaryIDBeforeGeneration {
                reflectionDraft = store.reflectionDraft(for: summary, reuseSaved: false)
            }
            opensReflectionAfterGeneration = false
        }) { preview in
            DailySummaryPreviewView(store: store, preview: preview)
        }
        .sheet(item: $reflectionDraft) { ReflectionEditorView(store: store, initialDraft: $0) }
        .sheet(isPresented: Binding(get: { draftInput != nil }, set: { if !$0 { draftInput = nil } })) { if let input = draftInput { KnowledgeDraftFlowView(store: store, input: input, initialType: draftType) } }
    }

    private func openJournalDraft() {
        draftType = .journal
        draftInput = store.journalDraftInput(for: day)
    }
}

private struct DailySummaryPreviewView: View {
    @ObservedObject var store: ThoughtStore
    let preview: DailySummaryPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.isGeneratingDailySummary {
                    Section { ProgressView("振り返りを生成しています…")
                        Text("完了すると確認・編集画面が開きます。").font(.footnote).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("dailySummaryGenerationProgress")
                }
                if let error = store.dailySummaryError { Section { Text(error).foregroundStyle(.red) } }
                Section("送信内容") {
                    Text("あなたのThoughtだけを送信します。AI Personaの本文は含みません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LabeledContent("対象", value: "\(preview.thoughts.count)件のHuman Thought")
                    LabeledContent("payload", value: "\(preview.request.prompt.count)文字")
                    LabeledContent("Continuation", value: "\(preview.continuationCount)件")
                }
                Section("対象Thought") { ForEach(preview.thoughts) { Text($0.body) } }
                Section("Human Thoughtとして送信") {
                    ForEach(preview.inputs, id: \.thought.id) { input in
                    HStack(alignment: .top, spacing: 10) { PersonaIcon(persona: input.author, size: 32); VStack(alignment: .leading, spacing: 3) { Text(input.author.displayName).font(.subheadline.weight(.semibold)); Text(input.author.kind == .human ? "人間" : "AI").font(.caption2).foregroundStyle(.secondary); if input.author.kind == .human, !input.tags.isEmpty { Text(input.tags.map { "#\($0.name)" }.joined(separator: " ")).font(.caption).foregroundStyle(.tint) }; Text(input.thought.body) } }
                    }
                }
                Section("最終payload") { Text(preview.request.prompt).font(.caption).textSelection(.enabled) }
            }
            .operationFeedback(store, scope: .dailyReview)
            .interactiveDismissDisabled(store.isGeneratingDailySummary)
            .navigationTitle("送信前プレビュー")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { store.cancelDailySummaryPreview(); dismiss() }.disabled(store.isGeneratingDailySummary) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.isGeneratingDailySummary ? "生成中…" : "送信") {
                        Task { await store.generateDailySummary(from: preview); if store.dailySummaryError == nil { dismiss() } }
                    }.disabled(store.isGeneratingDailySummary)
                }
            }
        }
    }
}
