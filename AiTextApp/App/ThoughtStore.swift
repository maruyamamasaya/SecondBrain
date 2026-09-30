import Combine
import Foundation

@MainActor
final class ThoughtStore: ObservableObject {
    enum AutomaticReplyState: Equatable {
        case generating
        case failed(String)
    }
    enum AIReplyPreviewPreference: String, CaseIterable, Identifiable {
        case alwaysShow
        case skip

        var id: Self { self }
    }

    struct PostNavigationRequest: Equatable {
        let id = UUID()
        let thoughtID: UUID
        let resetsNavigation: Bool
    }

    struct ExportArtifact: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Published var draft = ""
    @Published private(set) var thoughts: [Thought] = []
    @Published private(set) var isLoadingTimelinePage = false
    @Published private(set) var timelinePaginationError: String?
    @Published private(set) var defaultHumanPersona = Persona(id: Persona.defaultHumanID, displayName: "自分", kind: .human)
    @Published private(set) var personas: [Persona] = []
    @Published private(set) var personasByThoughtID: [UUID: Persona] = [:]
    @Published private(set) var mentionedPersonasByThoughtID: [UUID: Persona] = [:]
    @Published private(set) var mentionsByThoughtID: [UUID: [ThoughtMention]] = [:]
    @Published var selectedMentionPersona: Persona?
    @Published private(set) var aiConfigurations: [UUID: AIPersonaConfiguration] = [:]
    @Published var aiPostPreview: AIPostPreview?
    @Published private(set) var isGeneratingAIPost = false
    @Published var aiPostError: String?
    @Published var aiReplyPreview: AIThoughtReplyPreview?
    @Published var aiReplyDraft: AIThoughtReplyDraft?
    @Published private(set) var isGeneratingAIReply = false
    @Published var aiReplyError: String?
    @Published private(set) var postNavigationRequest: PostNavigationRequest?
    @Published var aiReplyPreviewPreference: AIReplyPreviewPreference {
        didSet { userDefaults.set(aiReplyPreviewPreference.rawValue, forKey: Self.aiReplyPreviewPreferenceKey) }
    }
    @Published var knowledgeDraftAIProvider: AIProvider {
        didSet { userDefaults.set(knowledgeDraftAIProvider.rawValue, forKey: Self.knowledgeDraftAIProviderKey) }
    }
    @Published private(set) var hasOpenAIAPIKey = false
    @Published var openAIAPIKeyMessage: String?
    @Published private(set) var aiRepliesByTargetID: [UUID: [Thought]] = [:]
    @Published private(set) var automaticRepliesByTargetID: [UUID: [UUID: AutomaticReplyState]] = [:]
    @Published private(set) var replyTargetIDsByThoughtID: [UUID: UUID] = [:]
    @Published private(set) var replyTargetsByThoughtID: [UUID: Thought] = [:]
    @Published private(set) var dailySummaries: [DailySummary] = []
    @Published private(set) var dailySummary: DailySummary?
    @Published private(set) var dailySummaryPreview: DailySummaryPreview?
    @Published private(set) var isGeneratingDailySummary = false
    @Published var dailySummaryError: String?
    @Published private(set) var dailySummaryDayThoughts: [Thought] = []
    @Published private(set) var dailySummaryDayTags: [String] = []
    @Published private(set) var dailySummaryDayContinuationCount = 0
    @Published private(set) var weeklySummaries: [WeeklySummary] = []
    @Published private(set) var weeklySummary: WeeklySummary?
    @Published private(set) var weeklyPlan: WeeklyPlan?
    @Published private(set) var weeklySummaryPreview: WeeklySummaryPreview?
    @Published private(set) var weeklyPlanDraft: WeeklyPlanDraft?
    @Published private(set) var isGeneratingWeeklyReview = false
    @Published var weeklyReviewError: String?
    @Published private(set) var searchResults: [Thought] = []
    @Published private(set) var hasSearchQuery = false
    @Published private(set) var tagsByThoughtID: [UUID: [ThoughtTag]] = [:]
    @Published private(set) var allTags: [ThoughtTag] = []
    @Published private(set) var taggedThoughts: [Thought] = []
    @Published var tagMessage: String?
    @Published var deletionCandidate: Thought?
    @Published var errorMessage: String?
    @Published var exportArtifact: ExportArtifact?
    @Published private(set) var history: [ThoughtHistoryEntry] = []
    @Published private(set) var conversationThread: ConversationThread?
    @Published private(set) var historyCurrentID: UUID?
    @Published var continuationDraft = ""
    @Published var humanReplyDraft = ""
    @Published private(set) var analytics: ThoughtAnalyticsSnapshot?
    @Published private(set) var isLoadingAnalytics = false
    @Published private(set) var aiUsageAnalytics: AIAPIUsageAnalytics?
    @Published private(set) var isLoadingAIUsageAnalytics = false
    @Published var aiUsageAnalyticsError: String?
    @Published var knowledgeDraft: KnowledgeDraft?
    @Published private(set) var isGeneratingKnowledgeDraft = false
    @Published private(set) var isSavingKnowledgeDraft = false
    @Published private(set) var isDeletingKnowledgeDraft = false
    @Published var knowledgeDraftError: String?
    @Published var knowledgeDraftMessage: String?
    @Published private(set) var knowledgeDrafts: [KnowledgeDraft] = []
    @Published private(set) var knowledgeDocuments: [KnowledgeDocument] = []
    @Published private(set) var knowledgeLifecycleEvents: [KnowledgeLifecycleEvent] = []
    @Published private(set) var knowledgeQualityCandidates: [KnowledgeQualityCandidate] = []
    @Published private(set) var secondBrainApps: [SecondBrainApp] = []
    let externalBackupManager: ExternalBackupManager?
    let externalBrainManager: ExternalBrainManager

    private var timeline: ThoughtTimeline?
    private var exporter: ThoughtExporter?
    private var thoughtRepository: (any ThoughtRepository)?
    private var relationRepository: (any ThoughtRelationRepository)?
    private var continuationRepository: (any ThoughtContinuationRepository)?
    private var tagRepository: (any ThoughtTagRepository)?
    private var analyticsRepository: (any ThoughtAnalyticsRepository)?
    private var aiUsageAnalyticsRepository: (any AIAPIUsageAnalyticsRepository)?
    private var aiUsageRepository: (any AIAPIUsageRepository)?
    private var knowledgeDraftRepository: (any KnowledgeDraftRepository)?
    private var knowledgeLifecycleRepository: (any KnowledgeLifecycleEventRepository)?
    private var dailySummaryRepository: (any DailySummaryRepository)?
    private var weeklyReviewRepository: (any WeeklyReviewRepository)?
    private var personaRepository: (any PersonaRepository)?
    private var aiPersonaRepository: (any AIPersonaRepository)?
    private var mentionRepository: (any ThoughtMentionRepository)?
    private var aiReplyRepository: (any AIThoughtReplyRepository)?
    private var humanReplyRepository: (any HumanThoughtReplyRepository)?
    private var summaryClient: any ReviewSummaryClient
    private var isPosting = false
    private let userDefaults: UserDefaults
    private static let aiReplyPreviewPreferenceKey = "ai.replyPreviewPreference"
    private static let knowledgeDraftAIProviderKey = "ai.knowledgeDraftProvider"
    private static let legacyDefaultAIProviderKey = "ai.defaultProvider"

    private func handlePostSuccess(_ thought: Thought, resetsNavigation: Bool = true) {
        postNavigationRequest = PostNavigationRequest(
            thoughtID: thought.id,
            resetsNavigation: resetsNavigation
        )
    }

    func acknowledgePostNavigationRequest(id: UUID) {
        guard postNavigationRequest?.id == id else { return }
        postNavigationRequest = nil
    }

