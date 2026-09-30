import SwiftUI
import PhotosUI
import UIKit

struct MainTabView: View {
    @ObservedObject var store: ThoughtStore
    @Environment(\.appTheme) private var theme
    @State private var selection: Tab = .home
    @State private var navigationResetID = UUID()

    private enum Tab: Hashable { case home, mentions, ai, tools, profile }

    var body: some View {
        TabView(selection: $selection) {
            TimelineView(store: store)
                .id(navigationResetID)
                .tabItem { Label("ホーム", systemImage: "house") }
                .tag(Tab.home)
                .accessibilityIdentifier("homeTab")

            MentionsView(store: store)
                .id(navigationResetID)
                .tabItem { Label("メンション", systemImage: "at") }
                .tag(Tab.mentions)
                .accessibilityIdentifier("mentionsTab")

            AIFeaturesView(store: store)
                .id(navigationResetID)
                .tabItem { Label("AI機能", systemImage: "cpu") }
                .tag(Tab.ai)
                .accessibilityIdentifier("aiFeaturesTab")

            ToolsView(store: store)
                .id(navigationResetID)
                .tabItem { Label("ツール", systemImage: "square.grid.3x3") }
                .tag(Tab.tools)
                .accessibilityIdentifier("toolsTab")

            ProfileTabView(store: store)
                .id(navigationResetID)
                .tabItem { Label("プロフィール", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
                .accessibilityIdentifier("profileTab")
        }
        .tint(theme.colors.accent)
        .onChange(of: store.postNavigationRequest?.id) { _ in
            guard let request = store.postNavigationRequest else { return }
            let wasAlreadyOnHome = selection == .home
            selection = .home
            if request.resetsNavigation || !wasAlreadyOnHome {
                navigationResetID = UUID()
            }
        }
    }
}

struct TimelineView: View {
    @ObservedObject var store: ThoughtStore
    @Environment(\.appTheme) private var theme
    @State private var replyTarget: Thought?
    @State private var highlightedThoughtID: UUID?
    @State private var composerIsPresented = false
    @State private var selectedAuthorID: UUID?
    @State private var hidesLaterReplies = true
    @State private var searchQuery = ""

    private var visibleThoughts: [Thought] {
        if store.hasSearchQuery {
            return store.searchResults
        }
        let authorFiltered = selectedAuthorID.map { authorID in
            store.thoughts.filter { store.personasByThoughtID[$0.id]?.id == authorID }
        } ?? store.thoughts
        guard hidesLaterReplies else { return authorFiltered }
        return authorFiltered.filter { thought in
            thought.id == store.postNavigationRequest?.thoughtID || !isLaterReply(thought)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                    if visibleThoughts.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleThoughts) { thought in
                            let replyTarget = store.replyTargetsByThoughtID[thought.id]
                            ThoughtRow(
                                store: store,
                                thought: thought,
                                persona: store.personasByThoughtID[thought.id] ?? store.defaultHumanPersona,
                                mentionedPersona: store.mentionedPersonasByThoughtID[thought.id],
                                replyTarget: replyTarget,
                                replyTargetPersona: replyTarget.flatMap { store.personasByThoughtID[$0.id] },
                                tags: store.tagsByThoughtID[thought.id] ?? [],
                                onRequestReply: { self.replyTarget = thought },
                                onDelete: { store.requestDeletion(of: thought) }
                            )
                            .id(thought.id)
                            .background(highlightedThoughtID == thought.id ? theme.colors.accent.opacity(0.12) : Color.clear)
                            if let states = store.automaticRepliesByTargetID[thought.id] {
                                ForEach(Array(states.keys), id: \.self) { personaID in
                                    if let persona = store.personas.first(where: { $0.id == personaID }), let state = states[personaID] {
                                        HStack(spacing: 8) {
                                            PersonaIcon(persona: persona, size: 24)
                                            switch state {
                                            case .generating:
                                                ProgressView().controlSize(.small)
                                                Text("\(persona.displayName)が考えています…")
                                            case .failed:
                                                Text("返信を生成できませんでした").foregroundStyle(.red)
                                                Spacer()
                                                Button("再試行") { store.retryAutomaticReply(to: thought, personaID: personaID) }
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 58)
                                        .padding(.bottom, 8)
                                    }
                                }
                            }
                            if thought.id != visibleThoughts.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                        if !store.hasSearchQuery {
                            TimelineLoadMoreView(store: store)
                        }
                    }
                    }
                }
                .onChange(of: store.postNavigationRequest?.id) { _ in
                    guard let thoughtID = store.postNavigationRequest?.thoughtID else { return }
                    focusOnPostedThought(thoughtID, proxy: proxy)
                }
                .onAppear {
                    guard let thoughtID = store.postNavigationRequest?.thoughtID else { return }
                    DispatchQueue.main.async { focusOnPostedThought(thoughtID, proxy: proxy) }
                }
            }
            .themedScreen(.calm)
            .scrollDismissesKeyboard(.interactively)
            .animation(.easeOut(duration: 0.2), value: store.thoughts.map(\.id))
            .navigationTitle("思考メモ")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Thought本文を検索"
            )
            .onChange(of: searchQuery) { store.search($0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        InsightsContentView(store: store)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("振り返り")
                    .accessibilityHint("サマリー、日記、分析を開きます")
                    .accessibilityIdentifier("homeInsightsButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        hidesLaterReplies.toggle()
                    } label: {
                        Image(systemName: hidesLaterReplies ? "bubble.left" : "bubble.left.and.bubble.right")
                    }
                    .accessibilityLabel(hidesLaterReplies ? "返信をすべて表示" : "2件目以降の返信を隠す")
                    .accessibilityValue(hidesLaterReplies ? "1件だけ表示" : "すべて表示")
                    .accessibilityIdentifier("homeReplyVisibilityButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            selectedAuthorID = nil
                        } label: {
                            Label("すべてのユーザー", systemImage: selectedAuthorID == nil ? "checkmark" : "person.2")
                        }
                        ForEach(store.personas) { persona in
                            Button {
                                selectedAuthorID = persona.id
                            } label: {
                                Label(persona.displayName, systemImage: selectedAuthorID == persona.id ? "checkmark" : "person.crop.circle")
                            }
                            .accessibilityIdentifier("homeAuthorFilter_\(persona.id.uuidString)")
                        }
                    } label: {
                        Image(systemName: selectedAuthorID == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("投稿者でフィルター")
                    .accessibilityValue(selectedAuthorName ?? "すべてのユーザー")
                    .accessibilityIdentifier("homeAuthorFilterButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composerIsPresented = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新しいThoughtを投稿")
                    .accessibilityHint("投稿画面を開きます")
                    .accessibilityIdentifier("openComposerButton")
                }
            }
            .navigationDestination(for: UUID.self) { thoughtID in
                ThoughtDetailView(store: store, initialThoughtID: thoughtID)
            }
            .navigationDestination(for: TagRoute.self) { route in
                TaggedThoughtListView(store: store, tag: route.tag)
            }
            .sheet(item: $store.exportArtifact) { artifact in
                ShareSheet(url: artifact.url, onFailure: store.sharingFailed)
            }
            .sheet(item: $replyTarget) { thought in AIReplyRequestView(store: store, thought: thought) }
            .sheet(isPresented: $composerIsPresented) {
                NewThoughtComposerView(store: store)
            }
            .confirmationDialog(
                "このThoughtを削除しますか？",
                isPresented: deletionDialogIsPresented,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) { store.confirmDeletion() }
                    .accessibilityIdentifier("confirmDeleteButton")
                Button("キャンセル", role: .cancel) { store.cancelDeletion() }
                    .accessibilityIdentifier("cancelDeleteButton")
            } message: {
                Text("削除したThoughtはタイムラインに表示されなくなります。")
            }
            .alert("エラー", isPresented: errorIsPresented) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    private func focusOnPostedThought(_ thoughtID: UUID, proxy: ScrollViewProxy) {
        guard let request = store.postNavigationRequest, request.thoughtID == thoughtID else { return }
        highlightedThoughtID = thoughtID
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(thoughtID, anchor: .center) }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard highlightedThoughtID == thoughtID else { return }
            withAnimation(.easeOut(duration: 0.3)) { highlightedThoughtID = nil }
            store.acknowledgePostNavigationRequest(id: request.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.hasSearchQuery ? "text.magnifyingglass" : "square.and.pencil")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(emptyStateTitle)
                .font(.headline)
            Text(emptyStateDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(store.hasSearchQuery ? "thoughtSearchEmptyState" : "timelineEmptyState")
    }

    private var emptyStateTitle: String {
        if store.hasSearchQuery { return "一致するThoughtはありません" }
        return selectedAuthorID == nil ? "まだThoughtはありません" : "このユーザーのThoughtはありません"
    }

    private var emptyStateDetail: String {
        store.hasSearchQuery
            ? "別のキーワードを試してください。"
            : "右上の鉛筆から\n140文字以内で残してみましょう。"
    }

    private var selectedAuthorName: String? {
        guard let selectedAuthorID else { return nil }
        return store.personas.first(where: { $0.id == selectedAuthorID })?.displayName
    }

    private var deletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { store.deletionCandidate != nil },
            set: { if !$0 { store.cancelDeletion() } }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private func isLaterReply(_ thought: Thought) -> Bool {
        guard let replyTargetID = store.replyTargetIDsByThoughtID[thought.id] else { return false }
        return store.replyTargetIDsByThoughtID[replyTargetID] != nil
    }
}

private struct NewThoughtComposerView: View {
    @ObservedObject var store: ThoughtStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                composer
                    .padding(.vertical, 16)
            }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("新しいThought")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("投稿") {
                            if store.post() { dismiss() }
                        }
                        .disabled(!store.canPost)
                        .accessibilityLabel("Thoughtを投稿")
                        .accessibilityHint("入力したThoughtを投稿します")
                        .accessibilityIdentifier("postButton")
                    }
                }
        }
        .onAppear { composerIsFocused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PersonaIcon(persona: store.defaultHumanPersona, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.defaultHumanPersona.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text("Thoughtを投稿")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if store.draft.isEmpty {
                        Text("今なに考えてる？")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    TextEditor(text: Binding(get: { store.draft }, set: store.updateDraft))
                        .focused($composerIsFocused)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 1)
                        .padding(.vertical, 4)
                        .frame(minHeight: 132)
                        .accessibilityLabel("Thoughtを入力")
                        .accessibilityHint("140文字以内で入力します")
                        .accessibilityIdentifier("thoughtComposer")
                }

                Divider()

                HStack(spacing: 12) {
                    mentionMenu
                    Spacer()
                    characterCount
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            if !store.mentionSuggestions.isEmpty {
                mentionSuggestionList
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.16), value: store.mentionSuggestions.map(\.id))
    }

    private var mentionMenu: some View {
        Menu {
            ForEach(store.personas) { persona in
                Button("\(persona.displayName)  @\(persona.handle)") { store.insertMention(persona) }
            }
            if store.selectedMentionPersona != nil {
                Button("メンションを外す", role: .destructive) { store.removeSelectedMention() }
            }
        } label: {
            Label("メンション", systemImage: "at")
                .font(.subheadline.weight(.semibold))
        }
        .disabled(store.personas.allSatisfy { $0.kind != .ai })
        .accessibilityLabel(store.selectedMentionPersona.map { "\($0.displayName)をメンション中" } ?? "AI Personaをメンション")
        .accessibilityIdentifier("mentionPersonaMenu")
    }

    private var mentionSuggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("メンション候補")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.mentionSuggestions) { persona in
                        Button { store.insertMention(persona) } label: {
                            HStack(spacing: 10) {
                                PersonaIcon(persona: persona, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(persona.displayName)
                                            .font(.subheadline.weight(.medium))
                                        ExternalBrainBadge(store: store, persona: persona)
                                    }
                                    Text("@\(persona.handle)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(persona.kind == .human ? "人間" : "AI")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                            .frame(height: 52)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mentionSuggestion_\(persona.handle)")
                    }
                }
            }
            .frame(height: CGFloat(min(store.mentionSuggestions.count, 3)) * 52)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .accessibilityIdentifier("mentionSuggestionList")
    }

    private var characterCount: some View {
        Text("\(store.draft.count) / \(ThoughtDraft.characterLimit)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(store.draft.count >= 130 ? Color.orange : Color.secondary)
            .accessibilityLabel("文字数 \(store.draft.count)、上限 \(ThoughtDraft.characterLimit)")
    }

}

