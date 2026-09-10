import Foundation

/// The canonical, human-authored text. AI-derived metadata belongs in separate models.
public struct Thought: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let body: String
    public let createdAt: Date
    public let updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}

public enum PersonaKind: String, Codable, Sendable {
    case human
    case ai
}

public struct Persona: Identifiable, Equatable, Sendable {
    public static let defaultHumanID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public let id: UUID
    public var displayName: String
    public var accountID: String
    public var biography: String
    public let kind: PersonaKind
    public var iconData: Data?
    public var iconMIMEType: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), displayName: String, accountID: String = "", biography: String = "", kind: PersonaKind, iconData: Data? = nil, iconMIMEType: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.accountID = accountID
        self.biography = biography
        self.kind = kind
        self.iconData = iconData
        self.iconMIMEType = iconMIMEType
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}

public enum PersonaProfileValidationError: Error, LocalizedError, Equatable {
    case invalidNickname, invalidAccountID, reservedAccountID
    public var errorDescription: String? {
        switch self {
        case .invalidNickname: "ニックネームは1〜40文字で入力してください。"
        case .invalidAccountID: "アカウントIDは英小文字で始まる3〜24文字の英数字と_で入力してください。"
        case .reservedAccountID: "このアカウントIDは使用できません。"
        }
    }
}

public enum PersonaProfile {
    public static let reservedAccountIDs: Set<String> = ["me", "self", "system", "admin", "support", "ai"]
    public static func nickname(from value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40 else { throw PersonaProfileValidationError.invalidNickname }
        return value
    }
    public static func accountID(from value: String) throws -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        value = value.precomposedStringWithCompatibilityMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard value.count >= 3, value.count <= 24,
              value.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
            throw PersonaProfileValidationError.invalidAccountID
        }
        guard !reservedAccountIDs.contains(value) else { throw PersonaProfileValidationError.reservedAccountID }
        return value
    }
    public static func biography(from value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count <= 160 ? value : nil
    }
}

public protocol PersonaRepository: Sendable {
    func fetchDefaultHumanPersona() throws -> Persona
    func fetchPersonas(includeInactive: Bool) throws -> [Persona]
    func fetchPersona(for thoughtID: UUID) throws -> Persona?
    func fetchPersonas(for thoughtIDs: [UUID]) throws -> [UUID: Persona]
    func fetchThoughts(authoredBy personaID: UUID) throws -> [Thought]
    func createPersona(_ persona: Persona) throws
    func updatePersona(_ persona: Persona) throws
    @discardableResult func deactivatePersona(id: UUID, at date: Date) throws -> Bool
}

public protocol AuthoredThoughtRepository: Sendable {
    func create(_ thought: Thought, authorPersonaID: UUID) throws
}

public struct ThoughtMention: Equatable, Sendable {
    public let thoughtID: UUID
    public let personaID: UUID
    public let createdAt: Date
    public init(thoughtID: UUID, personaID: UUID, createdAt: Date = Date()) { self.thoughtID = thoughtID; self.personaID = personaID; self.createdAt = createdAt }
}

public protocol ThoughtMentionRepository: Sendable {
    func create(_ thought: Thought, authorPersonaID: UUID, mentionedPersonaID: UUID?) throws
    func fetchMentionedPersonas(for thoughtIDs: [UUID]) throws -> [UUID: Persona]
}

public struct AIPersonaConfiguration: Equatable, Sendable {
    public let personaID: UUID
    public var role: String
    public var instructions: String
    public var connectionID: UUID?
    public var updatedAt: Date

    public init(personaID: UUID, role: String, instructions: String, connectionID: UUID? = nil, updatedAt: Date = Date()) {
        self.personaID = personaID; self.role = role; self.instructions = instructions; self.connectionID = connectionID; self.updatedAt = updatedAt
    }
}

public struct AIConnection: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public var provider: String
    public var model: String
    public var isEnabled: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), label: String, provider: String, model: String, isEnabled: Bool = true, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.label = label; self.provider = provider; self.model = model; self.isEnabled = isEnabled; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

public struct AIPostGeneration: Equatable, Sendable {
    public let thoughtID: UUID
    public let personaID: UUID
    public let userRequest: String
    public let provider: String
    public let model: String
    public let promptVersion: Int
    public let generatedAt: Date
    public let requestID: UUID?
    public let parentThoughtID: UUID?
    public init(thoughtID: UUID, personaID: UUID, userRequest: String, provider: String, model: String, promptVersion: Int, generatedAt: Date, requestID: UUID? = nil, parentThoughtID: UUID? = nil) {
        self.thoughtID = thoughtID; self.personaID = personaID; self.userRequest = userRequest; self.provider = provider; self.model = model; self.promptVersion = promptVersion; self.generatedAt = generatedAt; self.requestID = requestID; self.parentThoughtID = parentThoughtID
    }
}

public protocol AIPersonaRepository: Sendable {
    func fetchAIConfigurations() throws -> [UUID: AIPersonaConfiguration]
    func saveAIConfiguration(_ configuration: AIPersonaConfiguration) throws
    func createAIPersona(_ persona: Persona, configuration: AIPersonaConfiguration) throws
    func saveGeneratedThought(_ thought: Thought, authorPersonaID: UUID, generation: AIPostGeneration) throws
    func fetchAIConnections() throws -> [AIConnection]
    func saveAIConnection(_ connection: AIConnection) throws
    func saveGeneratedContinuation(_ thought: Thought, parentThoughtID: UUID, authorPersonaID: UUID, generation: AIPostGeneration) throws
}