    init(
        repository: (any ThoughtRepository)? = nil,
        summaryClient: any ReviewSummaryClient = MockReviewSummaryClient(),
        startupError: String? = nil,
        externalBrainManager: ExternalBrainManager? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        aiReplyPreviewPreference = AIReplyPreviewPreference(rawValue: userDefaults.string(forKey: Self.aiReplyPreviewPreferenceKey) ?? "") ?? .skip
        let savedKnowledgeProvider = userDefaults.string(forKey: Self.knowledgeDraftAIProviderKey)
            ?? userDefaults.string(forKey: Self.legacyDefaultAIProviderKey)
        knowledgeDraftAIProvider = AIProvider(rawValue: savedKnowledgeProvider ?? "") ?? .gemini
        hasOpenAIAPIKey = !(OpenAIAPIKeyStore.load() ?? "").isEmpty
        self.summaryClient = summaryClient
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.externalBrainManager = externalBrainManager ?? ExternalBrainManager(rootURL: support.appendingPathComponent("ExternalBrain", isDirectory: true))
        var backupManager: ExternalBackupManager?
        do {
            let repository = try repository ?? SQLiteThoughtRepository()
            let timeline = try ThoughtTimeline(repository: repository)
            self.timeline = timeline
            thoughtRepository = repository
            relationRepository = repository as? any ThoughtRelationRepository
            continuationRepository = repository as? any ThoughtContinuationRepository
            tagRepository = repository as? any ThoughtTagRepository
            analyticsRepository = repository as? any ThoughtAnalyticsRepository
            aiUsageAnalyticsRepository = repository as? any AIAPIUsageAnalyticsRepository
            aiUsageRepository = repository as? any AIAPIUsageRepository
            knowledgeDraftRepository = repository as? any KnowledgeDraftRepository
            knowledgeLifecycleRepository = repository as? any KnowledgeLifecycleEventRepository
            dailySummaryRepository = repository as? any DailySummaryRepository
            weeklyReviewRepository = repository as? any WeeklyReviewRepository
            personaRepository = repository as? any PersonaRepository
            aiPersonaRepository = repository as? any AIPersonaRepository
            mentionRepository = repository as? any ThoughtMentionRepository
            aiReplyRepository = repository as? any AIThoughtReplyRepository
            humanReplyRepository = repository as? any HumanThoughtReplyRepository
            exporter = ThoughtExporter(repository: repository)
            thoughts = timeline.thoughts
            if let appRepository = repository as? any SecondBrainAppRepository {
                secondBrainApps = (try? appRepository.fetchAllApps()) ?? []
            } else {
                secondBrainApps = (try? SecondBrainDefaultApps.all()) ?? []
            }
            if let personaRepository { defaultHumanPersona = try personaRepository.fetchDefaultHumanPersona() }
            if let personaRepository { personas = try personaRepository.fetchPersonas(includeInactive: false) }
            if let aiPersonaRepository { aiConfigurations = try aiPersonaRepository.fetchAIConfigurations() }
            dailySummaries = try dailySummaryRepository?.fetchDailySummaries(from: .distantPast, to: .distantFuture) ?? []
            weeklySummaries = try weeklyReviewRepository?.fetchWeeklySummaries() ?? []
            knowledgeDrafts = try knowledgeDraftRepository?.fetchKnowledgeDrafts() ?? []; knowledgeDocuments = try knowledgeDraftRepository?.fetchKnowledgeDocuments() ?? []
            if let sqliteRepository = repository as? SQLiteThoughtRepository {
                backupManager = ExternalBackupManager(repository: sqliteRepository)
            }
        } catch {
            errorMessage = "保存データの整合性確認に失敗しました。アプリを削除せず、バックアップから復元してください。"
        }
        externalBackupManager = backupManager
        refreshTags(for: thoughts.map(\.id))
        refreshAuthors(for: thoughts.map(\.id))
        refreshMentions(for: thoughts.map(\.id))
        refreshReplyRelations(for: thoughts.map(\.id))
        loadAllTags()
        if let startupError { errorMessage = startupError }
    }

    func saveOpenAIAPIKey(_ apiKey: String) -> Bool {
        do {
            try OpenAIAPIKeyStore.save(apiKey)
            hasOpenAIAPIKey = true
            openAIAPIKeyMessage = "OpenAI API keyをこの端末のKeychainへ保存しました。"
            return true
        } catch let error as ReviewSummaryServiceError {
            openAIAPIKeyMessage = error.localizedDescription
            return false
        } catch {
            openAIAPIKeyMessage = "OpenAI API keyを保存できませんでした。"
            return false
        }
    }

    func removeOpenAIAPIKey() {
        do {
            try OpenAIAPIKeyStore.remove()
            hasOpenAIAPIKey = false
            openAIAPIKeyMessage = "OpenAI API keyをKeychainから削除しました。"
        } catch {
            openAIAPIKeyMessage = "OpenAI API keyを削除できませんでした。"
        }
    }