private struct SettingsView: View {
    @ObservedObject var store: ThoughtStore
    @EnvironmentObject private var themeController: ThemeController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("外観") {
                    NavigationLink {
                        AppearanceThemeView(controller: themeController)
                    } label: {
                        LabeledContent {
                            Text(themeController.selection.name).foregroundStyle(.secondary)
                        } label: {
                            Label("外観とテーマ", systemImage: "circle.lefthalf.filled")
                        }
                    }
                    .accessibilityIdentifier("appearanceThemeButton")
                }

                Section("データ") {
                    Button { store.export(.markdown) } label: {
                        Label("Markdownを共有", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("exportMarkdownButton")

                    Button { store.export(.json) } label: {
                        Label("JSONを共有", systemImage: "curlybraces")
                    }
                    .accessibilityIdentifier("exportJSONButton")

                    if let manager = store.externalBackupManager {
                        NavigationLink {
                            BackupManagementView(manager: manager)
                        } label: {
                            Label("バックアップ", systemImage: "externaldrive.badge.timemachine")
                        }
                        .accessibilityIdentifier("backupManagementButton")
                    }
                }
            }
            .themedScrollableBackground()
            .themedScreen(.expressive)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .sheet(item: $store.exportArtifact) { artifact in
                ShareSheet(url: artifact.url, onFailure: store.sharingFailed)
            }
        }
    }
}

private struct AIFeaturesView: View {
    @ObservedObject var store: ThoughtStore