public struct AIReplyPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: Thought
    public let context: [Thought]
    public let persona: Persona
    public let configuration: AIPersonaConfiguration
    public let request: ReviewSummaryRequest
    public init(id: UUID = UUID(), target: Thought, context: [Thought], persona: Persona, configuration: AIPersonaConfiguration) throws {
        guard persona.kind == .ai, persona.deletedAt == nil else { throw AIPostError.inactivePersona }
        guard !configuration.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !configuration.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIPostError.missingConfiguration }
        self.id = id; self.target = target; self.context = context; self.persona = persona; self.configuration = configuration
        let history = context.map { "- \($0.body)" }.joined(separator: "\n")
        self.request = ReviewSummaryRequest(prompt: """
        あなたはプライベートなThought TimelineのAIアカウントです。
        ニックネーム: \(persona.displayName)
        アカウントID: @\(persona.accountID)
        役割: \(configuration.role)
        指示: \(configuration.instructions)
        Conversation:
        \(history)

        最後のThoughtへの返信本文だけを日本語140文字以内で返してください。前置き、引用符、Markdownは付けないでください。
        """)
    }
}

public struct GenerateAIReply: Sendable {
    private let client: any ReviewSummaryClient
    private let repository: any AIPersonaRepository
    public init(client: any ReviewSummaryClient, repository: any AIPersonaRepository) { self.client = client; self.repository = repository }
    public func callAsFunction(preview: AIReplyPreview, now: Date = Date(), thoughtID: UUID = UUID()) async throws -> Thought {
        let response = try await client.generateSummary(preview.request)
        let body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw AIPostError.emptyResponse }
        guard body.count <= ThoughtDraft.characterLimit else { throw AIPostError.responseTooLong }
        let thought = Thought(id: thoughtID, body: body, createdAt: now)
        let generation = AIPostGeneration(thoughtID: thoughtID, personaID: preview.persona.id, userRequest: "@\(preview.persona.accountID)への返信", provider: response.provider, model: response.model, promptVersion: AIPostPrompt.version, generatedAt: now, requestID: preview.id, parentThoughtID: preview.target.id)
        try repository.saveGeneratedContinuation(thought, parentThoughtID: preview.target.id, authorPersonaID: preview.persona.id, generation: generation)
        return thought
    }
}

public struct AIPostPreview: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let persona: Persona
    public let configuration: AIPersonaConfiguration
    public let userRequest: String
    public let request: ReviewSummaryRequest
}

public enum AIPostError: Error, LocalizedError, Equatable {
    case invalidRequest, inactivePersona, missingConfiguration, emptyResponse, responseTooLong
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "AIへの依頼を入力してください。"
        case .inactivePersona: "このAI Personaは利用できません。"
        case .missingConfiguration: "AI Personaの役割と指示を設定してください。"
        case .emptyResponse: "AIから空の応答が返されました。"
        case .responseTooLong: "AIの応答が140文字を超えたため投稿しませんでした。"
        }
    }
}

public enum AIPostPrompt {
    public static let version = 1
    public static func prepare(persona: Persona, configuration: AIPersonaConfiguration, userRequest: String) throws -> AIPostPreview {
        let request = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { throw AIPostError.invalidRequest }
        guard persona.kind == .ai, persona.deletedAt == nil else { throw AIPostError.inactivePersona }
        guard !configuration.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIPostError.missingConfiguration }
        let prompt = """
        あなたはプライベートなThought Timelineへ参加するAI Personaです。
        Persona名: \(persona.displayName)
        役割: \(configuration.role)
        指示: \(configuration.instructions)
        ユーザーの依頼: \(request)

        日本語で140文字以内の投稿本文だけを返してください。前置き、引用符、Markdown、文字数の説明は付けないでください。
        """
        return AIPostPreview(persona: persona, configuration: configuration, userRequest: request, request: ReviewSummaryRequest(prompt: prompt))
    }
}

public struct GenerateAIPost: Sendable {
    private let client: any ReviewSummaryClient
    private let repository: any AIPersonaRepository
    public init(client: any ReviewSummaryClient, repository: any AIPersonaRepository) { self.client = client; self.repository = repository }
    public func callAsFunction(preview: AIPostPreview, now: Date = Date(), thoughtID: UUID = UUID()) async throws -> Thought {
        let response = try await client.generateSummary(preview.request)
        let body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw AIPostError.emptyResponse }
        guard body.count <= ThoughtDraft.characterLimit else { throw AIPostError.responseTooLong }
        let thought = Thought(id: thoughtID, body: body, createdAt: now)
        let generation = AIPostGeneration(thoughtID: thoughtID, personaID: preview.persona.id, userRequest: preview.userRequest, provider: response.provider, model: response.model, promptVersion: AIPostPrompt.version, generatedAt: now)
        try repository.saveGeneratedThought(thought, authorPersonaID: preview.persona.id, generation: generation)
        return thought
    }
}