    func updateDefaultHumanPersona(displayName: String, handle: String, iconData: Data?) -> Bool {
        guard let personaRepository else { errorMessage = "プロフィールを保存できませんでした。"; return false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { errorMessage = "表示名は1〜40文字で入力してください。"; return false }
        guard let normalizedHandle = ActorHandle.normalize(handle) else { errorMessage = "@IDは半角英数字と_の3〜30文字で入力してください。"; return false }
        var persona = defaultHumanPersona
        persona.displayName = name
        persona.handle = normalizedHandle
        persona.iconData = iconData
        persona.iconMIMEType = iconData == nil ? nil : "image/jpeg"
        persona.updatedAt = Date()
        do {
            try personaRepository.updatePersona(persona)
            defaultHumanPersona = persona
            loadPersonas()
            refreshAuthors(for: thoughts.map(\.id))
            return true
        } catch {
            errorMessage = "プロフィールを保存できませんでした。"
            return false
        }
    }

    func createAIPersona(displayName: String, handle: String, iconData: Data?, role: String, instructions: String, autoReplyEnabled: Bool = true, provider: AIProvider = .gemini, externalBrainEnabled: Bool = false, agentPath: String = "", maxRetrievedChunks: Int = 5) -> Bool {
#if DEBUG
        NSLog("[AIPersona][Store] createAIPersona started handle=%@", handle)
#endif
        guard let aiPersonaRepository else {
            errorMessage = "AI Personaの保存先を利用できません（aiPersonaRepository == nil）。"
#if DEBUG
            NSLog("[AIPersona][Store] createAIPersona failed: aiPersonaRepository == nil")
#endif
            return false
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines), instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !role.isEmpty, !instructions.isEmpty else { errorMessage = "表示名・役割・指示を入力してください。"; return false }
        guard let normalizedHandle = ActorHandle.normalize(handle) else { errorMessage = "@IDは半角英数字と_の3〜30文字で入力してください。"; return false }
        let persona = Persona(displayName: name, handle: normalizedHandle, kind: .ai, iconData: iconData, iconMIMEType: iconData == nil ? nil : "image/jpeg")
        do {
            try aiPersonaRepository.createAIPersona(persona, configuration: AIPersonaConfiguration(personaID: persona.id, role: role, instructions: instructions, autoReplyEnabled: autoReplyEnabled, provider: provider))
            externalBrainManager.savePersona(.init(personaID: persona.id, enabled: externalBrainEnabled, agentPath: agentPath, maxRetrievedChunks: maxRetrievedChunks))
            do {
                try reloadPersonasAfterAIPersonaSave()
            } catch {
                errorMessage = "AI Personaは保存されましたが、保存後の再読み込みに失敗しました: \(error.localizedDescription)"
#if DEBUG
                NSLog("[AIPersona][Store] createAIPersona reload failed error=%@ localizedDescription=%@", String(describing: error), error.localizedDescription)
#endif
                return false
            }
#if DEBUG
            NSLog("[AIPersona][Store] createAIPersona succeeded persona_id=%@", persona.id.uuidString)
#endif
            return true
        } catch {
            errorMessage = error.localizedDescription
#if DEBUG
            NSLog("[AIPersona][Store] createAIPersona failed error=%@ localizedDescription=%@", String(describing: error), error.localizedDescription)
#endif
            return false
        }
    }

    func updateAIPersona(_ original: Persona, displayName: String, handle: String, iconData: Data?, role: String, instructions: String, autoReplyEnabled: Bool, provider: AIProvider) -> Bool {
        guard original.kind == .ai, let personaRepository, let aiPersonaRepository else { return false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines), instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !role.isEmpty, !instructions.isEmpty else { errorMessage = "表示名・役割・指示を入力してください。"; return false }
        guard let normalizedHandle = ActorHandle.normalize(handle) else { errorMessage = "@IDは半角英数字と_の3〜30文字で入力してください。"; return false }
        var persona = original; persona.displayName = name; persona.handle = normalizedHandle; persona.iconData = iconData; persona.iconMIMEType = iconData == nil ? nil : "image/jpeg"; persona.updatedAt = Date()
        do { try personaRepository.updatePersona(persona); try aiPersonaRepository.saveAIConfiguration(AIPersonaConfiguration(personaID: persona.id, role: role, instructions: instructions, autoReplyEnabled: autoReplyEnabled, provider: provider)); loadPersonas(); loadAIConfigurations(); refreshAuthors(for: thoughts.map(\.id)); return true }
        catch { errorMessage = "AI Personaを保存できませんでした。"; return false }
    }

    func deactivateAIPersona(_ persona: Persona) {
        guard persona.kind == .ai, let personaRepository else { return }
        do { _ = try personaRepository.deactivatePersona(id: persona.id, at: Date()); loadPersonas(); refreshMentions(for: thoughts.map(\.id)) }
        catch { errorMessage = "AI Personaを無効化できませんでした。" }
    }

    private func loadPersonas() {
        do { personas = try personaRepository?.fetchPersonas(includeInactive: false) ?? [] }
        catch { errorMessage = "Personaを読み込めませんでした。" }
    }
    private func loadAIConfigurations() { aiConfigurations = (try? aiPersonaRepository?.fetchAIConfigurations()) ?? [:] }

    private func reloadPersonasAfterAIPersonaSave() throws {
        guard let personaRepository, let aiPersonaRepository else {
            throw CocoaError(.featureUnsupported)
        }
        personas = try personaRepository.fetchPersonas(includeInactive: false)
        aiConfigurations = try aiPersonaRepository.fetchAIConfigurations()
    }

    func thoughts(authoredBy personaID: UUID) -> [Thought] {
        thoughts.filter { personasByThoughtID[$0.id]?.id == personaID }
    }

    func prepareAutonomousAIPost(persona: Persona) {
        let ownPosts = thoughts(authoredBy: persona.id).prefix(5)
        let recentTimeline = thoughts.prefix(8)
        let ownText = ownPosts.isEmpty ? "（過去の発言なし）" : ownPosts.map { "- \($0.body)" }.joined(separator: "\n")
        let timelineText = recentTimeline.isEmpty ? "（最近の投稿なし）" : recentTimeline.map { thought in
            let actor = personasByThoughtID[thought.id]?.displayName ?? "不明"
            return "- [\(actor)] \(thought.body)"
        }.joined(separator: "\n")
        let request = """
        テーマは指定しません。あなた自身のRoleとPersonalityを軸に、過去の発言と最近のタイムラインを参考にして、今この場で自然な1件を自由に考えてください。毎回知識の説明に偏らず、フリートーク、気づき、考察、質問、軽い話題も選択肢に含め、過去の発言の単純な繰り返しは避けてください。

        あなたの最近の発言:
        \(ownText)

        最近のタイムライン:
        \(timelineText)
        """
        prepareAIPost(persona: persona, userRequest: request)
    }

    func prepareAIPost(persona: Persona, userRequest: String) {
        guard let configuration = aiConfigurations[persona.id] else { aiPostError = AIPostError.missingConfiguration.localizedDescription; return }
        let externalBrain = externalBrainManager.retrieve(personaID: persona.id, query: userRequest); trackKnowledgeRetrieval(externalBrain)
        do { aiPostPreview = try AIPostPrompt.prepare(persona: persona, configuration: configuration, userRequest: userRequest, externalBrain: externalBrain); aiPostError = nil }
        catch { aiPostError = error.localizedDescription }
    }

    func cancelAIPostPreview() { aiPostPreview = nil }

    func generateAIPost(from preview: AIPostPreview) async {
        guard let aiPersonaRepository, let thoughtRepository else { aiPostError = "AI投稿の保存先を利用できません。"; return }
        isGeneratingAIPost = true; aiPostError = nil; defer { isGeneratingAIPost = false }
        do {
            let thought = try await GenerateAIPost(client: summaryClient, repository: aiPersonaRepository, usageRepository: aiUsageRepository)(preview: preview)
            timeline = try ThoughtTimeline(repository: thoughtRepository); thoughts = timeline?.thoughts ?? []
            refreshTags(for: thoughts.map(\.id)); refreshAuthors(for: thoughts.map(\.id)); aiPostPreview = nil
            handlePostSuccess(thought)
        } catch { aiPostError = error.localizedDescription }
    }

    func prepareAIReply(to thought: Thought, userRequest: String) {
        guard thought.deletedAt == nil, let persona = mentionedPersonasByThoughtID[thought.id],
              personas.contains(where: { $0.id == persona.id }), let configuration = aiConfigurations[persona.id], let aiReplyRepository else {
            aiReplyError = "返信先または有効なAI Personaを確認できません。"; return
        }
        do {
            let context = try aiReplyRepository.loadAIReplyContext(targetThoughtID: thought.id, maximumEntries: AIThoughtReplyPrompt.maximumContextEntries)
            let query = (context.entries.map(\.thought.body) + [userRequest]).joined(separator: " ")
            let externalBrain = externalBrainManager.retrieve(personaID: persona.id, query: query)
            trackKnowledgeRetrieval(externalBrain)
            let statements = try aiReplyRepository.fetchRecentAIStatements(personaID: persona.id, limit: 5)
            aiReplyPreview = try AIThoughtReplyPrompt.prepare(persona: persona, configuration: configuration, targetThought: thought, userRequest: userRequest, context: context, externalBrain: externalBrain, personaStatements: statements); aiReplyDraft = nil; aiReplyError = nil
        }
        catch { aiReplyError = error.localizedDescription }
    }

    private func makeAIReplyPreview(to thought: Thought, persona: Persona, userRequest: String) throws -> AIThoughtReplyPreview {
        guard thought.deletedAt == nil, persona.kind == .ai, persona.deletedAt == nil,
              let configuration = aiConfigurations[persona.id], let aiReplyRepository else { throw AIPostError.inactivePersona }
        let context = try aiReplyRepository.loadAIReplyContext(targetThoughtID: thought.id, maximumEntries: AIThoughtReplyPrompt.maximumContextEntries)
        let query = (context.entries.map(\.thought.body) + [userRequest]).joined(separator: " ")
        let externalBrain = externalBrainManager.retrieve(personaID: persona.id, query: query)
        trackKnowledgeRetrieval(externalBrain)
        let statements = try aiReplyRepository.fetchRecentAIStatements(personaID: persona.id, limit: 5)
        return try AIThoughtReplyPrompt.prepare(persona: persona, configuration: configuration, targetThought: thought, userRequest: userRequest, context: context, externalBrain: externalBrain, personaStatements: statements)
    }

    private func startAutomaticReplies(to thought: Thought, personaIDs: [UUID]) {
        let targets = Array(Set(personaIDs)).compactMap { id -> Persona? in
            guard let persona = personas.first(where: { $0.id == id }), persona.kind == .ai,
                  aiConfigurations[id]?.autoReplyEnabled == true else { return nil }
            return persona
        }
        guard !targets.isEmpty else { return }
        for persona in targets { automaticRepliesByTargetID[thought.id, default: [:]][persona.id] = .generating }
        Task { for persona in targets { await generateAutomaticReply(to: thought, persona: persona) } }
    }

    private func generateAutomaticReply(to thought: Thought, persona: Persona) async {
        guard let aiReplyRepository, let thoughtRepository else { return }
        do {
            let preview = try makeAIReplyPreview(to: thought, persona: persona, userRequest: "メンションされた会話の流れを踏まえて自然に返信してください")
            let generated = try await GenerateAIThoughtReply(client: summaryClient, repository: aiReplyRepository, usageRepository: aiUsageRepository)(preview: preview)
            timeline = try ThoughtTimeline(repository: thoughtRepository); thoughts = timeline?.thoughts ?? []
            refreshTags(for: thoughts.map(\.id)); refreshAuthors(for: thoughts.map(\.id)); refreshMentions(for: thoughts.map(\.id)); refreshReplyRelations(for: thoughts.map(\.id))
            automaticRepliesByTargetID[thought.id]?[persona.id] = nil
            if automaticRepliesByTargetID[thought.id]?.isEmpty == true { automaticRepliesByTargetID[thought.id] = nil }
            loadConversation(for: thought.id)
        } catch AIPostError.duplicateReply {
            automaticRepliesByTargetID[thought.id]?[persona.id] = nil
        } catch {
            automaticRepliesByTargetID[thought.id, default: [:]][persona.id] = .failed(error.localizedDescription)
        }
    }

    func retryAutomaticReply(to thought: Thought, personaID: UUID) {
        startAutomaticReplies(to: thought, personaIDs: [personaID])
    }

    func cancelAIReplyPreview() { aiReplyPreview = nil; aiReplyDraft = nil }

    func generateAIReply(from preview: AIThoughtReplyPreview) async {
        guard let aiReplyRepository else { aiReplyError = "AI返信の保存先を利用できません。"; return }
        guard !isGeneratingAIReply else { return }
        isGeneratingAIReply = true; aiReplyError = nil; defer { isGeneratingAIReply = false }
        do {
            aiReplyDraft = try await GenerateAIThoughtReply(client: summaryClient, repository: aiReplyRepository, usageRepository: aiUsageRepository).generate(preview: preview)
        } catch ReviewSummaryError.stalePreview { aiReplyError = "確認後に会話内容が変更されたため送信しませんでした。もう一度内容を確認してください。" }
        catch { aiReplyError = error.localizedDescription }
    }

    @discardableResult
    func publishAIReply(_ draft: AIThoughtReplyDraft) -> Bool {
        guard let aiReplyRepository, let thoughtRepository else { aiReplyError = "AI返信の保存先を利用できません。"; return false }
        do {
            let thought = try GenerateAIThoughtReply(client: summaryClient, repository: aiReplyRepository, usageRepository: aiUsageRepository).publish(draft: draft)
            timeline = try ThoughtTimeline(repository: thoughtRepository); thoughts = timeline?.thoughts ?? []
            refreshTags(for: thoughts.map(\.id)); refreshAuthors(for: thoughts.map(\.id)); refreshMentions(for: thoughts.map(\.id)); refreshReplyRelations(for: thoughts.map(\.id)); aiReplyPreview = nil; aiReplyDraft = nil
            loadAIReplies(to: draft.preview.targetThought.id)
            handlePostSuccess(thought)
            return true
        } catch { aiReplyError = error.localizedDescription; return false }
    }

    func generateAndPublishAIReply(from preview: AIThoughtReplyPreview) async -> Bool {
        if aiReplyDraft?.preview.id != preview.id {
            await generateAIReply(from: preview)
        }
        guard let draft = aiReplyDraft, draft.preview.id == preview.id else { return false }
        return publishAIReply(draft)
    }

    func loadAIReplies(to thoughtID: UUID) {
        guard let aiReplyRepository else { return }
        do { let replies = try aiReplyRepository.fetchAIReplies(to: thoughtID); aiRepliesByTargetID[thoughtID] = replies; refreshAuthors(for: replies.map(\.id)) }
        catch { aiReplyError = "AI返信を読み込めませんでした。" }
    }

    private func refreshReplyRelations(for ids: [UUID]) {
        guard let aiReplyRepository, let thoughtRepository else { return }
        guard let values = try? aiReplyRepository.fetchReplyTargets(for: ids) else { return }
        replyTargetIDsByThoughtID.merge(values) { _, new in new }
        let targetIDs = Set(values.values)
        refreshAuthors(for: Array(targetIDs))
        for (replyID, targetID) in values {
            if let target = try? thoughtRepository.fetchByID(targetID) {
                replyTargetsByThoughtID[replyID] = target
            }
        }
    }

    private func refreshAuthors(for ids: [UUID]) {
        guard let personaRepository else { return }
        if let values = try? personaRepository.fetchPersonas(for: ids) { personasByThoughtID.merge(values) { _, new in new } }
    }
    private func refreshMentions(for ids: [UUID]) {
        guard let mentionRepository else { return }
        if let values = try? mentionRepository.fetchMentionedPersonas(for: ids) { mentionedPersonasByThoughtID.merge(values) { _, new in new } }
        if let values = try? mentionRepository.fetchMentions(for: ids) { mentionsByThoughtID.merge(values) { _, new in new } }
    }

    func incomingMentionAndReplyThoughts() -> [Thought] {
        thoughts.filter { thought in
            if !(mentionsByThoughtID[thought.id] ?? []).isEmpty { return true }
            guard let targetID = replyTargetIDsByThoughtID[thought.id] else { return false }
            return personasByThoughtID[targetID] != nil
        }
    }

    func isHumanAuthored(_ thought: Thought) -> Bool {
        personasByThoughtID[thought.id]?.kind == .human
    }

    func loadDailySummary(for day: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: day)
        do {
            dailySummary = try dailySummaryRepository?.fetchDailySummary(dayStart: start)
            if let thoughtRepository, let tagRepository, let relationRepository, let personaRepository,
               let preview = try? PrepareDailySummary(thoughts: thoughtRepository, tags: tagRepository, relations: relationRepository, authors: personaRepository)(day: day, calendar: calendar) {
                dailySummaryDayThoughts = preview.thoughts
                dailySummaryDayTags = preview.existingTags
                dailySummaryDayContinuationCount = preview.continuationCount
            } else {
                dailySummaryDayThoughts = []
                dailySummaryDayTags = []
                dailySummaryDayContinuationCount = 0
            }
            dailySummaryError = nil
        }
        catch { dailySummary = nil; dailySummaryError = "Daily Summaryを読み込めませんでした。" }
    }