    var body: some View {
        NavigationStack {
            Form {
                Section("AI接続") {
                    NavigationLink {
                        AIProviderSettingsView(store: store)
                    } label: {
                        Label("AIプロバイダー設定", systemImage: "network")
                    }
                    .accessibilityIdentifier("aiProviderSettingsButton")

                    Text("Gemini、OpenAIなど、AIサービスごとに接続設定と利用状態を確認できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("AIペルソナ") {
                    NavigationLink {
                        AIPostRequestView(store: store)
                    } label: {
                        Label("AIに投稿を依頼", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("aiPostRequestPageButton")

                    NavigationLink {
                        AIPersonaManagementView(store: store)
                    } label: {
                        Label("AIペルソナの設定", systemImage: "person.2.badge.gearshape")
                    }
                    .accessibilityIdentifier("aiPersonasButton")
                }

                Section("利用状況") {
                    NavigationLink {
                        AIAPIUsageAnalyticsView(store: store)
                    } label: {
                        Label("AI使用状況", systemImage: "waveform.path.ecg")
                    }
                    .accessibilityIdentifier("aiUsageAnalyticsButton")
                }

                Section("外部ブレイン") {
                    NavigationLink { ExternalBrainSettingsView(store: store) } label: {
                        HStack {
                            Label("外部ブレイン設定", systemImage: "brain.head.profile")
                            Spacer()
                            Text(externalBrainStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("externalBrainSettingsButton")

                    NavigationLink { KnowledgeManagementView(store: store) } label: {
                        Label("ナレッジ下書き", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("knowledgeManagementButton")
                }

                Section("生成設定") {
                    LabeledContent("Daily Summary") {
                        Text("OpenAI · \(ReviewSummaryAIConfiguration.openAIModelName) · medium")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("週間サマリー") {
                        Text("OpenAI · \(ReviewSummaryAIConfiguration.weeklyReviewModelName) · medium")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("次週プラン") {
                        Text("OpenAI · \(ReviewSummaryAIConfiguration.weeklyReviewModelName) · low")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Knowledge DraftのAI Provider", selection: $store.knowledgeDraftAIProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .accessibilityIdentifier("knowledgeDraftAIProviderPicker")
                    Text("Knowledge Draft: \(store.knowledgeDraftAIProvider.defaultModel) · medium。AIペルソナの投稿・手動返信・自動返信はPersonaごとにProviderを選択でき、どちらもlowで生成します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "AI返信の確認クッション",
                        isOn: Binding(
                            get: { store.aiReplyPreviewPreference == .alwaysShow },
                            set: { store.aiReplyPreviewPreference = $0 ? .alwaysShow : .skip }
                        )
                    )
                    .accessibilityIdentifier("aiReplyPreviewPreference")
                    Text("OFFではAI返信を生成後そのまま投稿します。ONでは手動で返信を依頼したとき、生成内容を確認してから投稿できます。@メンションによる自動返信には確認を挟みません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .themedScrollableBackground()
            .themedScreen(.expressive)
            .navigationTitle("AI機能")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var externalBrainStatus: String {
        guard store.externalBrainManager.repository.isConfigured else { return "未設定" }
        guard let capabilities = store.externalBrainManager.connectionCapabilities else { return "設定済み" }
        return capabilities.issue == nil ? "接続済み" : "設定済み"
    }
}

private struct AIProviderSettingsView: View {
    @ObservedObject var store: ThoughtStore

    private var hasGeminiConfiguration: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }

    var body: some View {
        Form {
            Section("プロバイダー") {
                NavigationLink {
                    GeminiProviderSettingsView(isConfigured: hasGeminiConfiguration)
                } label: {
                    AIProviderSettingsRow(
                        name: "Gemini",
                        detail: hasGeminiConfiguration ? "設定済み" : "未設定",
                        state: hasGeminiConfiguration ? .configured : .notConfigured
                    )
                }
                .accessibilityIdentifier("geminiProviderSettingsButton")

                NavigationLink {
                    OpenAIProviderSettingsView(store: store)
                } label: {
                    AIProviderSettingsRow(
                        name: "OpenAI",
                        detail: store.hasOpenAIAPIKey ? "設定済み" : "未設定",
                        state: store.hasOpenAIAPIKey ? .configured : .notConfigured
                    )
                }
                .accessibilityIdentifier("openAIProviderSettingsButton")

                NavigationLink {
                    ClaudeProviderSettingsView()
                } label: {
                    AIProviderSettingsRow(name: "Claude", detail: "未対応", state: .unavailable)
                }
                .accessibilityIdentifier("claudeProviderSettingsButton")
            }

            Section {
                Text("緑のランプは、この端末で必要な設定を検出できたことを示します。実際のAPI接続を確認した表示ではありません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .themedScrollableBackground()
        .themedScreen(.expressive)
        .navigationTitle("AIプロバイダー設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AIProviderSettingsRow: View {
    enum State {
        case configured
        case notConfigured
        case unavailable

        var color: Color {
            switch self {
            case .configured: .green
            case .notConfigured: .orange
            case .unavailable: .secondary
            }
        }
    }

    let name: String
    let detail: String
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(name)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)、\(detail)")
    }
}

private struct GeminiProviderSettingsView: View {
    let isConfigured: Bool

    var body: some View {
        Form {
            Section("状態") {
                AIProviderSettingsRow(
                    name: "Gemini",
                    detail: isConfigured ? "設定済み" : "未設定",
                    state: isConfigured ? .configured : .notConfigured
                )
                LabeledContent("接続方式", value: "Firebase AI Logic")
                LabeledContent("Model", value: ReviewSummaryAIConfiguration.geminiModelName)
            }

            Section("設定方法") {
                Text(isConfigured
                    ? "GoogleService-Info.plistを検出しました。APIの疎通とApp Checkの有効性は、実際の生成時に確認されます。"
                    : "XcodeプロジェクトのルートへGoogleService-Info.plistを配置すると、ビルド時にアプリへ取り込まれます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .themedScrollableBackground()
        .themedScreen(.expressive)
        .navigationTitle("Gemini")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OpenAIProviderSettingsView: View {
    @ObservedObject var store: ThoughtStore
    @State private var apiKey = ""
    @State private var confirmsRemoval = false

    var body: some View {
        Form {
            Section("状態") {
                AIProviderSettingsRow(
                    name: "OpenAI",
                    detail: store.hasOpenAIAPIKey ? "設定済み" : "未設定",
                    state: store.hasOpenAIAPIKey ? .configured : .notConfigured
                )
                LabeledContent("接続方式", value: "OpenAI Responses API")
                LabeledContent("Model", value: ReviewSummaryAIConfiguration.openAIModelName)
            }

            Section("API key") {
                SecureField("新しいOpenAI API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .accessibilityIdentifier("openAIAPIKeyField")
                Button(store.hasOpenAIAPIKey ? "API keyを置き換える" : "API keyを保存") {
                    if store.saveOpenAIAPIKey(apiKey) { apiKey = "" }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveOpenAIAPIKeyButton")
                if store.hasOpenAIAPIKey {
                    Button("API keyを削除", role: .destructive) {
                        confirmsRemoval = true
                    }
                }
                if let message = store.openAIAPIKeyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("自分の端末だけで使う暫定構成です。キーはこの端末限定のKeychainへ保存されます。緑のランプはキーの保存状態を示し、APIの疎通確認ではありません。配布用アプリでは安全なバックエンドへ移行してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .themedScrollableBackground()
        .themedScreen(.expressive)
        .navigationTitle("OpenAI")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("OpenAI API keyを削除しますか？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("削除", role: .destructive) { store.removeOpenAIAPIKey() }
            Button("キャンセル", role: .cancel) {}
        }
    }
}

private struct ClaudeProviderSettingsView: View {
    var body: some View {
        Form {
            Section("状態") {
                AIProviderSettingsRow(name: "Claude", detail: "未対応", state: .unavailable)
            }

            Section {
                Text("Claude APIは現在の生成経路へまだ接続されていません。API keyを保存しても利用できないため、設定欄は有効にしていません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .themedScrollableBackground()
        .themedScreen(.expressive)
        .navigationTitle("Claude")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MentionsView: View {
    @ObservedObject var store: ThoughtStore
    @State private var selection: InboxKind = .mentions
    @State private var replyTarget: Thought?

    private enum InboxKind: String, CaseIterable, Identifiable {
        case mentions = "メンション"
        case replies = "リプライ"

        var id: Self { self }
    }

    private var items: [Thought] {
        store.incomingMentionAndReplyThoughts().filter { thought in
            let isReply = store.replyTargetIDsByThoughtID[thought.id] != nil
            return selection == .replies ? isReply : !isReply
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("表示する通知", selection: $selection) {
                    ForEach(InboxKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("mentionsKindPicker")

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if items.isEmpty {
                            emptyState
                        } else {
                            ForEach(items) { thought in
                                let replyTarget = store.replyTargetsByThoughtID[thought.id]
                                ThoughtRow(
                                    store: store,
                                    thought: thought,
                                    persona: store.personasByThoughtID[thought.id] ?? store.defaultHumanPersona,
                                    mentionedPersona: store.mentionedPersonasByThoughtID[thought.id],
                                    replyTarget: replyTarget,
                                    replyTargetPersona: replyTarget.flatMap { store.personasByThoughtID[$0.id] },
                                    tags: store.tagsByThoughtID[thought.id] ?? [],
                                    onRequestReply: { self.replyTarget = thought },
                                    onDelete: { store.requestDeletion(of: thought) }
                                )
                                .accessibilityIdentifier("mentionItem_\(thought.id.uuidString)")
                                if thought.id != items.last?.id {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        TimelineLoadMoreView(store: store)
                    }
                }
            }
            .themedScreen(.calm)
            .navigationTitle("メンション")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { thoughtID in
                ThoughtDetailView(store: store, initialThoughtID: thoughtID)
            }
            .sheet(item: $replyTarget) { thought in
                AIReplyRequestView(store: store, thought: thought)
            }
            .confirmationDialog(
                "このThoughtを削除しますか？",
                isPresented: deletionDialogIsPresented,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) { store.confirmDeletion() }
                Button("キャンセル", role: .cancel) { store.cancelDeletion() }
            } message: {
                Text("削除したThoughtはタイムラインに表示されなくなります。")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: selection == .mentions ? "at" : "arrowshape.turn.up.left")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(selection == .mentions ? "メンションはありません" : "リプライはありません")
                .font(.headline)
            Text(selection == .mentions
                 ? "自分またはAI Persona宛てのメンションがここに表示されます。"
                 : "Thoughtへのリプライがここに表示されます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("mentionsEmptyState")
    }

    private var deletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { store.deletionCandidate != nil },
            set: { if !$0 { store.cancelDeletion() } }
        )
    }
}

private struct TimelineLoadMoreView: View {
    @ObservedObject var store: ThoughtStore

    var body: some View {
        Group {
            if let message = store.timelinePaginationError {
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("再読み込み") { store.loadMoreTimelineThoughts() }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 16)
            } else if store.hasMoreTimelineThoughts {
                ProgressView("過去のThoughtを読み込み中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
                    .onAppear { store.loadMoreTimelineThoughts() }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("timelineLoadMore")
    }
}

private struct InsightsContentView: View {
    @ObservedObject var store: ThoughtStore

    var body: some View {
        List {
            Section("サマリー") {
                NavigationLink {
                    SummaryLibraryView(store: store)
                } label: {
                    Label("サマリーを見る", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("insightsSummaryLibraryButton")
            }
            Section("日記") {
                NavigationLink {
                    JournalCalendarView(store: store)
                } label: {
                    Label("日記を見る", systemImage: "book.closed")
                }
                .accessibilityIdentifier("insightsJournalButton")
            }
            Section("作成") {
                NavigationLink {
                    WeeklyReviewListView(store: store)
                } label: {
                    Label("週間振り返り", systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("insightsWeeklyReviewButton")
                NavigationLink {
                    DailySummaryCalendarView(store: store)
                } label: {
                    Label("デイリーサマリー", systemImage: "calendar.badge.checkmark")
                }
                .accessibilityIdentifier("insightsDailySummaryButton")
            }
            Section("分析") {
                NavigationLink {
                    ThoughtAnalyticsView(store: store)
                } label: {
                    Label("思考メモの分析", systemImage: "chart.line.uptrend.xyaxis")
                }
                .accessibilityIdentifier("insightsAnalyticsButton")
            }
        }
        .themedScrollableBackground()
        .themedScreen(.expressive)
        .navigationTitle("振り返り")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolsView: View {
    @ObservedObject var store: ThoughtStore
    @Environment(\.openURL) private var openURL
    @State private var launchError: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.secondBrainApps) { app in
                        tile(for: app)
                    }
                }
                .padding(16)
            }
            .themedScreen(.expressive)
            .navigationTitle("ツール")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if store.secondBrainApps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.grid.3x3")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("ツールはありません")
                            .font(.headline)
                        Text("利用できるApp / Toolが追加されると、ここに表示されます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                }
            }
            .alert("ツールを開けません", isPresented: launchErrorIsPresented) {
                Button("OK") { launchError = nil }
            } message: {
                Text(launchError ?? "")
            }
        }
    }

    @ViewBuilder
    private func tile(for app: SecondBrainApp) -> some View {
        switch app.launchTarget {
        case .nativeFeature(let feature):
            NavigationLink {
                nativeDestination(feature)
            } label: {
                ToolTile(app: app)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolTile_\(app.id.uuidString)")
        case .webURL(let value), .localURL(let value), .deepLink(let value):
            Button {
                launch(value, appName: app.name)
            } label: {
                ToolTile(app: app)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolTile_\(app.id.uuidString)")
        }
    }

    @ViewBuilder
    private func nativeDestination(_ feature: SecondBrainNativeFeature) -> some View {
        switch feature {
        case .ai:
            AIFeaturesView(store: store)
        case .knowledge:
            KnowledgeManagementView(store: store)
        case .insights:
            InsightsContentView(store: store)
        }
    }

    private func launch(_ value: String, appName: String) {
        guard let url = URL(string: value) else {
            launchError = "\(appName)の起動先URLが不正です。"
            return
        }
        openURL(url) { accepted in
            if !accepted {
                launchError = "\(appName)を開けませんでした。"
            }
        }
    }

    private var launchErrorIsPresented: Binding<Bool> {
        Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )
    }
}

private struct ToolTile: View {
    let app: SecondBrainApp

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: app.icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(app.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.name)
        .accessibilityHint(app.description.isEmpty ? "開きます" : app.description)
    }
}

private struct ProfileTabView: View {
    @ObservedObject var store: ThoughtStore

    var body: some View {
        NavigationStack {
            ActorProfileView(store: store, persona: store.defaultHumanPersona, allowsEditing: true)
                .themedScreen(.expressive)
        }
    }
}

private struct BackupManagementView: View {
    enum PickerPurpose: Identifiable { case destination, restore; var id: Int { self == .destination ? 0 : 1 } }
    @ObservedObject var manager: ExternalBackupManager
    @State private var pickerPurpose: PickerPurpose?

    var body: some View {
        Form {
            Section("保存先") {
                LabeledContent("フォルダ", value: manager.destinationName ?? "未選択")
                LabeledContent("状態", value: manager.destinationAvailable ? "利用可能" : "利用できません")
                Button("バックアップ保存先を選択") { pickerPurpose = .destination }
                    .accessibilityIdentifier("selectBackupDestinationButton")
            }
            Section {
                LabeledContent("最終バックアップ") {
                    Text(manager.lastBackupAt?.formatted(date: .numeric, time: .shortened) ?? "未作成")
                }
                Button("今すぐバックアップ") { manager.createBackup() }
                    .disabled(!manager.destinationAvailable)
                    .accessibilityIdentifier("createExternalBackupButton")
            } header: {
                Text("外部完全バックアップ")
            } footer: {
                Text("SQLite全体をFilesまたはiCloud Driveへ保存します。アプリ内の2世代バックアップやMarkdown／JSON Exportとは別の、削除・再インストール時の復旧用です。")
            }
            Section {
                Button("バックアップから復元", role: .destructive) { pickerPurpose = .restore }
                    .accessibilityIdentifier("restoreExternalBackupButton")
            } header: {
                Text("復元")
            } footer: {
                Text("選択後に内容を検証し、確認画面を表示します。現在のデータは次回起動時まで置き換えません。")
            }
        }
        .navigationTitle("バックアップ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.refreshDestinationStatus() }
        .sheet(item: $pickerPurpose) { purpose in
            FolderPicker { url in
                pickerPurpose = nil
                if purpose == .destination { manager.selectDestination(url) }
                else { manager.prepareRestoreSelection(url) }
            } onCancel: { pickerPurpose = nil }
        }
        .alert("バックアップから復元", isPresented: restoreConfirmationIsPresented) {
            Button("キャンセル", role: .cancel) { manager.cancelRestore() }
            Button("復元する", role: .destructive) { manager.confirmRestore() }
        } message: {
            Text("このバックアップで現在のAiTextデータを置き換えます。\n\nバックアップ日時: \(manager.restoreCandidate?.manifest.createdAt.formatted(date: .numeric, time: .shortened) ?? "不明")\n\n適用は次回アプリ起動時です。")
        }
        .alert("バックアップ", isPresented: messageIsPresented) {
            Button("OK") { manager.message = nil }
        } message: { Text(manager.message ?? "") }
    }

    private var restoreConfirmationIsPresented: Binding<Bool> {
        Binding(get: { manager.restoreCandidate != nil }, set: { if !$0 { manager.cancelRestore() } })
    }
    private var messageIsPresented: Binding<Bool> {
        Binding(get: { manager.message != nil }, set: { if !$0 { manager.message = nil } })
    }
}

private struct TagRoute: Hashable {
    let tag: ThoughtTag
}

private struct TagStrip: View {
    let tags: [ThoughtTag]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(tags.prefix(2))) { tag in
                    NavigationLink(value: TagRoute(tag: tag)) {
                        Label(tag.name, systemImage: "tag.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("タグ \(tag.name)")
                    .accessibilityHint("このタグのThought一覧を開きます")
                    .accessibilityIdentifier("thoughtTag_\(tag.id.uuidString)")
                }
                if tags.count > 2 {
                    Text("+\(tags.count - 2)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("他\(tags.count - 2)個のタグ")
                }
            }
        }
    }

}

private struct ThoughtTagListView: View {
    @ObservedObject var store: ThoughtStore

    var body: some View {
        Group {
            if store.allTags.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag").font(.title2).foregroundStyle(.secondary)
                    Text("タグはありません").font(.headline)
                    Text("Thought Detailからタグを追加できます。").font(.subheadline).foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    .accessibilityIdentifier("thoughtTagListEmptyState")
            } else {
                List(store.allTags) { tag in
                    NavigationLink(value: TagRoute(tag: tag)) {
                        Label(tag.name, systemImage: "tag")
                    }
                    .accessibilityIdentifier("tagListItem_\(tag.id.uuidString)")
                }
            }
        }
        .navigationTitle("タグ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.loadAllTags() }
    }
}

private struct TaggedThoughtListView: View {
    @ObservedObject var store: ThoughtStore
    let tag: ThoughtTag

    var body: some View {
        Group {
            if store.taggedThoughts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag").font(.title2).foregroundStyle(.secondary)
                    Text("Thoughtはありません").font(.headline)
                    Text("削除されていないThoughtはありません。").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.taggedThoughts) { thought in
                            VStack(alignment: .leading, spacing: 8) {
                                NavigationLink(value: thought.id) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(thought.body)
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .multilineTextAlignment(.leading)
                                        Text(ThoughtDateText.string(for: thought.createdAt))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("taggedThought_\(thought.id.uuidString)")
                                TagStrip(tags: store.tagsByThoughtID[thought.id] ?? [])
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            if thought.id != store.taggedThoughts.last?.id { Divider().padding(.leading, 16) }
                        }
                    }
                }
            }
        }
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.loadThoughts(taggedWith: tag) }
    }
}

private struct ThoughtTagEditorView: View {
    @ObservedObject var store: ThoughtStore
    let thought: Thought
    @State private var newTagName = ""
    @Environment(\.dismiss) private var dismiss

    private var currentTags: [ThoughtTag] { store.tagsByThoughtID[thought.id] ?? [] }
    private var availableTags: [ThoughtTag] {
        let currentIDs = Set(currentTags.map(\.id))
        return store.allTags.filter { !currentIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("現在のタグ") {
                    if currentTags.isEmpty { Text("タグなし").foregroundStyle(.secondary) }
                    ForEach(currentTags) { tag in
                        HStack {
                            Label(tag.name, systemImage: "tag")
                            Spacer()
                            Button("削除", role: .destructive) { store.removeTag(tag, from: thought.id) }
                                .accessibilityIdentifier("removeThoughtTag_\(tag.id.uuidString)")
                        }
                    }
                }
                if !availableTags.isEmpty {
                    Section("既存タグを追加") {
                        ForEach(availableTags) { tag in
                            Button { store.addTag(named: tag.name, to: thought.id) } label: {
                                Label(tag.name, systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("attachExistingTag_\(tag.id.uuidString)")
                        }
                    }
                }
                Section("新しいタグ") {
                    TextField("タグ名", text: $newTagName)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .accessibilityIdentifier("newThoughtTagField")
                        .onSubmit(addNewTag)
                    Button("タグを追加", action: addNewTag)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .disabled(ThoughtTag.displayName(from: newTagName) == nil)
                        .accessibilityIdentifier("addThoughtTagButton")
                }
                if let message = store.tagMessage {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("タグを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }.accessibilityIdentifier("closeThoughtTagEditor")
                }
            }
            .onAppear {
                store.refreshTags(for: [thought.id])
                store.loadAllTags()
                store.tagMessage = nil
            }
        }
    }

    private func addNewTag() {
        guard let displayName = ThoughtTag.displayName(from: newTagName) else { return }
        store.addTag(named: displayName, to: thought.id)
        if store.tagMessage == nil { newTagName = "" }
    }
}

private struct ThoughtDetailView: View {
    @ObservedObject var store: ThoughtStore
    let initialThoughtID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var currentThoughtID: UUID
    @State private var showsComposer = false
    @State private var showsTagEditor = false
    @State private var showsAIReply = false
    @State private var showsHumanReplyComposer = false
    @State private var branchReplyTarget: Thought?
    @State private var knowledgeDraftInput: KnowledgeDraftInput?
    @FocusState private var composerIsFocused: Bool

    init(store: ThoughtStore, initialThoughtID: UUID) {
        self.store = store
        self.initialThoughtID = initialThoughtID
        _currentThoughtID = State(initialValue: initialThoughtID)
    }

    private var currentThought: Thought? {
        store.history.first { $0.id == currentThoughtID }?.thought
    }

    private var normalReplyTarget: Thought? { store.conversationThread?.lastThought ?? currentThought }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let currentThought {
                    VStack(alignment: .leading, spacing: 10) {
                        let actor = store.personasByThoughtID[currentThought.id] ?? store.defaultHumanPersona
                        NavigationLink {
                            ActorProfileView(store: store, persona: actor)
                        } label: {
                            HStack(spacing: 10) {
                                PersonaIcon(persona: actor, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(actor.displayName).font(.subheadline.weight(.semibold))
                                    Text("@\(actor.handle)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("detailActorProfileLink")
                        Text(currentThought.deletedAt == nil ? currentThought.body : "削除されたThought")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(currentThought.deletedAt == nil ? Color.primary : Color.secondary)
                        Text(ThoughtDateText.string(for: currentThought.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TagStrip(tags: store.tagsByThoughtID[currentThought.id] ?? [])
                        Button("返信を書く") {
                            branchReplyTarget = nil
                            if let target = normalReplyTarget, let author = store.personasByThoughtID[target.id], author.kind == .ai { store.updateHumanReplyDraft("@\(author.handle) ") }
                            showsHumanReplyComposer.toggle()
                            showsComposer = false
                            if showsHumanReplyComposer { composerIsFocused = true }
                        }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("writeReplyButton")
                        if store.conversationThread?.edges.isEmpty != false,
                           (store.personasByThoughtID[currentThought.id]?.kind ?? .human) == .human {
                            Button("続きを書く") {
                                showsComposer.toggle(); showsHumanReplyComposer = false
                                if showsComposer { composerIsFocused = true }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("writeContinuationButton")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)

                    if showsComposer { continuationComposer(parent: currentThought) }
                    if showsHumanReplyComposer, let target = branchReplyTarget ?? normalReplyTarget { humanReplyComposer(target: target) }
                }

                Divider()
                Text("会話")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                ForEach(Array(store.history.enumerated()), id: \.element.id) { index, entry in
                    historyRow(entry)
                    if index < store.history.count - 1 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 1, height: 18)
                            .padding(.leading, 24 + CGFloat(entry.depth) * 14)
                    }
                }
            }
        }
        .navigationTitle("Thought")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let currentThought {
                    Menu {
                        Button {
                            UIPasteboard.general.string = currentThought.body
                        } label: {
                            Label("本文をコピー", systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("copyCurrentThoughtBodyButton")
                        Button("タグを編集") { showsTagEditor = true }
                        if let input = store.knowledgeDraftInput(for: currentThought) { Button("Knowledge Draftへ移す") { knowledgeDraftInput = input } }
                        Button("この投稿から返信を分岐") {
                            branchReplyTarget = currentThought
                            if let author = store.personasByThoughtID[currentThought.id], author.kind == .ai { store.updateHumanReplyDraft("@\(author.handle) ") }
                            showsHumanReplyComposer = true; showsComposer = false; composerIsFocused = true
                        }
                        Divider()
                        Button("削除", role: .destructive) { store.requestDeletion(of: currentThought) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("投稿のその他の操作")
                }
            }
        }
        .onAppear { store.loadHistory(for: currentThoughtID); store.loadAIReplies(to: currentThoughtID) }
        .onChange(of: currentThoughtID) { store.loadAIReplies(to: $0) }
        .sheet(isPresented: Binding(get: { knowledgeDraftInput != nil }, set: { if !$0 { knowledgeDraftInput = nil } })) { if let input = knowledgeDraftInput { KnowledgeDraftFlowView(store: store, input: input) } }
        .sheet(isPresented: $showsTagEditor) {
            if let currentThought {
                ThoughtTagEditorView(store: store, thought: currentThought)
            }
        }
        .sheet(isPresented: $showsAIReply) {
            if let currentThought {
                AIReplyRequestView(store: store, thought: currentThought) {
                    dismiss()
                }
            }
        }
    }

    private func continuationComposer(parent: Thought) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("続きを書く")
                .font(.headline)
            TextEditor(text: Binding(get: { store.continuationDraft }, set: store.updateContinuationDraft))
                .focused($composerIsFocused)
                .frame(minHeight: 96, maxHeight: 140)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("\(parent.deletedAt == nil ? parent.body : "削除されたThought")の続きを入力")
                .accessibilityHint("140文字以内で入力します")
                .accessibilityIdentifier("continuationComposer")
            HStack {
                Text("\(store.continuationDraft.count) / \(ThoughtDraft.characterLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(store.continuationDraft.count >= 130 ? Color.orange : Color.secondary)
                Spacer()
                Button("投稿") {
                    if let created = store.postContinuation(parentThoughtID: parent.id) {
                        currentThoughtID = created.id
                        showsComposer = false
                        composerIsFocused = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(!store.canPostContinuation)
                .accessibilityLabel("続きを投稿")
                .accessibilityIdentifier("postContinuationButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func historyRow(_ entry: ThoughtHistoryEntry) -> some View {
        let node = store.conversationThread?.nodes.first { $0.id == entry.id }
        let actor = store.personasByThoughtID[entry.id] ?? store.defaultHumanPersona
        return HStack(alignment: .center, spacing: 0) {
            Button {
                currentThoughtID = entry.id
                showsComposer = false
                store.loadHistory(for: entry.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(entry.id == currentThoughtID ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            PersonaIcon(persona: actor, size: 24)
                            Text(actor.displayName).font(.caption.weight(.semibold))
                            if let relation = node?.incomingRelation {
                                Text(relation.type == .repliesTo ? "返信" : "続き")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(relation.type == .repliesTo ? Color.accentColor : Color.secondary)
                            } else { Text("Root").font(.caption2).foregroundStyle(.secondary) }
                            if node?.hasBranches == true { Label("分岐", systemImage: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary) }
                        }
                        HStack {
                            Text(entry.thought.deletedAt == nil ? entry.thought.body : "削除されたThought")
                                .font(entry.id == currentThoughtID ? .body.weight(.semibold) : .body)
                                .foregroundStyle(entry.thought.deletedAt == nil ? Color.primary : Color.secondary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if entry.id == currentThoughtID {
                                Text("現在")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text(ThoughtDateText.string(for: entry.thought.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let states = store.automaticRepliesByTargetID[entry.id] {
                            ForEach(Array(states.keys), id: \.self) { personaID in
                                if let persona = store.personas.first(where: { $0.id == personaID }), let state = states[personaID] {
                                    switch state {
                                    case .generating:
                                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("\(persona.displayName)が考えています…") }.font(.caption).foregroundStyle(.secondary)
                                    case .failed:
                                        HStack { Text("返信を生成できませんでした").font(.caption).foregroundStyle(.red); Button("再試行") { store.retryAutomaticReply(to: entry.thought, personaID: personaID) }.font(.caption) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 16 + CGFloat(entry.depth) * 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("History Thought、\(entry.thought.deletedAt == nil ? entry.thought.body : "削除されたThought")\(entry.id == currentThoughtID ? "、現在" : "")")
            .accessibilityHint("ダブルタップしてこのThoughtを現在位置にします")
            .accessibilityIdentifier("historyThought_\(entry.id.uuidString)")

            if entry.thought.deletedAt == nil {
                Menu {
                    Button {
                        UIPasteboard.general.string = entry.thought.body
                    } label: {
                        Label("本文をコピー", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("copyHistoryThoughtBodyButton_\(entry.id.uuidString)")
                    Button("削除", role: .destructive) { store.requestDeletion(of: entry.thought) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("History Thoughtの操作")
                .accessibilityIdentifier("historyThoughtMenu_\(entry.id.uuidString)")
            }
        }
        .padding(.trailing, 8)
        .background(entry.id == currentThoughtID ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func humanReplyComposer(target: Thought) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("返信を書く").font(.headline)
            TextEditor(text: Binding(get: { store.humanReplyDraft }, set: store.updateHumanReplyDraft))
                .focused($composerIsFocused)
                .frame(minHeight: 80)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("humanReplyComposer")
            HStack {
                Text("\(store.humanReplyDraft.count) / \(ThoughtDraft.characterLimit)")
                    .font(.caption.monospacedDigit())
                Spacer()
                Button("返信") {
                    if let reply = store.postHumanReply(to: target) {
                        showsHumanReplyComposer = false
                        composerIsFocused = false
                        if store.aiReplyPreview?.targetThought.id == reply.id {
                            currentThoughtID = reply.id
                            if let preview = store.aiReplyPreview {
                                if store.aiReplyPreviewPreference == .skip {
                                    Task {
                                        if await store.generateAndPublishAIReply(from: preview) == false {
                                            showsAIReply = true
                                        }
                                    }
                                } else {
                                    showsAIReply = true
                                    Task { await store.generateAIReply(from: preview) }
                                }
                            }
                        } else {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canPostHumanReply)
                .accessibilityIdentifier("postHumanReplyButton")
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }
}

private struct ThoughtRow: View {
    @ObservedObject var store: ThoughtStore
    let thought: Thought
    let persona: Persona
    let mentionedPersona: Persona?
    let replyTarget: Thought?
    let replyTargetPersona: Persona?
    let tags: [ThoughtTag]
    let onRequestReply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink { ActorProfileView(store: store, persona: persona) } label: {
                PersonaIcon(persona: persona, size: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(persona.displayName)のプロフィールを開く")
            .accessibilityIdentifier("actorIcon_\(thought.id.uuidString)")
            VStack(alignment: .leading, spacing: replyTarget == nil ? 8 : 4) {
                HStack(spacing: 6) {
                    NavigationLink { ActorProfileView(store: store, persona: persona) } label: {
                        Text(persona.displayName).font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    ExternalBrainBadge(store: store, persona: persona)
                    NavigationLink { ActorProfileView(store: store, persona: persona) } label: {
                        Text("@\(persona.handle)").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("actorHandle_\(thought.id.uuidString)")
                    if persona.kind == .ai {
                        Text("AI").font(.caption2.weight(.bold)).foregroundStyle(.tint)
                    }
                }
                if let replyTarget {
                    HStack(spacing: 4) {
                        if let replyTargetPersona {
                            NavigationLink { ActorProfileView(store: store, persona: replyTargetPersona) } label: {
                                Text("↩ @\(replyTargetPersona.handle)")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("↩ 返信")
                                .fontWeight(.semibold)
                        }
                        Text("·")
                        Text(replyTarget.deletedAt == nil ? replyTarget.body : "削除されたThought")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("replyContext_\(thought.id.uuidString)")
                }
                NavigationLink(value: thought.id) {
                    VStack(alignment: .leading, spacing: replyTarget == nil ? 8 : 4) {
                    Text(thought.body)
                        .font(.body)
                        .lineSpacing(replyTarget == nil ? 4 : 2)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("thoughtBody_\(thought.id.uuidString)")
                    Text(ThoughtDateText.string(for: thought.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(timelineAccessibilityLabel)
                .accessibilityHint("ダブルタップして詳細とHistoryを開きます")
                .accessibilityIdentifier("timelineThought_\(thought.id.uuidString)")
                TagStrip(tags: tags)
                if let mentionedPersona {
                    NavigationLink {
                        ActorProfileView(store: store, persona: mentionedPersona)
                    } label: {
                        Text("@\(mentionedPersona.handle)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mentionedPersona.displayName)のプロフィールを開く")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    UIPasteboard.general.string = thought.body
                } label: {
                    Label("本文をコピー", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("copyThoughtBodyButton_\(thought.id.uuidString)")
                Button("削除", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Thoughtの操作")
            .accessibilityHint("本文のコピーまたは削除メニューを表示します")
            .accessibilityIdentifier("thoughtMenu")
        }
        .themeSurface(isAI: persona.kind == .ai)
        .padding(.horizontal, 12)
        .padding(.vertical, replyTarget == nil ? 6 : 2)
        .accessibilityElement(children: .contain)
        .contentShape(Rectangle())
    }

    private var timelineAccessibilityLabel: String {
        guard let replyTarget else { return "Thought、\(thought.body)" }
        let targetBody = replyTarget.deletedAt == nil ? replyTarget.body : "削除されたThought"
        return "\(replyTargetPersona?.displayName ?? "不明")への返信、返信先、\(targetBody)、本文、\(thought.body)"
    }
}

private struct ExternalBrainSettingsView: View {
    @ObservedObject var store: ThoughtStore
    @ObservedObject var manager: ExternalBrainManager
    @State private var owner = ""
    @State private var repository = ""
    @State private var branch = "main"
    @State private var token = ""
    @State private var showsToken = false
    @State private var confirmsRepositoryChange = false
    @State private var confirmsTokenRemoval = false
    init(store: ThoughtStore) { self.store = store; self.manager = store.externalBrainManager }
    private var editedConfiguration: ExternalBrainRepositoryConfiguration {
        .init(owner: owner.trimmingCharacters(in: .whitespacesAndNewlines), repository: repository.trimmingCharacters(in: .whitespacesAndNewlines), branch: branch.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var hasLocalKnowledge: Bool { !store.knowledgeDrafts.isEmpty || !store.knowledgeDocuments.isEmpty }

    var body: some View {
        Form {
            Section("GitHubリポジトリ") {
                TextField("Owner", text: $owner).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Repository", text: $repository).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Branch", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Repository設定を保存") {
                    if hasLocalKnowledge && editedConfiguration != manager.repository { confirmsRepositoryChange = true }
                    else { manager.repository = editedConfiguration }
                }
            }
            Section("パーソナルアクセストークン") {
                HStack {
                    Group {
                        if showsToken { TextField("新しいGitHub token", text: $token) }
                        else { SecureField(manager.hasToken ? "••••••••••••••" : "GitHub fine-grained token", text: $token) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(showsToken ? "隠す" : "表示") { showsToken.toggle() }.buttonStyle(.borderless)
                }
                LabeledContent("状態", value: manager.hasToken ? "Keychainに設定済み" : "未設定")
                Button("Tokenを保存") { if manager.saveToken(token) { token = ""; showsToken = false } }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if manager.hasToken { Button("トークンを削除", role: .destructive) { confirmsTokenRemoval = true } }
            }
            Section("GitHub接続") {
                Button(manager.isTestingConnection ? "確認中…" : "接続を確認") { Task { await manager.testConnection() } }.disabled(manager.isTestingConnection)
                capability("Authentication", manager.connectionCapabilities?.authentication)
                capability("Repository Read", manager.connectionCapabilities?.repositoryRead)
                capability("Branch \(manager.repository.branch)", manager.connectionCapabilities?.branchRead)
                capability("Write Drafts", manager.connectionCapabilities?.writeDrafts)
                capability("Write Knowledge", manager.connectionCapabilities?.writeKnowledge)
                if let issue = manager.connectionCapabilities?.issue { Text(issue.localizedDescription).font(.footnote).foregroundStyle(.red) }
                if let remaining = manager.connectionCapabilities?.rateLimitRemaining { LabeledContent("レート制限の残り", value: "\(remaining)") }
                Text("接続確認はRepository・Branch・権限情報の読取りだけを行い、ファイルを書き込みません。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("保存先") {
                LabeledContent("下書きのパス", value: manager.draftDirectory)
                LabeledContent("ナレッジのパス", value: manager.knowledgeDirectory)
            }
            Section("同期") {
                if let date = manager.manifest.syncedAt { LabeledContent("最終同期", value: date.formatted(date: .abbreviated, time: .shortened)) }
                else { LabeledContent("最終同期", value: "未同期") }
                LabeledContent("キャッシュ", value: ByteCountFormatter.string(fromByteCount: manager.cacheByteCount, countStyle: .file))
                Button(manager.isSyncing ? "同期中…" : "今すぐ同期") { Task { await manager.synchronize() } }.disabled(manager.isSyncing)
                if let message = manager.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("機能") {
                LabeledContent("GitHub", value: manager.repository.isConfigured ? (manager.connectionCapabilities?.issue == nil && manager.connectionCapabilities != nil ? "接続済み" : "設定済み") : "未設定")
                LabeledContent("リポジトリ", value: manager.repositoryDisplayName)
                LabeledContent("ブランチ", value: manager.repository.branch)
                LabeledContent("下書き", value: manager.canWriteDrafts ? "書き込み可" : "設定または権限が必要")
                LabeledContent("ナレッジ", value: manager.canWriteKnowledge ? "書き込み可" : "設定または権限が必要")
            }
            Section { Text("TokenはKeychainへ保存され、SQLite・Markdown・Usage・ログには含まれません。Write DraftsにはGitHub Contentsのwrite権限が必要です。書き込み失敗はRead機能へ影響しません。").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("外部ブレイン")
        .onAppear { owner = manager.repository.owner; repository = manager.repository.repository; branch = manager.repository.branch; store.loadKnowledge() }
        .confirmationDialog("GitHub Repositoryを変更しますか？", isPresented: $confirmsRepositoryChange, titleVisibility: .visible) {
            Button("変更する") { manager.repository = editedConfiguration }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("既存のローカルKnowledgeとDraftは削除されません。今後のGitHub同期・保存先が変更されます。") }
        .confirmationDialog("GitHub tokenを削除しますか？", isPresented: $confirmsTokenRemoval, titleVisibility: .visible) {
            Button("削除", role: .destructive) { manager.removeToken() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    @ViewBuilder private func capability(_ title: String, _ value: Bool?) -> some View {
        LabeledContent(title, value: value.map { $0 ? "✓" : "×" } ?? "未確認")
    }
}

struct KnowledgeDraftFlowView: View {
    @ObservedObject var store: ThoughtStore
    let input: KnowledgeDraftInput
    @State private var type: KnowledgeDraftType
    @Environment(\.dismiss) private var dismiss
    init(store: ThoughtStore, input: KnowledgeDraftInput, initialType: KnowledgeDraftType = .knowledge) {
        self.store = store; self.input = input; _type = State(initialValue: initialType)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("生成元") { LabeledContent("種類", value: input.source.displayName); Text(input.sourceContent).lineLimit(8) }
                Section("下書きの種類") { Picker("種類", selection: $type) { ForEach(KnowledgeDraftType.allCases, id: \.self) { Text($0.displayName).tag($0) } }; Text(type.guidance).font(.footnote).foregroundStyle(.secondary) }
                Section { Text("生成を押すまでAI通信は行いません。生成後のPreview確認とGitHub保存は別操作です。").font(.footnote).foregroundStyle(.secondary) }
                if let error = store.knowledgeDraftError { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("ナレッジ下書き")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(store.isGeneratingKnowledgeDraft ? "生成中…" : "下書きを生成") { Task { await store.generateKnowledgeDraft(input: input, type: type) } }.disabled(store.isGeneratingKnowledgeDraft) }
            }
            .sheet(item: Binding(get: { store.knowledgeDraft }, set: { if $0 == nil { store.cancelKnowledgeDraft() } })) { KnowledgeDraftPreviewView(store: store, draft: $0) }
        }
    }
}

private struct KnowledgeDraftPreviewView: View {
    @ObservedObject var store: ThoughtStore
    @State private var draft: KnowledgeDraft
    @State private var showsGitHubSettings = false
    @Environment(\.dismiss) private var dismiss
    init(store: ThoughtStore, draft: KnowledgeDraft) { self.store = store; _draft = State(initialValue: draft) }
    var body: some View {
        NavigationStack {
            Form {
                Section("下書き") {
                    TextField("Title", text: $draft.title)
                    Picker("種類", selection: $draft.type) { ForEach(KnowledgeDraftType.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    TextField("Project", text: $draft.project)
                    TextField("Tags（カンマ区切り）", text: Binding(get: { draft.tags.joined(separator: ", ") }, set: { draft.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }))
                    LabeledContent("生成元", value: draft.source.displayName)
                    LabeledContent("保存予定path", value: draft.targetPath)
                }
                Section("Markdown本文") { TextEditor(text: $draft.body).frame(minHeight: 260).font(.system(.caption, design: .monospaced)) }
                Section("Markdown全文") { Text(draft.markdown).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Section("関連する既存資料") {
                    if draft.relatedDocuments.isEmpty { Text("なし").foregroundStyle(.secondary) }
                    ForEach(Array(draft.relatedDocuments.enumerated()), id: \.offset) { item in VStack(alignment: .leading) { Text(item.element.documentPath).font(.subheadline.weight(.semibold)); Text(item.element.heading).font(.caption).foregroundStyle(.secondary) } }
                }
                if let message = store.knowledgeDraftMessage { Section { Text(message).foregroundStyle(.green) } }
                if let error = store.knowledgeDraftError { Section { Text(error).foregroundStyle(.red) } }
                if !store.externalBrainManager.canWriteDrafts {
                    Section("GitHub") {
                        Text("GitHubが設定されていません。").foregroundStyle(.secondary)
                        Button("GitHub設定を開く") { showsGitHubSettings = true }
                    }
                }
                if draft.savedPath == nil { Section { Text("保存の承認はGitHub drafts/への新規作成までです。確定知識への昇格ではありません。").font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle("下書きのプレビュー")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(store.isSavingKnowledgeDraft ? "保存中…" : "GitHubへ保存") { Task { await store.saveKnowledgeDraft(draft); if let saved = store.knowledgeDraft { draft = saved } } }.disabled(store.isSavingKnowledgeDraft || draft.savedPath != nil || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .sheet(isPresented: $showsGitHubSettings) { NavigationStack { ExternalBrainSettingsView(store: store) } }
        }
    }
}

private struct KnowledgeManagementView: View {
    @ObservedObject var store: ThoughtStore
    @State private var filter: KnowledgeDraftReviewStatus?
    @State private var query = ""
    private var drafts: [KnowledgeDraft] { store.knowledgeDrafts.filter { filter == nil || $0.reviewStatus == filter } }
    var body: some View {
        List {
            Section { NavigationLink { KnowledgeQualityView(store:store) } label: { Label("品質チェック",systemImage:"checkmark.seal") } }
            Section("レビュー集計") { ForEach([KnowledgeLifecycleEventType.approved,.rejected,.promoted],id:\.rawValue) { type in LabeledContent(type.rawValue,value:"\(store.knowledgeLifecycleEvents.filter { $0.type == type }.count)") } }
            Section {
                Picker("状態", selection:$filter) { Text("すべて").tag(Optional<KnowledgeDraftReviewStatus>.none); ForEach(KnowledgeDraftReviewStatus.allCases,id:\.self) { Text($0.displayName).tag(Optional($0)) } }
                TextField("Draftを検索",text:$query).textInputAutocapitalization(.never).onSubmit { store.loadKnowledge(search:query) }
                if !query.isEmpty { Button("検索をクリア") { query=""; store.loadKnowledge() } }
            }
            Section("Drafts") { if drafts.isEmpty { Text("Draftはありません").foregroundStyle(.secondary) }; ForEach(drafts) { draft in NavigationLink { KnowledgeDraftReviewView(store:store,draftID:draft.id) } label: { VStack(alignment:.leading,spacing:4) { Text(draft.title).font(.headline); Text("\(draft.type.displayName) · \(draft.source.displayName)").font(.caption); Text("\(draft.reviewStatus.rawValue) · \(draft.syncStatus.rawValue)").font(.caption2).foregroundStyle(.secondary); Text("作成 \(draft.createdAt.formatted())").font(.caption2).foregroundStyle(.secondary); Text("更新 \(draft.updatedAt.formatted())").font(.caption2).foregroundStyle(.secondary) } } } }
            Section("Knowledge") { if store.knowledgeDocuments.isEmpty { Text("正式Knowledgeはありません").foregroundStyle(.secondary) }; ForEach(store.knowledgeDocuments) { document in NavigationLink { KnowledgeDocumentDetailView(store:store,documentID:document.id) } label: { VStack(alignment:.leading) { Text(document.title); Text("\(document.status.rawValue) · \(document.path)").font(.caption).foregroundStyle(.secondary) } } } }
        }.navigationTitle("ナレッジ").onAppear { store.loadKnowledge() }
    }
}

private struct KnowledgeDocumentDetailView: View {
    @ObservedObject var store:ThoughtStore; let documentID:UUID
    private var document:KnowledgeDocument? { store.knowledgeDocuments.first{$0.id==documentID} }
    var body: some View { List { if let document { Section("Metadata") { LabeledContent("Source",value:document.source.displayName); LabeledContent("Status",value:document.status.rawValue); LabeledContent("Path",value:document.path); LabeledContent("Tags",value:document.tags.joined(separator:", ")); LabeledContent("Updated",value:document.updatedAt.formatted()); LabeledContent("Used by AI",value:"\(document.retrievalCount) times"); LabeledContent("Last used",value:document.lastRetrievedAt?.formatted() ?? "未使用"); if let id=document.supersededByKnowledgeID { LabeledContent("Superseded by",value:id.uuidString) } }; Section("Markdown") { Text(document.markdown).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }; if document.status == .active { Section { Button("Archive",role:.destructive) { store.archiveKnowledge(document) } } } } }.navigationTitle(document?.title ?? "Knowledge").onAppear { store.loadKnowledge() } }
}

private struct KnowledgeQualityView: View {
    @ObservedObject var store:ThoughtStore
    var body: some View { List {
        Section { Button("ナレッジを解析") { store.analyzeKnowledgeQuality() }; Text("ローカル解析のみ。ナレッジ本文・状態を自動変更せず、AI APIも呼びません。").font(.footnote).foregroundStyle(.secondary) }
        candidateSection("重複候補",type:.duplicate)
        candidateSection("類似ナレッジ",type:.similar)
        candidateSection("古いナレッジ候補",type:.stale)
        Section("Recently Used") { ForEach(store.knowledgeDocuments.filter{$0.lastRetrievedAt != nil}.sorted{$0.lastRetrievedAt! > $1.lastRetrievedAt!}.prefix(10)) { document in NavigationLink { KnowledgeDocumentDetailView(store:store,documentID:document.id) } label: { VStack(alignment:.leading) { Text(document.title); Text("\(document.retrievalCount) uses · \(document.lastRetrievedAt?.formatted() ?? "")").font(.caption).foregroundStyle(.secondary) } } } }
        if let message=store.knowledgeDraftMessage { Section { Text(message).foregroundStyle(.secondary) } }
    }.navigationTitle("ナレッジの品質").onAppear { store.loadKnowledge() } }
    @ViewBuilder private func candidateSection(_ title:String,type:KnowledgeQualityCandidateType)->some View { Section(title) { let values=store.knowledgeQualityCandidates.filter{$0.type==type && $0.status == .open}; if values.isEmpty { Text("候補なし").foregroundStyle(.secondary) }; ForEach(values) { candidate in VStack(alignment:.leading,spacing:8) { if let first=store.knowledgeDocuments.first(where:{$0.id==candidate.knowledgeID}) { Text(first.title).font(.headline); Text("\(first.source.displayName) · \(first.updatedAt.formatted())").font(.caption) }; if let relatedID=candidate.relatedKnowledgeID,let second=store.knowledgeDocuments.first(where:{$0.id==relatedID}) { Text("↔ \(second.title)").font(.subheadline); Text("\(second.source.displayName) · \(second.updatedAt.formatted())").font(.caption); Text(candidate.score >= 0.75 ? "High similarity" : "Medium similarity").font(.caption.weight(.semibold)); NavigationLink("Compare") { KnowledgeCompareView(store:store,candidate:candidate) }; Button("Create Merge Draft") { store.createMergeDraft(candidate) } }; Text(candidate.reason).font(.caption).foregroundStyle(.secondary); Button("Dismiss") { store.dismissQualityCandidate(candidate) } } } } }
}

private struct KnowledgeCompareView: View {
    @ObservedObject var store:ThoughtStore; let candidate:KnowledgeQualityCandidate
    @State private var confirmsSupersede=false
    private var first:KnowledgeDocument? { store.knowledgeDocuments.first{$0.id==candidate.knowledgeID} }; private var second:KnowledgeDocument? { guard let id=candidate.relatedKnowledgeID else{return nil}; return store.knowledgeDocuments.first{$0.id==id} }
    var body: some View { List { if let first { comparison(first,label:"Knowledge A") }; if let second { comparison(second,label:"Knowledge B") }; if let first,let second,first.status == .active,second.status == .active { Section("Actions") { Button("AをBでSupersede",role:.destructive) { confirmsSupersede=true }; Button("Create Merge Draft") { store.createMergeDraft(candidate) } } } }.navigationTitle("Compare").confirmationDialog("Knowledge AをBでSupersedeしますか？",isPresented:$confirmsSupersede,titleVisibility:.visible) { Button("Supersede",role:.destructive) { if let first,let second { store.supersedeKnowledge(first,by:second) } }; Button("キャンセル",role:.cancel){} } }
    @ViewBuilder private func comparison(_ document:KnowledgeDocument,label:String)->some View { Section(label) { Text(document.title).font(.headline); LabeledContent("Source",value:document.source.displayName); LabeledContent("Created",value:document.createdAt.formatted()); LabeledContent("Updated",value:document.updatedAt.formatted()); LabeledContent("Tags",value:document.tags.joined(separator:", ")); Text(document.markdown).font(.system(.caption,design:.monospaced)).textSelection(.enabled) } }
}

private struct KnowledgeDraftReviewView: View {
    @ObservedObject var store: ThoughtStore
    let draftID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var edited: KnowledgeDraft?
    @State private var confirmsPromotion=false
    @State private var confirmsDeletion=false
    private var current: KnowledgeDraft? { edited ?? store.knowledgeDrafts.first { $0.id == draftID } }
    var body: some View {
        Form {
            if var draft=current {
                Section("Review") { TextField("Title",text:Binding(get:{ edited?.title ?? draft.title },set:{ edited = edited ?? draft; edited?.title=$0 })); Picker("Type",selection:Binding(get:{ edited?.type ?? draft.type },set:{ edited = edited ?? draft; edited?.type=$0 })) { ForEach(KnowledgeDraftType.allCases,id:\.self) { Text($0.displayName).tag($0) } }; TextField("Project",text:Binding(get:{ edited?.project ?? draft.project },set:{ edited = edited ?? draft; edited?.project=$0 })); TextField("Tags（カンマ区切り）",text:Binding(get:{ (edited?.tags ?? draft.tags).joined(separator:", ") },set:{ edited = edited ?? draft; edited?.tags=$0.split(separator:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty } })); TextEditor(text:Binding(get:{ edited?.body ?? draft.body },set:{ edited = edited ?? draft; edited?.body=$0 })).frame(minHeight:240).disabled(draft.reviewStatus == .promoted); if edited != nil && draft.reviewStatus != .promoted { Button("編集を保存") { if let edited { store.updateKnowledgeDraft(edited); self.edited=nil } } } }
                Section("Metadata") { LabeledContent("Source",value:draft.source.displayName); LabeledContent("Status",value:draft.reviewStatus.rawValue); LabeledContent("GitHub",value:draft.syncStatus.rawValue); LabeledContent("Draft path",value:draft.savedPath ?? "local"); if let path=draft.knowledgePath { LabeledContent("Knowledge path",value:path) }; LabeledContent("Created",value:draft.createdAt.formatted()); LabeledContent("Updated",value:draft.updatedAt.formatted()); if let id=draft.provenance.sourceID { LabeledContent("Source ID",value:id) }; if let persona=draft.provenance.personaID { LabeledContent("Persona ID",value:persona.uuidString) } }
                Section("Related Knowledge") { if draft.relatedDocuments.isEmpty { Text("なし") }; ForEach(Array(draft.relatedDocuments.enumerated()),id:\.offset) { Text("\($0.element.documentPath) > \($0.element.heading)") } }
                if draft.reviewStatus != .promoted { Section("Actions") { if draft.reviewStatus == .unreviewed || draft.reviewStatus == .rejected { Button("Approve") { store.reviewKnowledgeDraft(edited ?? draft,status:.approved); edited=nil } }; if draft.reviewStatus == .unreviewed || draft.reviewStatus == .approved { Button("Reject",role:.destructive) { store.reviewKnowledgeDraft(edited ?? draft,status:.rejected); edited=nil } }; if draft.reviewStatus == .approved { Button("Promote to Knowledge") { confirmsPromotion=true } }; Button(store.isDeletingKnowledgeDraft ? "削除中…" : "Draftを削除",role:.destructive) { confirmsDeletion=true }.disabled(store.isDeletingKnowledgeDraft) } }
                if let message=store.knowledgeDraftMessage { Section { Text(message).foregroundStyle(.green) } }; if let error=store.knowledgeDraftError { Section { Text(error).foregroundStyle(.red) } }
            }
        }.navigationTitle("Draft Review").onAppear { store.loadKnowledge() }.confirmationDialog("正式Knowledgeへ昇格しますか？",isPresented:$confirmsPromotion,titleVisibility:.visible) { Button("Promote") { if let current { Task { await store.promoteKnowledgeDraft(current) } } }; Button("キャンセル",role:.cancel) {} } message: { if let current { Text("Title: \(current.title)\nDestination: \(KnowledgeDocumentPath.targetPath(date:Date(),title:current.title))\nSource: \(current.source.displayName)") } }
        .confirmationDialog("このDraftを削除しますか？",isPresented:$confirmsDeletion,titleVisibility:.visible) { Button("削除",role:.destructive) { if let current { Task { if await store.deleteKnowledgeDraft(current) { dismiss() } } } }; Button("キャンセル",role:.cancel) {} } message: { if let current { Text(current.savedPath == nil ? "ローカルのDraftを削除します。" : "GitHubのファイルとローカルのDraftを削除します。\n\(current.savedPath ?? "")") } }
    }
}

private struct AIReplyRequestView: View {
    @ObservedObject var store: ThoughtStore
    let thought: Thought
    var onReplyGenerated: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var userRequest = "このThoughtに返信してください"
    @State private var isSubmitting = false
    var body: some View {
        NavigationStack {
            List {
                if let persona = store.mentionedPersonasByThoughtID[thought.id] {
                    Section("返信するAI") { HStack { PersonaIcon(persona: persona, size: 40); VStack(alignment: .leading) { Text(persona.displayName).font(.headline); Text(store.aiConfigurations[persona.id]?.role ?? "").font(.caption).foregroundStyle(.secondary) } } }
                    Section("対象Thought") { Text(thought.body) }
                    Section("依頼") { TextField("AIへの今回の依頼", text: $userRequest, axis: .vertical).lineLimit(2...5) }
                    if let configuration = store.aiConfigurations[persona.id] { Section("指示") { Text(configuration.instructions) } }
                }
                Section { Text(store.aiReplyPreviewPreference == .alwaysShow ? "確認を押すまでAI通信は行いません。" : "送信後、AI返信を生成してそのまま投稿します。").font(.footnote).foregroundStyle(.secondary) }
                if let error = store.aiReplyError { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("AIに返信を依頼")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { store.cancelAIReplyPreview(); dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button(store.aiReplyPreviewPreference == .alwaysShow ? "確認" : (isSubmitting ? "送信中…" : "送信")) { submit() }.disabled(userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting) } }
            .sheet(item: previewPresentation) {
                AIReplyPreviewView(
                    store: store,
                    preview: $0,
                    parentDismiss: dismiss,
                    onReplyGenerated: onReplyGenerated
                )
            }
        }
    }

    private var previewPresentation: Binding<AIThoughtReplyPreview?> {
        Binding(
            get: { store.aiReplyPreviewPreference == .alwaysShow ? store.aiReplyPreview : nil },
            set: { if $0 == nil { store.cancelAIReplyPreview() } }
        )
    }

    private func submit() {
        store.prepareAIReply(to: thought, userRequest: userRequest)
        guard store.aiReplyPreviewPreference == .skip, let preview = store.aiReplyPreview else { return }
        isSubmitting = true
        Task {
            if await store.generateAndPublishAIReply(from: preview) {
                dismiss()
                onReplyGenerated()
            }
            isSubmitting = false
        }
    }
}

private struct AIReplyPreviewView: View {
    @ObservedObject var store: ThoughtStore
    let preview: AIThoughtReplyPreview
    let parentDismiss: DismissAction
    let onReplyGenerated: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("返信するAI") { Text(preview.persona.displayName); LabeledContent("役割", value: preview.configuration.role) }
                Section("対象Thought") { Text(preview.targetThought.body) }
                Section("依頼") { Text(preview.userRequest) }
                Section("会話文脈") {
                    ForEach(preview.context.entries, id: \.thought.id) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            PersonaIcon(persona: entry.author, size: 32)
                            VStack(alignment: .leading, spacing: 4) { Text(entry.author.displayName).font(.subheadline.weight(.semibold)); Text(entry.author.kind == .human ? "Human" : "AI").font(.caption2).foregroundStyle(.secondary); Text(entry.thought.body) }
                        }
                    }
                }
                Section("External Brain") {
                    if let brain = preview.externalBrain {
                        LabeledContent("使用Persona", value: preview.persona.displayName)
                        LabeledContent("AGENT.md", value: brain.agentPath)
                        LabeledContent("取得資料", value: "\(brain.chunks.count)件")
                        VStack(alignment: .leading, spacing: 4) { Text("Retrieval Route").font(.caption).foregroundStyle(.secondary); ForEach(Array(brain.routes.enumerated()), id: \.offset) { Text("\($0.offset + 1). \($0.element)") } }
                        if brain.chunks.isEmpty { Text("今回の検索語に一致する参照資料はありません。接続・同期の失敗を意味する表示ではありません。").foregroundStyle(.secondary) }
                        ForEach(Array(brain.chunks.enumerated()), id: \.offset) { item in
                            VStack(alignment: .leading, spacing: 4) { Text(item.element.documentPath).font(.subheadline.weight(.semibold)); Text(item.element.heading).font(.caption).foregroundStyle(.secondary); Text(item.element.excerpt).font(.caption).lineLimit(6) }
                        }
                    } else { Text("利用なし").foregroundStyle(.secondary) }
                }
                Section("最終payload") { Text(preview.request.prompt).font(.caption).textSelection(.enabled) }
                Section("生成元") { LabeledContent("Provider", value: preview.configuration.provider.displayName); LabeledContent("Model", value: preview.configuration.provider.defaultModel) }
                if let draft = store.aiReplyDraft, draft.preview.id == preview.id {
                    Section("返信Preview") { Text(draft.body).font(.body); Text("投稿するまでTimelineには保存されません。").font(.footnote).foregroundStyle(.secondary) }
                }
                if let error = store.aiReplyError { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("送信前プレビュー")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { store.cancelAIReplyPreview(); dismiss() } }; ToolbarItem(placement: .confirmationAction) { if let draft = store.aiReplyDraft, draft.preview.id == preview.id { Button("投稿する") { if store.publishAIReply(draft) { dismiss(); parentDismiss(); onReplyGenerated() } } } else { Button(store.isGeneratingAIReply ? "生成中…" : "返信を生成") { Task { await store.generateAIReply(from: preview) } }.disabled(store.isGeneratingAIReply) } } }
        }
    }
}

struct PersonaIcon: View {
    let persona: Persona
    let size: CGFloat

    var body: some View {
        Group {
            if let data = persona.iconData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct ExternalBrainBadge: View {
    @ObservedObject private var manager: ExternalBrainManager
    let persona: Persona

    init(store: ThoughtStore, persona: Persona) {
        manager = store.externalBrainManager
        self.persona = persona
    }

    var body: some View {
        if persona.kind == .ai, manager.connectionStatus(for: persona.id) == .verified {
            Image(systemName: "medal.fill")
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.yellow, Color.orange)
                .padding(4)
                .background(Color.orange.opacity(0.13), in: Circle())
                .accessibilityLabel("外部ブレイン接続済み")
                .accessibilityIdentifier("externalBrainConnectedBadge_\(persona.id.uuidString)")
        }
    }
}

private struct ActorProfileView: View {
    @ObservedObject var store: ThoughtStore
    let persona: Persona
    var allowsEditing = false
    @State private var showsEditor = false
    @State private var showsSettings = false

    private var configuration: AIPersonaConfiguration? { store.aiConfigurations[persona.id] }
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    PersonaIcon(persona: persona, size: 104)
                    HStack(spacing: 7) {
                        Text(persona.displayName)
                            .font(.title2.weight(.bold))
                        ExternalBrainBadge(store: store, persona: persona)
                    }
                    Text("@\(persona.handle)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("actorProfileHandle")
                    Text(persona.kind == .ai ? "AI" : "Human")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(persona.kind == .ai ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background((persona.kind == .ai ? Color.accentColor : Color.secondary).opacity(0.12), in: Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("プロフィール") {
                LabeledContent("表示名", value: persona.displayName)
                LabeledContent("@ID", value: "@\(persona.handle)")
                LabeledContent("ユーザー種別", value: persona.kind == .ai ? "AI" : "人間")
                VStack(alignment: .leading, spacing: 6) {
                    Text("自己紹介").font(.caption).foregroundStyle(.secondary)
                    Text(description)
                }
            }

            if persona.kind == .ai {
                Section("AIペルソナ") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("役割", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(configuration?.role ?? "役割は未設定です")
                            .font(.title3.weight(.semibold))
                    }
                    .padding(.vertical, 6)
                    LabeledContent("Provider", value: configuration?.provider.displayName ?? "未設定")
                    LabeledContent("使用Model", value: configuration?.provider.defaultModel ?? "未設定")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("指示と個性").font(.caption).foregroundStyle(.secondary)
                        Text(configuration?.instructions ?? "指示と個性は未設定です")
                    }
                }

                PersonaExternalBrainConnectionChecker(store: store, persona: persona)

            }

        }
        .themedScrollableBackground()
        .navigationTitle("プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("actorProfileView")
        .toolbar {
            if allowsEditing {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("編集") { showsEditor = true }
                        .accessibilityIdentifier("editProfileButton")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if persona.kind == .human {
                        Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("設定を開く")
                            .accessibilityIdentifier("settingsButton")
                    }
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            if persona.kind == .ai {
                AIPersonaEditorView(store: store, persona: persona)
            } else {
                ProfileEditorView(store: store)
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView(store: store) }
    }

    private var description: String {
        if persona.kind == .ai {
            return configuration.map { "\($0.role)としてThoughtに参加するAIペルソナです。" }
                ?? "タイムラインに参加するAIペルソナです。"
        }
        return "Thoughtを記録し、AIペルソナと対話するユーザーです。"
    }
}

private struct PersonaExternalBrainConnectionChecker: View {
    @ObservedObject var manager: ExternalBrainManager
    let persona: Persona

    init(store: ThoughtStore, persona: Persona) {
        manager = store.externalBrainManager
        self.persona = persona
    }

    private var status: PersonaExternalBrainConnectionStatus {
        manager.connectionStatus(for: persona.id)
    }

    var body: some View {
        Section("外部ブレイン接続") {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(statusColor.opacity(0.18)).frame(width: 28, height: 28)
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.footnote).foregroundStyle(.secondary)
                    if let checkedAt = manager.connectionCheckedAt {
                        Text("最終確認: \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("外部ブレイン接続、\(statusTitle)、\(statusDetail)")
            .accessibilityIdentifier("personaExternalBrainConnectionStatus")

            Button {
                Task { await manager.testConnection() }
            } label: {
                if manager.isTestingConnection {
                    HStack { ProgressView(); Text("確認中…") }
                } else {
                    Label("接続を確認", systemImage: "network")
                }
            }
            .disabled(manager.isTestingConnection || !canTestConnection)
            .accessibilityIdentifier("personaExternalBrainConnectionCheckButton")

            Text("AI APIは呼びません。GitHubのRepositoryとBranchを読み取るだけなので、AIトークン消費はありません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var canTestConnection: Bool {
        let configuration = manager.configuration(for: persona.id)
        return configuration.enabled && manager.repository.isConfigured && manager.hasToken
    }

    private var statusColor: Color {
        switch status {
        case .verified: .green
        case .verificationNeeded, .synchronizationNeeded: .orange
        case .disabled: .secondary
        case .invalidAgentPath, .repositoryNotConfigured, .tokenMissing, .failed: .red
        }
    }

    private var statusTitle: String {
        switch status {
        case .disabled: "使用しない設定"
        case .invalidAgentPath: "AGENT.mdの設定が必要"
        case .repositoryNotConfigured: "Repositoryが未設定"
        case .tokenMissing: "GitHub tokenが未設定"
        case .verificationNeeded(let hasLocalCache): hasLocalCache ? "ローカル利用可・接続未確認" : "接続未確認"
        case .synchronizationNeeded: "GitHub接続済み・同期が必要"
        case .verified: "接続確認済み"
        case .failed: "接続できません"
        }
    }

    private var statusDetail: String {
        switch status {
        case .disabled:
            "このAIペルソナでは外部ブレインがOFFです。"
        case .invalidAgentPath:
            "AIペルソナ編集で安全なAGENT.mdのパスを設定してください。"
        case .repositoryNotConfigured:
            "AI機能の「外部ブレイン設定」でGitHub Repositoryを設定してください。"
        case .tokenMissing:
            "AI機能の「外部ブレイン設定」でGitHub tokenを保存してください。"
        case .verificationNeeded(let hasLocalCache):
            hasLocalCache
                ? "同期済みキャッシュは使えます。現在のGitHub接続は未確認です。"
                : "接続確認後に同期すると、このペルソナから参照できます。"
        case .synchronizationNeeded:
            "Repositoryへ接続できました。外部ブレインを使うには同期してください。"
        case .verified:
            "GitHub接続と、このペルソナの同期済みAGENT.mdを確認できました。"
        case .failed(let issue):
            issue.localizedDescription
        }
    }
}

private struct AIPersonaManagementView: View {
    @ObservedObject var store: ThoughtStore
    @State private var showsNewAIEditor = false

    var body: some View {
        List {
            Section("AIペルソナ") {
                if aiPersonas.isEmpty {
                    Text("AIペルソナはまだありません")
                        .foregroundStyle(.secondary)
                }
                ForEach(aiPersonas) { persona in
                    NavigationLink {
                        ActorProfileView(store: store, persona: persona, allowsEditing: true)
                    } label: {
                        personaRow(persona)
                    }
                    .accessibilityIdentifier("aiPersonaProfileButton")
                    .padding(.vertical, 4)
                }
                Button { showsNewAIEditor = true } label: { Label("AIペルソナを追加", systemImage: "plus.circle") }
                    .accessibilityIdentifier("addAIPersonaButton")
            }
            Section {
                Text("AIペルソナを選ぶと、プロフィールと設定を確認・編集できます。投稿の依頼はAI機能の「AIに投稿を依頼」から行います。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AIペルソナ")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsNewAIEditor) { AIPersonaEditorView(store: store, persona: nil) }
    }

    private var aiPersonas: [Persona] { store.personas.filter { $0.kind == .ai } }

    private func personaRow(_ persona: Persona) -> some View {
        HStack(spacing: 12) {
            PersonaIcon(persona: persona, size: 44)
            VStack(alignment: .leading) {
                HStack(spacing: 5) {
                    Text(persona.displayName).foregroundStyle(.primary)
                    ExternalBrainBadge(store: store, persona: persona)
                }
                Text(persona.kind == .human ? "人間" : "AI").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.contentShape(Rectangle())
    }
}

private struct AIPersonaEditorView: View {
    @ObservedObject var store: ThoughtStore
    let persona: Persona?
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var handle: String
    @State private var iconData: Data?
    @State private var selectedItem: PhotosPickerItem?
    @State private var role: String
    @State private var instructions: String
    @State private var autoReplyEnabled: Bool
    @State private var provider: AIProvider
    @State private var brainEnabled: Bool
    @State private var agentPath: String
    @State private var maxChunks: Int
    @State private var saveError: String?

    init(store: ThoughtStore, persona: Persona?) {
        self.store = store; self.persona = persona
        _displayName = State(initialValue: persona?.displayName ?? "")
        _handle = State(initialValue: persona?.handle ?? "")
        _iconData = State(initialValue: persona?.iconData)
        let configuration = persona.flatMap { store.aiConfigurations[$0.id] }
        _role = State(initialValue: configuration?.role ?? "")
        _instructions = State(initialValue: configuration?.instructions ?? "")
        _autoReplyEnabled = State(initialValue: configuration?.autoReplyEnabled ?? true)
        _provider = State(initialValue: configuration?.provider ?? .gemini)
        let brain = persona.map { store.externalBrainManager.configuration(for: $0.id) }
        _brainEnabled = State(initialValue: brain?.enabled ?? false)
        _agentPath = State(initialValue: brain?.agentPath ?? "")
        _maxChunks = State(initialValue: brain?.maxRetrievedChunks ?? 5)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("アイコン") {
                    HStack { Spacer(); PersonaIcon(persona: previewPersona, size: 96); Spacer() }
                    PhotosPicker(selection: $selectedItem, matching: .images) { Label("写真を選ぶ", systemImage: "photo") }
                    if iconData != nil { Button("アイコンを削除", role: .destructive) { iconData = nil } }
                }
                Section("表示名") { TextField("AI Persona名", text: $displayName) }
                Section("@ID") { TextField("dev_ai", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled() }
                Section("役割") { TextField("例：アイデアを広げる相棒", text: $role, axis: .vertical) }
                Section("指示") { TextField("口調、視点、避けることなど", text: $instructions, axis: .vertical).lineLimit(3...8) }
                Section("AI Provider") {
                    Picker("Provider", selection: $provider) {
                        ForEach(AIProvider.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    LabeledContent("Model", value: provider.defaultModel)
                    LabeledContent("思考量", value: "Low")
                    Text("このProviderはAI Personaの投稿・手動返信・自動返信に共通で使います。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(provider == .gemini ? "Firebase AI LogicからGeminiを呼び出します。" : "この端末のKeychainに保存したAPI keyでOpenAIを直接呼び出します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("返信") {
                    Toggle("自動返信", isOn: $autoReplyEnabled)
                    Text(autoReplyEnabled ? "HumanのThoughtで@メンションされると自動で返信します。AI自身の投稿からは連鎖しません。" : "@メンションされても自動返信しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("外部ブレイン") {
                    Toggle("外部ブレイン", isOn: $brainEnabled)
                    TextField("personas/architect/AGENT.md", text: $agentPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("最大参照 \(maxChunks)件", value: $maxChunks, in: 1...5)
                }
                if let saveError {
                    Section("保存エラー") {
                        Text(saveError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("aiPersonaSaveError")
                    }
                }
                if let persona { Section { Button("AI Personaを無効化", role: .destructive) { store.deactivateAIPersona(persona); dismiss() } } }
            }
            .navigationTitle(persona == nil ? "AIペルソナを追加" : "AIペルソナを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
#if DEBUG
                        NSLog("[AIPersona][Editor] save button action fired mode=%@ handle=%@", persona == nil ? "create" : "update", handle)
#endif
                        saveError = nil
                        let saved = persona.map { store.updateAIPersona($0, displayName: displayName, handle: handle, iconData: iconData, role: role, instructions: instructions, autoReplyEnabled: autoReplyEnabled, provider: provider) }
                            ?? store.createAIPersona(displayName: displayName, handle: handle, iconData: iconData, role: role, instructions: instructions, autoReplyEnabled: autoReplyEnabled, provider: provider, externalBrainEnabled: brainEnabled, agentPath: agentPath, maxRetrievedChunks: maxChunks)
                        if saved {
                            if let persona { store.externalBrainManager.savePersona(.init(personaID: persona.id, enabled: brainEnabled, agentPath: agentPath, maxRetrievedChunks: maxChunks)) }
                            dismiss()
                        } else {
                            saveError = store.errorMessage ?? "AI Personaを保存できませんでした。"
                        }
                    }.disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName.count > 40 || ActorHandle.normalize(handle) == nil || role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (brainEnabled && !ExternalBrainPath.isSafe(agentPath)))
                }
            }
            .onChange(of: selectedItem) { item in
                Task { guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }; iconData = image.squareJPEG(maxPixels: 512, quality: 0.82) }
            }
        }
    }

    private var previewPersona: Persona { Persona(id: persona?.id ?? UUID(), displayName: displayName, handle: handle.isEmpty ? nil : handle, kind: .ai, iconData: iconData, iconMIMEType: iconData == nil ? nil : "image/jpeg") }
}

private struct AIPostRequestView: View {
    @ObservedObject var store: ThoughtStore
    @State private var selectedPersonaID: UUID?
    @State private var userRequest = ""

    init(store: ThoughtStore) {
        self.store = store
        _selectedPersonaID = State(initialValue: store.personas.first(where: { $0.kind == .ai })?.id)
    }

    private var aiPersonas: [Persona] { store.personas.filter { $0.kind == .ai } }
    private var selectedPersona: Persona? { aiPersonas.first { $0.id == selectedPersonaID } }

    var body: some View {
        Form {
            Section("AI") {
                if aiPersonas.isEmpty {
                    Text("利用できるAIペルソナがありません。先にAI Personasから追加してください。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("投稿するAI", selection: $selectedPersonaID) {
                        ForEach(aiPersonas) { persona in
                            Text(persona.displayName).tag(Optional(persona.id))
                        }
                    }
                    .accessibilityIdentifier("aiPostPersonaPicker")

                    if let persona = selectedPersona {
                        HStack(spacing: 12) {
                            PersonaIcon(persona: persona, size: 44)
                            VStack(alignment: .leading) {
                                HStack(spacing: 5) {
                                    Text(persona.displayName).font(.headline)
                                    ExternalBrainBadge(store: store, persona: persona)
                                }
                                Text(store.aiConfigurations[persona.id]?.role ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("依頼") {
                TextField("AIに考えて投稿してほしいこと", text: $userRequest, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("aiPostRequestEditor")
            }
            Section { Text("投稿を押すと確認画面へ進みます。確認画面で送信するまでAI通信も投稿も行いません。").font(.footnote).foregroundStyle(.secondary) }
            if let error = store.aiPostError { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("AIに投稿を依頼")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("投稿") {
                    guard let persona = selectedPersona else { return }
                    store.prepareAIPost(persona: persona, userRequest: userRequest)
                }
                .disabled(selectedPersona == nil || userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("prepareAIPostButton")
            }
        }
        .sheet(item: $store.aiPostPreview) { AIPostPreviewView(store: store, preview: $0) }
    }
}

private struct AIPostPreviewView: View {
    @ObservedObject var store: ThoughtStore
    let preview: AIPostPreview
    var parentDismiss: DismissAction? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("投稿者") { Text(preview.persona.displayName); LabeledContent("役割", value: preview.configuration.role) }
                Section("依頼") { Text(preview.userRequest) }
                Section("External Brain") {
                    if let brain = preview.externalBrain {
                        LabeledContent("AGENT.md", value: brain.agentPath)
                        LabeledContent("取得資料", value: "\(brain.chunks.count)件")
                        VStack(alignment: .leading, spacing: 4) { Text("選択Route").font(.caption).foregroundStyle(.secondary); ForEach(Array(brain.routes.enumerated()), id: \.offset) { Text("\($0.offset + 1). \($0.element)") } }
                        if brain.chunks.isEmpty { Text("今回の検索語に一致する参照資料はありません。接続・同期の失敗を意味する表示ではありません。").foregroundStyle(.secondary) }
                        ForEach(Array(brain.chunks.enumerated()), id: \.offset) { item in
                            VStack(alignment: .leading, spacing: 4) { Text(item.element.documentPath).font(.subheadline.weight(.semibold)); Text(item.element.heading).font(.caption).foregroundStyle(.secondary); Text(item.element.excerpt).font(.caption).lineLimit(6) }
                        }
                    } else { Text("利用なし").foregroundStyle(.secondary) }
                }
                Section("最終payload") { Text(preview.request.prompt).font(.caption).textSelection(.enabled) }
                Section("生成元") { LabeledContent("Provider", value: preview.configuration.provider.displayName); LabeledContent("Model", value: preview.configuration.provider.defaultModel) }
                if let error = store.aiPostError { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("送信前プレビュー")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { store.cancelAIPostPreview(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(store.isGeneratingAIPost ? "生成中…" : "送信") { Task { await store.generateAIPost(from: preview); if store.aiPostError == nil { dismiss(); parentDismiss?() } } }.disabled(store.isGeneratingAIPost) }
            }
        }
    }
}

private struct ProfileEditorView: View {
    @ObservedObject var store: ThoughtStore
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var handle: String
    @State private var iconData: Data?
    @State private var selectedItem: PhotosPickerItem?

    init(store: ThoughtStore) {
        self.store = store
        _displayName = State(initialValue: store.defaultHumanPersona.displayName)
        _handle = State(initialValue: store.defaultHumanPersona.handle)
        _iconData = State(initialValue: store.defaultHumanPersona.iconData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("アイコン") {
                    HStack { Spacer(); PersonaIcon(persona: previewPersona, size: 96); Spacer() }
                    PhotosPicker(selection: $selectedItem, matching: .images) { Label("写真を選ぶ", systemImage: "photo") }
                    if iconData != nil { Button("アイコンを削除", role: .destructive) { iconData = nil } }
                }
                Section("表示名") { TextField("自分", text: $displayName).textInputAutocapitalization(.never) }
                Section("@ID") { TextField("myself", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled() }
                Section { Text("プロフィールは端末内だけに保存され、既存のThoughtにも同じ名前とアイコンが表示されます。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("プロフィール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if store.updateDefaultHumanPersona(displayName: displayName, handle: handle, iconData: iconData) { dismiss() } }
                        .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName.count > 40 || ActorHandle.normalize(handle) == nil)
                }
            }
            .onChange(of: selectedItem) { item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                    iconData = image.squareJPEG(maxPixels: 512, quality: 0.82)
                }
            }
        }
    }

    private var previewPersona: Persona {
        Persona(id: store.defaultHumanPersona.id, displayName: displayName, handle: handle, kind: .human, iconData: iconData, iconMIMEType: iconData == nil ? nil : "image/jpeg")
    }
}

private extension UIImage {
    func squareJPEG(maxPixels: CGFloat, quality: CGFloat) -> Data? {
        let side = min(size.width, size.height)
        guard side > 0 else { return nil }
        let targetSide = min(maxPixels, side)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetSide, height: targetSide))
        let output = renderer.image { _ in
            let scale = targetSide / side
            let drawnSize = CGSize(width: size.width * scale, height: size.height * scale)
            draw(in: CGRect(x: (targetSide - drawnSize.width) / 2, y: (targetSide - drawnSize.height) / 2, width: drawnSize.width, height: drawnSize.height))
        }
        return output.jpegData(compressionQuality: quality)
    }
}

enum ThoughtDateText {
    static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨日 \(time)"
        }
        return date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
    }
}

#Preview {
    TimelineView(store: ThoughtStore(repository: MemoryThoughtRepository(records: [
        Thought(body: "AIを入れる前に、まず毎日使える入力体験を完成させたい。"),
        Thought(body: "SQLite化まで終わったので、次はUIをもっと軽くしたい。", createdAt: .now.addingTimeInterval(-3_600))
    ])))
}