    func prepareDailySummary(for day: Date, calendar: Calendar = .current) {
        guard let thoughtRepository, let tagRepository, let relationRepository, let personaRepository else { dailySummaryError = "要約対象を読み込めませんでした。"; return }
        do {
            dailySummaryPreview = try PrepareDailySummary(thoughts: thoughtRepository, tags: tagRepository, relations: relationRepository, authors: personaRepository)(day: day, calendar: calendar)
            dailySummaryError = nil
        } catch ReviewSummaryError.noThoughts { dailySummaryPreview = nil; dailySummaryError = "Thoughtが0件の日は要約できません。" }
        catch { dailySummaryPreview = nil; dailySummaryError = "要約対象を準備できませんでした。" }
    }

    func cancelDailySummaryPreview() { dailySummaryPreview = nil }

    func generateDailySummary(from preview: DailySummaryPreview) async {
        guard let thoughtRepository, let dailySummaryRepository else { dailySummaryError = "保存先を利用できません。"; return }
        isGeneratingDailySummary = true; dailySummaryError = nil
        defer { isGeneratingDailySummary = false }
        do {
            guard let tagRepository, let relationRepository, let personaRepository else { throw ReviewSummaryError.stalePreview }
            let current = try PrepareDailySummary(thoughts: thoughtRepository, tags: tagRepository, relations: relationRepository, authors: personaRepository)(day: preview.interval.start)
            guard current.inputs == preview.inputs && current.relations == preview.relations && current.existingTags == preview.existingTags && current.continuationCount == preview.continuationCount else { throw ReviewSummaryError.stalePreview }
            let value = try await GenerateDailySummary(client: summaryClient, repository: dailySummaryRepository, usageRepository: aiUsageRepository)(preview: preview)
            dailySummary = value
            dailySummaries.removeAll { $0.dayStart == value.dayStart }
            dailySummaries.append(value)
            dailySummaries.sort {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString > $1.id.uuidString
                    : $0.createdAt > $1.createdAt
            }
            dailySummaryPreview = nil
        } catch ReviewSummaryError.stalePreview { dailySummaryError = "確認後にThoughtが変更されたため送信しませんでした。" }
        catch let error as ReviewSummaryServiceError { dailySummaryError = error.localizedDescription }
        catch { dailySummaryError = "Daily Summaryを作成できませんでした。応答形式または通信状態を確認してください。" }
    }

    func loadWeeklyReview(interval: DateInterval) {
        do {
            weeklySummary = try weeklyReviewRepository?.fetchWeeklySummary(weekStart: interval.start)
            weeklyPlan = try weeklySummary.flatMap { try weeklyReviewRepository?.fetchWeeklyPlan(targetWeekStart: $0.weekEnd) }
            weeklyReviewError = nil
        } catch { weeklySummary = nil; weeklyPlan = nil; weeklyReviewError = "週間振り返りを読み込めませんでした。" }
    }

    func prepareWeeklySummary(interval: DateInterval, calendar: Calendar = .current) {
        guard let thoughtRepository else { weeklyReviewError = "要約対象を読み込めませんでした。"; return }
        do {
            weeklySummaryPreview = try PrepareWeeklySummary(repository: thoughtRepository)(interval: interval, calendar: calendar)
            weeklyReviewError = nil
        } catch ReviewSummaryError.noThoughts { weeklySummaryPreview = nil; weeklyReviewError = "Human Thoughtが0件の週は要約できません。" }
        catch { weeklySummaryPreview = nil; weeklyReviewError = "週間要約の対象を準備できませんでした。" }
    }

    func generateWeeklySummary(from preview: WeeklySummaryPreview, calendar: Calendar = .current) async {
        guard let thoughtRepository, let weeklyReviewRepository else { weeklyReviewError = "保存先を利用できません。"; return }
        isGeneratingWeeklyReview = true; weeklyReviewError = nil
        defer { isGeneratingWeeklyReview = false }
        do {
            let current = try PrepareWeeklySummary(repository: thoughtRepository)(interval: preview.interval, calendar: calendar)
            guard current.thoughts == preview.thoughts else { throw ReviewSummaryError.stalePreview }
            let value = try await GenerateWeeklySummary(client: summaryClient, repository: weeklyReviewRepository, usageRepository: aiUsageRepository)(preview: preview)
            weeklySummary = value; weeklySummaryPreview = nil; weeklyPlanDraft = nil
            weeklySummaries.removeAll { $0.weekStart == value.weekStart }; weeklySummaries.append(value); weeklySummaries.sort { $0.weekStart > $1.weekStart }
        } catch ReviewSummaryError.stalePreview { weeklyReviewError = "確認後にThoughtが変更されたため送信しませんでした。" }
        catch let error as ReviewSummaryServiceError { weeklyReviewError = error.localizedDescription }
        catch { weeklyReviewError = "週間サマリーを作成できませんでした。応答形式または通信状態を確認してください。" }
    }

    func generateWeeklyPlanDraft(from summary: WeeklySummary) async {
        isGeneratingWeeklyReview = true; weeklyReviewError = nil
        defer { isGeneratingWeeklyReview = false }
        do { weeklyPlanDraft = try await GenerateWeeklyPlanDraft(client: summaryClient, usageRepository: aiUsageRepository)(summary: summary) }
        catch let error as ReviewSummaryServiceError { weeklyReviewError = error.localizedDescription }
        catch { weeklyReviewError = "次週プランの候補を作成できませんでした。" }
    }

    func saveWeeklyPlan(draft: WeeklyPlanDraft, content: WeeklyPlanContent) {
        guard let weeklyReviewRepository else { weeklyReviewError = "保存先を利用できません。"; return }
        do {
            let now = Date()
            let value = WeeklyPlan(targetWeekStart: draft.targetInterval.start, targetWeekEnd: draft.targetInterval.end, sourceSummaryID: draft.sourceSummary.id, content: content, createdAt: weeklyPlan?.createdAt ?? now, updatedAt: now, provider: draft.provider, model: draft.model, promptVersion: WeeklyPlanPrompt.version)
            try weeklyReviewRepository.saveWeeklyPlan(value); weeklyPlan = value; weeklyPlanDraft = nil; weeklyReviewError = nil
        } catch { weeklyReviewError = "次週プランを保存できませんでした。" }
    }

    func loadAnalytics(containing date: Date = Date(), calendar: Calendar = .current) {
        guard let analyticsRepository else {
            analytics = nil
            errorMessage = "ローカル分析を読み込めませんでした。"
            return
        }
        isLoadingAnalytics = true
        defer { isLoadingAnalytics = false }
        do {
            analytics = try LoadThoughtAnalytics(
                repository: analyticsRepository,
                calendar: calendar
            )(containing: date)
        } catch {
            analytics = nil
            errorMessage = "ローカル分析を読み込めませんでした。保存済みデータは変更されていません。"
        }
    }

    func export(_ format: ThoughtExportFormat) {
        guard let exporter else {
            errorMessage = "ThoughtをExportできませんでした。"
            return
        }
        do {
            exportArtifact = ExportArtifact(url: try exporter.write(format))
        } catch {
            errorMessage = "ThoughtをExportできませんでした。入力内容と保存済みデータは変更されていません。"
        }
    }

    func sharingFailed() {
        errorMessage = "共有を完了できませんでした。Exportファイルは変更されていません。"
    }

    var remainingCharacterCount: Int {
        ThoughtDraft.characterLimit - draft.count
    }

    var canPost: Bool {
        ThoughtDraft.validBody(from: draft) != nil
    }

    func updateDraft(_ value: String) {
        draft = ThoughtDraft.limited(value)
        if let selectedMentionPersona, mentionRange(for: selectedMentionPersona, in: draft) == nil {
            self.selectedMentionPersona = nil
        }
    }

    var mentionSuggestions: [Persona] {
        guard let query = trailingMentionQuery(in: draft) else { return [] }
        return personas.filter { query.isEmpty || $0.handle.hasPrefix(query.lowercased()) }.prefix(6).map { $0 }
    }

    func insertMention(_ persona: Persona) {
        let token = "@\(persona.handle)"
        let updatedDraft: String
        if let selectedMentionPersona, let range = mentionRange(for: selectedMentionPersona, in: draft) {
            updatedDraft = draft.replacingCharacters(in: range, with: token)
        } else if let range = draft.range(of: "@[A-Za-z0-9_]*$", options: .regularExpression) {
            updatedDraft = draft.replacingCharacters(in: range, with: "\(token) ")
        } else {
            updatedDraft = draft.isEmpty ? "\(token) " : "\(token) \(draft)"
        }
        updateDraft(updatedDraft)
        selectedMentionPersona = persona
    }

    func removeSelectedMention() {
        guard let persona = selectedMentionPersona else { return }
        if let range = mentionRange(for: persona, in: draft) {
            var removalRange = range
            if removalRange.upperBound < draft.endIndex, draft[removalRange.upperBound] == " " {
                removalRange = removalRange.lowerBound..<draft.index(after: removalRange.upperBound)
            }
            draft.removeSubrange(removalRange)
        }
        selectedMentionPersona = nil
    }

    private func trailingMentionQuery(in body: String) -> String? {
        guard let range = body.range(of: "@[A-Za-z0-9_]*$", options: .regularExpression) else { return nil }
        return String(body[range].dropFirst())
    }

    private func mentionRange(for persona: Persona, in body: String) -> Range<String.Index>? {
        let pattern = "(?i)(?<![A-Za-z0-9_])@\(NSRegularExpression.escapedPattern(for: persona.handle))(?![A-Za-z0-9_])"
        return body.range(of: pattern, options: .regularExpression)
    }

    private func resolvedMentions(in thought: Thought) -> [ThoughtMention] {
        let text = thought.body as NSString
        return personas.flatMap { persona -> [ThoughtMention] in
            let pattern = "(?i)(?<![A-Za-z0-9_])@\(NSRegularExpression.escapedPattern(for: persona.handle))(?![A-Za-z0-9_])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: thought.body, range: NSRange(location: 0, length: text.length)).map { .init(thoughtID: thought.id, personaID: persona.id, handleSnapshot: persona.handle, rangeLocation: $0.range.location, rangeLength: $0.range.length, createdAt: thought.createdAt) }
        }.sorted { $0.rangeLocation < $1.rangeLocation }
    }

    var canPostContinuation: Bool {
        ThoughtDraft.validBody(from: continuationDraft) != nil
    }

    func updateContinuationDraft(_ value: String) {
        continuationDraft = ThoughtDraft.limited(value)
    }

    func knowledgeDraftInput(for thought: Thought) -> KnowledgeDraftInput? {
        guard let author = personasByThoughtID[thought.id] else { return nil }
        if author.kind == .human {
            return KnowledgeDraftInput(
                source: .manual,
                sourceContent: "Human statement:\n\(thought.body)",
                context: "Human: \(author.displayName)\nThought created at: \(thought.createdAt.formatted())",
                provenance: .init(sourceID: thought.id.uuidString, journalDate: thought.createdAt)
            )
        }
        var generation: AIPostGeneration?
        if let aiReplyRepository { generation = try? aiReplyRepository.fetchAIPostGeneration(for: thought.id) }
        let source: KnowledgeDraftSource = generation?.kind == .reply ? .aiReply : .personaPost
        let context = generation.map { "Human request: \($0.userRequest)\nAI persona: \(author.displayName)" }
        return KnowledgeDraftInput(source: source, sourceContent: "AI statement:\n\(thought.body)", context: context, provenance: .init(sourceID: thought.id.uuidString, personaID: author.id, conversationID: generation?.replyTargetThoughtID, journalDate: thought.createdAt))
    }

    func knowledgeDraftInput(for summary: DailySummary) -> KnowledgeDraftInput {
        let content = summary.content
        let sections = [
            "Overview:\n\(content.overview)",
            "Themes:\n\(content.themes.joined(separator: "\n"))",
            "Deep dives:\n\(content.deepDives.joined(separator: "\n"))",
            "Carry overs:\n\(content.carryOvers.joined(separator: "\n"))",
            "Recurring patterns (observations only):\n\(content.thoughtPatterns.joined(separator: "\n"))"
        ]
        return .init(source: .dailySummary, sourceContent: sections.joined(separator: "\n\n"), context: "Daily Summary generated at \(summary.createdAt.formatted())", provenance: .init(sourceID: summary.id.uuidString, dailySummaryDate: summary.dayStart))
    }

    func journalDraftInput(for day: Date) -> KnowledgeDraftInput? {
        guard !dailySummaryDayThoughts.isEmpty else { return nil }
        let content = dailySummaryDayThoughts.sorted { $0.createdAt < $1.createdAt }.map {
            "[\($0.createdAt.formatted(date: .omitted, time: .shortened))] \($0.body)"
        }.joined(separator: "\n")
        return .init(
            source: .dailyThoughts,
            sourceContent: content,
            context: "\(day.formatted(date: .long, time: .omitted))のHuman Thoughtから、自分の日記を作る。",
            provenance: .init(journalDate: Calendar.current.startOfDay(for: day))
        )
    }


    func generateKnowledgeDraft(input: KnowledgeDraftInput, type: KnowledgeDraftType) async {
        guard !isGeneratingKnowledgeDraft else { return }
        isGeneratingKnowledgeDraft = true; knowledgeDraftError = nil; knowledgeDraftMessage = nil
        defer { isGeneratingKnowledgeDraft = false }
        let related = externalBrainManager.relatedKnowledge(query: input.sourceContent)
        do { let value = try await GenerateKnowledgeDraft(client: summaryClient, usageRepository: aiUsageRepository)(input: input, type: type, related: related, provider: knowledgeDraftAIProvider); try knowledgeDraftRepository?.saveKnowledgeDraft(value); knowledgeDraft = value; loadKnowledge() }
        catch { knowledgeDraftError = error.localizedDescription }
    }

    func saveKnowledgeDraft(_ draft: KnowledgeDraft) async {
        guard !isSavingKnowledgeDraft else { return }
        isSavingKnowledgeDraft = true; knowledgeDraftError = nil; knowledgeDraftMessage = nil
        defer { isSavingKnowledgeDraft = false }
        do {
            let path = try await externalBrainManager.saveDraft(draft)
            var saved = draft; saved.savedPath = path; saved.syncStatus = .synced; saved.updatedAt = Date(); try knowledgeDraftRepository?.saveKnowledgeDraft(saved); knowledgeDraft = saved; loadKnowledge()
            knowledgeDraftMessage = "保存しました\n\(path)"
        } catch { var failed=draft; failed.syncStatus = .failed; failed.updatedAt=Date(); try? knowledgeDraftRepository?.saveKnowledgeDraft(failed); knowledgeDraft = failed; knowledgeDraftError = error.localizedDescription; loadKnowledge() }
    }

    func cancelKnowledgeDraft() { knowledgeDraft = nil; knowledgeDraftError = nil; knowledgeDraftMessage = nil }
    func loadKnowledge(search: String = "") { do { knowledgeDrafts = search.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? (try knowledgeDraftRepository?.fetchKnowledgeDrafts() ?? []) : (try knowledgeDraftRepository?.searchKnowledgeDrafts(query:search) ?? []); knowledgeDocuments = try knowledgeDraftRepository?.fetchKnowledgeDocuments() ?? []; knowledgeLifecycleEvents = try knowledgeLifecycleRepository?.fetchKnowledgeLifecycleEvents() ?? []; knowledgeQualityCandidates = try knowledgeDraftRepository?.fetchKnowledgeQualityCandidates() ?? [] } catch { knowledgeDraftError = "Knowledgeを読み込めませんでした。" } }
    func updateKnowledgeDraft(_ draft: KnowledgeDraft) { var value=draft; value.updatedAt=Date(); if value.savedPath != nil { value.syncStatus = .localOnly }; do { try knowledgeDraftRepository?.saveKnowledgeDraft(value); knowledgeDraft=value; loadKnowledge() } catch { knowledgeDraftError="Draftを保存できませんでした。" } }
    func deleteKnowledgeDraft(_ draft: KnowledgeDraft) async -> Bool {
        guard !isDeletingKnowledgeDraft, draft.reviewStatus != .promoted else { return false }
        isDeletingKnowledgeDraft = true; knowledgeDraftError = nil; knowledgeDraftMessage = nil
        defer { isDeletingKnowledgeDraft = false }
        do {
            if let path = draft.savedPath { try await externalBrainManager.deleteDraft(path: path) }
            try knowledgeDraftRepository?.deleteKnowledgeDraft(id: draft.id)
            if knowledgeDraft?.id == draft.id { knowledgeDraft = nil }
            loadKnowledge(); knowledgeDraftMessage = draft.savedPath == nil ? "ローカルのDraftを削除しました。" : "GitHubとローカルからDraftを削除しました。"
            return true
        } catch {
            knowledgeDraftError = error.localizedDescription
            loadKnowledge()
            return false
        }
    }
    func reviewKnowledgeDraft(_ draft: KnowledgeDraft, status: KnowledgeDraftReviewStatus) { do { let value=try KnowledgeDraftTransition.applying(status,to:draft); try knowledgeDraftRepository?.saveKnowledgeDraft(value); let event: KnowledgeLifecycleEventType?; switch status { case .approved: event = .approved; case .rejected: event = .rejected; default: event = nil }; if let event { try? knowledgeLifecycleRepository?.saveKnowledgeLifecycleEvent(.init(draftID:draft.id,type:event,source:draft.source)) }; knowledgeDraft=value; loadKnowledge() } catch { knowledgeDraftError=error.localizedDescription } }
    func promoteKnowledgeDraft(_ draft: KnowledgeDraft) async { let path=KnowledgeDocumentPath.targetPath(date:Date(),title:draft.title); do { let sha=try await externalBrainManager.promote(draft,path:path); var promoted=try KnowledgeDraftTransition.applying(.promoted,to:draft); promoted.knowledgePath=path; promoted.knowledgeSHA=sha; promoted.syncStatus = .synced; let document=KnowledgeDocument(draftID:draft.id,title:draft.title,path:path,sha:sha,source:draft.source,tags:draft.tags,markdown:draft.markdown.replacingOccurrences(of:"status: draft",with:"status: active"),createdAt:promoted.promotedAt ?? Date(),updatedAt:promoted.promotedAt ?? Date()); try knowledgeDraftRepository?.savePromotedKnowledge(draft:promoted,document:document); try? knowledgeLifecycleRepository?.saveKnowledgeLifecycleEvent(.init(draftID:draft.id,type:.promoted,source:draft.source)); knowledgeDraft=promoted; knowledgeDraftMessage="Promoteしました\n\(path)"; loadKnowledge() } catch { var failed=draft; failed.syncStatus = .failed; failed.updatedAt=Date(); try? knowledgeDraftRepository?.saveKnowledgeDraft(failed); knowledgeDraft=failed; knowledgeDraftError=error.localizedDescription; loadKnowledge() } }
    private func trackKnowledgeRetrieval(_ context:ExternalBrainContext?) { let paths=context?.chunks.map(\.documentPath) ?? []; guard !paths.isEmpty else{return}; try? knowledgeDraftRepository?.recordKnowledgeRetrieval(paths:paths,at:Date()) }
    func analyzeKnowledgeQuality() { do { let candidates=KnowledgeQualityAnalyzer.analyze(try knowledgeDraftRepository?.fetchKnowledgeDocuments() ?? []); try knowledgeDraftRepository?.replaceKnowledgeQualityCandidates(candidates); loadKnowledge(); knowledgeDraftMessage="ローカル解析を完了しました。AI APIは使用していません。" } catch { knowledgeDraftError="Knowledge Qualityを解析できませんでした。" } }
    func dismissQualityCandidate(_ candidate:KnowledgeQualityCandidate) { var value=candidate; value.status = .dismissed; value.resolvedAt=Date(); do { try knowledgeDraftRepository?.saveKnowledgeQualityCandidate(value); loadKnowledge() } catch { knowledgeDraftError="候補をDismissできませんでした。" } }
    func createMergeDraft(_ candidate:KnowledgeQualityCandidate) { guard let relatedID=candidate.relatedKnowledgeID,let a=knowledgeDocuments.first(where:{$0.id==candidate.knowledgeID}),let b=knowledgeDocuments.first(where:{$0.id==relatedID}) else{return}; let body="# Merge Draft\n\n## \(a.title)\n\(MarkdownFrontMatterParser.parse(a.markdown).body)\n\n## \(b.title)\n\(MarkdownFrontMatterParser.parse(b.markdown).body)"; let draft=KnowledgeDraft(title:"Merge: \(a.title)",type:.knowledge,tags:Array(Set(a.tags+b.tags)).sorted(),source:.mergeDraft,body:body,provenance:.init(sourceKnowledgeIDs:[a.id,b.id],sourcePaths:[a.path,b.path],mergeReason:candidate.reason)); do { try knowledgeDraftRepository?.saveKnowledgeDraft(draft); var resolved=candidate; resolved.status = .resolved; resolved.resolvedAt=Date(); try knowledgeDraftRepository?.saveKnowledgeQualityCandidate(resolved); knowledgeDraft=draft; loadKnowledge(); knowledgeDraftMessage="Merge Draftを作成しました。元のKnowledgeは変更していません。" } catch { knowledgeDraftError="Merge Draftを作成できませんでした。" } }
    func archiveKnowledge(_ document:KnowledgeDocument) { guard document.status == .active else{return}; var value=document; value.status = .archived; value.archivedAt=Date(); do { try knowledgeDraftRepository?.saveKnowledgeDocument(value); externalBrainManager.excludeFromRetrieval(path:value.path); loadKnowledge() } catch { knowledgeDraftError="Archiveできませんでした。" } }
    func supersedeKnowledge(_ old:KnowledgeDocument,by new:KnowledgeDocument) { guard old.status == .active,new.status == .active,old.id != new.id else{return}; var value=old; value.status = .superseded; value.supersededByKnowledgeID=new.id; value.supersededAt=Date(); do { try knowledgeDraftRepository?.saveKnowledgeDocument(value); externalBrainManager.excludeFromRetrieval(path:value.path); loadKnowledge() } catch { knowledgeDraftError="Supersedeできませんでした。" } }

    func loadAIUsageAnalytics(period: AIAPIUsagePeriod, now: Date = Date(), calendar: Calendar = .current) {
        guard let aiUsageAnalyticsRepository else { aiUsageAnalyticsError = "AI使用状況を読み込めませんでした。"; return }
        isLoadingAIUsageAnalytics = true; defer { isLoadingAIUsageAnalytics = false }
        do {
            aiUsageAnalytics = try LoadAIAPIUsageAnalytics(repository: aiUsageAnalyticsRepository, personas: personaRepository, calendar: calendar)(period: period, now: now)
            aiUsageAnalyticsError = nil
        } catch { aiUsageAnalytics = nil; aiUsageAnalyticsError = "AI使用状況を読み込めませんでした。利用履歴は変更されていません。" }
    }

    func updateHumanReplyDraft(_ value: String) { humanReplyDraft = ThoughtDraft.limited(value) }
    var canPostHumanReply: Bool { ThoughtDraft.validBody(from: humanReplyDraft) != nil }

    @discardableResult func postHumanReply(to target: Thought) -> Thought? {
        guard let humanReplyRepository, let thoughtRepository else { errorMessage = "返信を保存できませんでした。"; return nil }
        let targetAuthor = personasByThoughtID[target.id]
        let mentionID = targetAuthor?.deletedAt == nil ? targetAuthor?.id : nil
        do {
            guard let reply = try humanReplyRepository.createHumanReply(body: humanReplyDraft, targetThoughtID: target.id, mentionedPersonaID: mentionID, now: Date(), thoughtID: UUID(), relationID: UUID()) else { return nil }
            timeline = try ThoughtTimeline(repository: thoughtRepository); thoughts = timeline?.thoughts ?? []; humanReplyDraft = ""
            refreshAuthors(for: thoughts.map(\.id)); refreshMentions(for: thoughts.map(\.id)); refreshReplyRelations(for: thoughts.map(\.id)); loadAIReplies(to: target.id)
            handlePostSuccess(reply)
            let aiMentionIDs = (mentionsByThoughtID[reply.id] ?? []).compactMap { mention in
                personas.first(where: { $0.id == mention.personaID && $0.kind == .ai })?.id
            }
            startAutomaticReplies(to: reply, personaIDs: aiMentionIDs)
            return reply
        } catch {
#if DEBUG
            let diagnostic = String(reflecting: error)
            print("Human reply persistence failed: \(diagnostic)")
            errorMessage = "返信を保存できませんでした。入力内容は残しています。\nDebug: \(diagnostic)"
#else
            errorMessage = "返信を保存できませんでした。入力内容は残しています。"
#endif
            return nil
        }
    }

    func loadHistory(for thoughtID: UUID) {
        guard let thoughtRepository, let relationRepository else {
            errorMessage = "Thought Historyを読み込めませんでした。"
            return
        }
        do {
            let thread = try LoadConversationThread(thoughts: thoughtRepository, relations: relationRepository)(containing: thoughtID)
            conversationThread = thread
            history = thread.nodes.map { ThoughtHistoryEntry(thought: $0.thought, depth: $0.depth) }
            historyCurrentID = thoughtID
            refreshTags(for: history.map(\.id))
            refreshAuthors(for: history.map(\.id))
        } catch {
            errorMessage = "Thought Historyを読み込めませんでした。"
        }
    }

    func loadConversation(for thoughtID: UUID) { loadHistory(for: thoughtID) }

    func search(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSearchQuery = !normalized.isEmpty
        guard hasSearchQuery else {
            searchResults = []
            return
        }
        guard let thoughtRepository else {
            searchResults = []
            errorMessage = "Thoughtを検索できませんでした。"
            return
        }
        do {
            searchResults = try thoughtRepository.search(query: normalized)
            refreshTags(for: searchResults.map(\.id))
        } catch {
            searchResults = []
            errorMessage = "Thoughtを検索できませんでした。保存済みデータは変更されていません。"
        }
    }

    func clearSearch() {
        hasSearchQuery = false
        searchResults = []
    }

    var hasMoreTimelineThoughts: Bool { timeline?.hasMore == true }

    func loadMoreTimelineThoughts() {
        guard !isLoadingTimelinePage, var timeline, timeline.hasMore else { return }
        isLoadingTimelinePage = true
        timelinePaginationError = nil
        defer { isLoadingTimelinePage = false }
        do {
            let appended = try timeline.loadMore()
            self.timeline = timeline
            thoughts = timeline.thoughts
            let ids = appended.map(\.id)
            refreshTags(for: ids)
            refreshAuthors(for: ids)
            refreshMentions(for: ids)
            refreshReplyRelations(for: ids)
        } catch {
            timelinePaginationError = "過去のThoughtを読み込めませんでした。"
        }
    }

    func refreshTags(for thoughtIDs: [UUID]) {
        guard let tagRepository else { return }
        do {
            for id in thoughtIDs { tagsByThoughtID[id] = try tagRepository.fetchTags(for: id) }
        } catch { errorMessage = "タグを読み込めませんでした。" }
    }

    func loadAllTags() {
        guard let tagRepository else { return }
        do { allTags = try tagRepository.fetchAllTags() }
        catch { errorMessage = "タグ一覧を読み込めませんでした。" }
    }

    func loadThoughts(taggedWith tag: ThoughtTag) {
        guard let tagRepository else { return }
        do {
            taggedThoughts = try tagRepository.fetchThoughts(taggedWith: tag.id)
            refreshTags(for: taggedThoughts.map(\.id))
        } catch {
            taggedThoughts = []
            errorMessage = "タグのThoughtを読み込めませんでした。"
        }
    }

    func addTag(named name: String, to thoughtID: UUID) {
        guard let tagRepository else { return }
        do {
            switch try tagRepository.addTag(named: name, to: thoughtID) {
            case .added:
                tagMessage = nil
                refreshTags(for: [thoughtID])
                loadAllTags()
            case .alreadyAttached:
                tagMessage = "このタグはすでに付いています。"
            case .invalidName:
                tagMessage = "空のタグは追加できません。"
            }
        } catch { tagMessage = "タグを追加できませんでした。" }
    }

    func removeTag(_ tag: ThoughtTag, from thoughtID: UUID) {
        guard let tagRepository else { return }
        do {
            _ = try tagRepository.removeTag(id: tag.id, from: thoughtID)
            tagMessage = nil
            refreshTags(for: [thoughtID])
            loadAllTags()
        } catch { tagMessage = "タグを削除できませんでした。" }
    }

    @discardableResult
    func postContinuation(parentThoughtID: UUID) -> Thought? {
        guard let continuationRepository, let thoughtRepository else {
            errorMessage = "保存先を利用できないため続きを投稿できません。入力内容は残しています。"
            return nil
        }
        do {
            guard let thought = try continuationRepository.createContinuation(
                body: continuationDraft,
                parentThoughtID: parentThoughtID
            ) else { return nil }
            timeline = try ThoughtTimeline(repository: thoughtRepository)
            thoughts = timeline?.thoughts ?? []
            refreshTags(for: thoughts.map(\.id))
            refreshAuthors(for: thoughts.map(\.id))
            continuationDraft = ""
            loadHistory(for: thought.id)
            handlePostSuccess(thought)
            return thought
        } catch {
            errorMessage = "続きを保存できませんでした。入力内容は残しています。"
            return nil
        }
    }

    @discardableResult
    func post() -> Bool {
        guard post(draft, mentioning: selectedMentionPersona) else { return false }
        draft = ""
        selectedMentionPersona = nil
        return true
    }

    /// Posting boundary shared by the Timeline composer and mention handling.
    @discardableResult
    func post(_ body: String, mentioning persona: Persona? = nil) -> Bool {
        guard !isPosting else { return false }
        guard var timeline, let thoughtRepository else {
            errorMessage = "保存先を利用できないため投稿できません。入力内容は残しています。"
            return false
        }
        isPosting = true
        defer { isPosting = false }
        do {
            let validBody = ThoughtDraft.validBody(from: body)
            var postedThoughtID: UUID?
            if persona != nil || (validBody.map { !resolvedMentions(in: Thought(body: $0)).isEmpty } ?? false) {
                guard let mentionRepository, let validBody = ThoughtDraft.validBody(from: body) else { return false }
                let thought = Thought(body: validBody)
                var mentions = resolvedMentions(in: thought)
                if let persona, !mentions.contains(where: { $0.personaID == persona.id }) {
                    mentions.append(.init(thoughtID: thought.id, personaID: persona.id, handleSnapshot: persona.handle, rangeLocation: 0, rangeLength: 0, createdAt: thought.createdAt))
                }
                try mentionRepository.create(thought, authorPersonaID: Persona.defaultHumanID, mentions: mentions)
                timeline = try ThoughtTimeline(repository: thoughtRepository)
                postedThoughtID = thought.id
            } else {
                guard let thought = try timeline.post(body) else { return false }
                postedThoughtID = thought.id
            }
            self.timeline = timeline; thoughts = timeline.thoughts
            refreshTags(for: thoughts.map(\.id))
            refreshAuthors(for: thoughts.map(\.id))
            refreshMentions(for: thoughts.map(\.id))
            refreshReplyRelations(for: thoughts.map(\.id))
            if let postedThoughtID, let postedThought = thoughts.first(where: { $0.id == postedThoughtID }) {
                handlePostSuccess(postedThought, resetsNavigation: false)
                let aiMentionIDs = (mentionsByThoughtID[postedThought.id] ?? []).compactMap { mention in
                    personas.first(where: { $0.id == mention.personaID && $0.kind == .ai })?.id
                }
                startAutomaticReplies(to: postedThought, personaIDs: aiMentionIDs)
            }
            return true
        } catch {
            errorMessage = "Thoughtを保存できませんでした。"
            return false
        }
    }

    func requestDeletion(of thought: Thought) {
        deletionCandidate = thought
    }

    func cancelDeletion() {
        deletionCandidate = nil
    }

    func confirmDeletion() {
        guard let candidate = deletionCandidate, var timeline else { return }
        do {
            _ = try timeline.delete(id: candidate.id)
            self.timeline = timeline
            thoughts = timeline.thoughts
            refreshTags(for: thoughts.map(\.id))
            loadAllTags()
            deletionCandidate = nil
            if let historyCurrentID { loadHistory(for: historyCurrentID) }
        } catch {
            errorMessage = "Thoughtを削除できませんでした。"
        }
    }
}
