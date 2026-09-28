import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum SQLiteThoughtRepositoryError: Error, LocalizedError, Equatable {
    case open(String)
    case database(String)
    case invalidRecord
    case migration(String)
    case selfRelation
    case cycle

    public var errorDescription: String? {
        switch self {
        case .open(let message): "SQLiteを開けませんでした: \(message)"
        case .database(let message): "SQLite操作に失敗しました: \(message)"
        case .invalidRecord: "SQLite内のThoughtデータが不正です。"
        case .migration(let message): "JSON migrationに失敗しました: \(message)"
        case .selfRelation: "Thoughtを自分自身の続きにはできません。"
        case .cycle: "Thought Historyに循環するRelationは作成できません。"
        }
    }
}

public enum AIPersonaPersistenceError: Error, LocalizedError, Equatable {
    case personaInsert(String)
    case configurationUpsert(String)

    public var errorDescription: String? {
        switch self {
        case .personaInsert(let message):
            "AI Persona本体の保存に失敗しました: \(message)"
        case .configurationUpsert(let message):
            "AI設定の保存に失敗しました: \(message)"
        }
    }
}

public final class SQLiteThoughtRepository: ThoughtRepository, AuthoredThoughtRepository, ThoughtMentionRepository, AIPersonaRepository, AIThoughtReplyRepository, HumanThoughtReplyRepository, ThoughtRelationRepository, ThoughtContinuationRepository, ThoughtTagRepository, ThoughtAnalyticsRepository, ReviewSummaryRepository, DailySummaryRepository, WeeklyReviewRepository, SecondBrainAppRepository, PersonaRepository, AIAPIUsageRepository, AIAPIUsageAnalyticsRepository, KnowledgeDraftRepository, KnowledgeLifecycleEventRepository, @unchecked Sendable {
    public static let schemaVersion: Int32 = 22
    private static let localAccountID = "owner"

    private let databaseURL: URL
    private let legacyJSONURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var database: OpaquePointer?

    public convenience init(fileManager: FileManager = .default) throws {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent("ThoughtTimeline", isDirectory: true)
        try self.init(
            databaseURL: directory.appendingPathComponent("thought-timeline.sqlite3"),
            legacyJSONURL: directory.appendingPathComponent("thoughts.json"),
            fileManager: fileManager
        )
    }

    public init(databaseURL: URL, legacyJSONURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.databaseURL = databaseURL
        self.legacyJSONURL = legacyJSONURL
            ?? databaseURL.deletingLastPathComponent().appendingPathComponent("thoughts.json")
        self.fileManager = fileManager

        do {
            try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try open()
            try configureAndMigrateSchema()
            try migrateLegacyJSONIfNeeded()
            try validateDatabaseHealth()
            _ = try seedDefaultAppsIfNeededLocked(now: Date())
            createRollingBackupIfPossible()
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            NSLog("Thought database initialization failed: %@", String(describing: error))
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    public var canonicalDatabaseURL: URL { databaseURL }

    /// Creates a transactionally consistent, standalone SQLite database even
    /// while the canonical database is using a journal or WAL.
    public func createSnapshot(at destinationURL: URL) throws {
        try lock.withLock {
            guard let database else { throw SQLiteThoughtRepositoryError.open("database is closed") }
            try Self.createSnapshot(from: database, at: destinationURL, fileManager: fileManager)
        }
    }

    public func create(_ thought: Thought) throws {
        try create(thought, authorPersonaID: Persona.defaultHumanID)
    }

    public func create(_ thought: Thought, authorPersonaID: UUID) throws {
        try lock.withLock {
            try transaction {
                try executeThoughtInsert(thought, conflictClause: "")
                try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: authorPersonaID)
            }
            createRollingBackupIfPossible()
        }
    }

    public func create(_ thought: Thought, authorPersonaID: UUID, mentionedPersonaID: UUID?) throws {
        let mentions: [ThoughtMention]
        if let mentionedPersonaID {
            let persona = try lock.withLock { try queryPersona(id: mentionedPersonaID) }
            let token = "@\(persona.handle)", range = (thought.body as NSString).range(of: token, options: .caseInsensitive)
            mentions = [.init(thoughtID: thought.id, personaID: persona.id, handleSnapshot: persona.handle, rangeLocation: range.location == NSNotFound ? 0 : range.location, rangeLength: range.location == NSNotFound ? 0 : range.length, createdAt: thought.createdAt)]
        } else { mentions = [] }
        try create(thought, authorPersonaID: authorPersonaID, mentions: mentions)
    }

    public func create(_ thought: Thought, authorPersonaID: UUID, mentions: [ThoughtMention]) throws {
        try lock.withLock {
            try transaction {
                try executeThoughtInsert(thought, conflictClause: ""); try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: authorPersonaID)
                for mention in mentions {
                    guard mention.thoughtID == thought.id else { throw SQLiteThoughtRepositoryError.invalidRecord }
                    let statement = try prepare("INSERT INTO thought_mentions (thought_id, persona_id, handle_snapshot, range_location, range_length, created_at) SELECT ?, id, ?, ?, ?, ? FROM personas WHERE id = ? AND deleted_at IS NULL")
                    defer { sqlite3_finalize(statement) }
                    try bind(thought.id.uuidString, to: 1, in: statement); try bind(mention.handleSnapshot, to: 2, in: statement); try bind(Int32(mention.rangeLocation), to: 3, in: statement); try bind(Int32(mention.rangeLength), to: 4, in: statement); try bind(mention.createdAt.timeIntervalSince1970, to: 5, in: statement); try bind(mention.personaID.uuidString, to: 6, in: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw SQLiteThoughtRepositoryError.invalidRecord }
                }
            }
            createRollingBackupIfPossible()
        }
    }

    public func fetchMentionedPersonas(for thoughtIDs: [UUID]) throws -> [UUID: Persona] {
        guard !thoughtIDs.isEmpty else { return [:] }
        return try lock.withLock {
            let placeholders = Array(repeating: "?", count: thoughtIDs.count).joined(separator: ",")
            let statement = try prepare("SELECT m.thought_id, p.id, p.display_name, p.handle, p.kind, p.icon_data, p.icon_mime_type, p.created_at, p.updated_at, p.deleted_at FROM thought_mentions m JOIN personas p ON p.id = m.persona_id WHERE m.thought_id IN (\(placeholders)) ORDER BY m.range_location")
            defer { sqlite3_finalize(statement) }
            for (offset, id) in thoughtIDs.enumerated() { try bind(id.uuidString, to: Int32(offset + 1), in: statement) }
            var output: [UUID: Persona] = [:]; var result = sqlite3_step(statement)
            while result == SQLITE_ROW { guard let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) else { throw SQLiteThoughtRepositoryError.invalidRecord }; output[id] = try decodePersona(statement, columnOffset: 1); result = sqlite3_step(statement) }
            guard result == SQLITE_DONE else { throw lastError() }; return output
        }
    }

    public func fetchMentions(for thoughtIDs: [UUID]) throws -> [UUID: [ThoughtMention]] {
        guard !thoughtIDs.isEmpty else { return [:] }
        return try lock.withLock {
            let placeholders = Array(repeating: "?", count: thoughtIDs.count).joined(separator: ",")
            let statement = try prepare("SELECT thought_id, persona_id, handle_snapshot, range_location, range_length, created_at FROM thought_mentions WHERE thought_id IN (\(placeholders)) ORDER BY thought_id, range_location")
            defer { sqlite3_finalize(statement) }
            for (offset, id) in thoughtIDs.enumerated() { try bind(id.uuidString, to: Int32(offset + 1), in: statement) }
            var output: [UUID: [ThoughtMention]] = [:]; var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let thoughtText = sqlite3_column_text(statement, 0), let personaText = sqlite3_column_text(statement, 1), let snapshot = sqlite3_column_text(statement, 2), let thoughtID = UUID(uuidString: String(cString: thoughtText)), let personaID = UUID(uuidString: String(cString: personaText)) else { throw SQLiteThoughtRepositoryError.invalidRecord }
                output[thoughtID, default: []].append(.init(thoughtID: thoughtID, personaID: personaID, handleSnapshot: String(cString: snapshot), rangeLocation: Int(sqlite3_column_int64(statement, 3)), rangeLength: Int(sqlite3_column_int64(statement, 4)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }; return output
        }
    }

    public func fetchDefaultHumanPersona() throws -> Persona {
        try lock.withLock { try queryPersona(id: Persona.defaultHumanID) }
    }

    public func fetchPersonas(includeInactive: Bool) throws -> [Persona] {
        try lock.withLock { try queryPersonas(includeInactive ? "" : "WHERE deleted_at IS NULL") }
    }

    public func createPersona(_ persona: Persona) throws {
        try lock.withLock { try executePersonaInsert(persona); createRollingBackupIfPossible() }
    }

    public func fetchPersona(for thoughtID: UUID) throws -> Persona? {
        try lock.withLock {
            let statement = try prepare("""
                SELECT p.id, p.display_name, p.handle, p.kind, p.icon_data, p.icon_mime_type, p.created_at, p.updated_at, p.deleted_at
                FROM personas p JOIN thought_authors a ON a.persona_id = p.id
                WHERE a.thought_id = ? LIMIT 1
                """)
            defer { sqlite3_finalize(statement) }
            try bind(thoughtID.uuidString, to: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW ? try decodePersona(statement) : nil
        }
    }

    public func fetchPersonas(for thoughtIDs: [UUID]) throws -> [UUID: Persona] {
        guard !thoughtIDs.isEmpty else { return [:] }
        return try lock.withLock {
            let placeholders = Array(repeating: "?", count: thoughtIDs.count).joined(separator: ",")
            let statement = try prepare("""
                SELECT a.thought_id, p.id, p.display_name, p.handle, p.kind, p.icon_data, p.icon_mime_type, p.created_at, p.updated_at, p.deleted_at
                FROM thought_authors a JOIN personas p ON p.id = a.persona_id
                WHERE a.thought_id IN (\(placeholders))
                """)
            defer { sqlite3_finalize(statement) }
            for (offset, id) in thoughtIDs.enumerated() { try bind(id.uuidString, to: Int32(offset + 1), in: statement) }
            var output: [UUID: Persona] = [:]
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let thoughtText = sqlite3_column_text(statement, 0), let thoughtID = UUID(uuidString: String(cString: thoughtText)) else { throw SQLiteThoughtRepositoryError.invalidRecord }
                output[thoughtID] = try decodePersona(statement, columnOffset: 1)
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }
            return output
        }
    }

    public func updatePersona(_ persona: Persona) throws {
        try lock.withLock {
            guard ActorHandle.normalize(persona.handle) == persona.handle else { throw SQLiteThoughtRepositoryError.invalidRecord }
            let statement = try prepare("UPDATE personas SET display_name = ?, handle = ?, icon_data = ?, icon_mime_type = ?, updated_at = ?, deleted_at = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(persona.displayName, to: 1, in: statement)
            try bind(persona.handle, to: 2, in: statement)
            try bindOptional(persona.iconData, to: 3, in: statement)
            try bindOptional(persona.iconMIMEType, to: 4, in: statement)
            try bind(persona.updatedAt.timeIntervalSince1970, to: 5, in: statement)
            try bindOptional(persona.deletedAt?.timeIntervalSince1970, to: 6, in: statement)
            try bind(persona.id.uuidString, to: 7, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw lastError() }
            createRollingBackupIfPossible()
        }
    }

    public func deactivatePersona(id: UUID, at date: Date) throws -> Bool {
        guard id != Persona.defaultHumanID else { return false }
        return try lock.withLock {
            let statement = try prepare("UPDATE personas SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL")
            defer { sqlite3_finalize(statement) }
            try bind(date.timeIntervalSince1970, to: 1, in: statement); try bind(date.timeIntervalSince1970, to: 2, in: statement); try bind(id.uuidString, to: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            let changed = sqlite3_changes(database) == 1
            if changed { createRollingBackupIfPossible() }
            return changed
        }
    }

    public func fetchAIConfigurations() throws -> [UUID: AIPersonaConfiguration] {
        try lock.withLock {
            let statement = try prepare("SELECT persona_id, role, instructions, auto_reply_enabled, provider, updated_at FROM ai_persona_configurations")
            defer { sqlite3_finalize(statement) }
            var output: [UUID: AIPersonaConfiguration] = [:]; var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0), let roleText = sqlite3_column_text(statement, 1), let instructionsText = sqlite3_column_text(statement, 2), let providerText = sqlite3_column_text(statement, 4), let id = UUID(uuidString: String(cString: idText)), let provider = AIProvider(rawValue: String(cString: providerText)) else { throw SQLiteThoughtRepositoryError.invalidRecord }
                output[id] = AIPersonaConfiguration(personaID: id, role: String(cString: roleText), instructions: String(cString: instructionsText), autoReplyEnabled: sqlite3_column_int(statement, 3) != 0, provider: provider, updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))); result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }; return output
        }
    }

    public func saveAIConfiguration(_ configuration: AIPersonaConfiguration) throws {
        try lock.withLock { try executeAIConfigurationUpsert(configuration); createRollingBackupIfPossible() }
    }

    public func createAIPersona(_ persona: Persona, configuration: AIPersonaConfiguration) throws {
        try lock.withLock {
            try transaction {
                do {
                    try executePersonaInsert(persona)
                } catch {
                    let message = sqliteErrorMessage(fallback: error)
#if DEBUG
                    NSLog("[AIPersona][SQLite] personas INSERT failed: %@", message)
#endif
                    throw AIPersonaPersistenceError.personaInsert(message)
                }
                do {
                    try executeAIConfigurationUpsert(configuration)
                } catch {
                    let message = sqliteErrorMessage(fallback: error)
#if DEBUG
                    NSLog("[AIPersona][SQLite] ai_persona_configurations UPSERT failed: %@", message)
#endif
                    throw AIPersonaPersistenceError.configurationUpsert(message)
                }
            }
#if DEBUG
            NSLog("[AIPersona][SQLite] transaction committed persona_id=%@", persona.id.uuidString)
#endif
            createRollingBackupIfPossible()
        }
    }

    public func saveGeneratedThought(_ thought: Thought, authorPersonaID: UUID, generation: AIPostGeneration) throws {
        try lock.withLock {
            try transaction {
                let author = try queryPersona(id: authorPersonaID)
                guard author.kind == .ai, author.deletedAt == nil,
                      generation.thoughtID == thought.id, generation.personaID == authorPersonaID,
                      generation.kind == .standalone, generation.replyTargetThoughtID == nil else { throw SQLiteThoughtRepositoryError.invalidRecord }
                try executeThoughtInsert(thought, conflictClause: ""); try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: authorPersonaID)
                let statement = try prepare("INSERT INTO ai_post_generations (thought_id, persona_id, user_request, provider, model, prompt_version, generated_at, generation_kind, reply_target_thought_id) VALUES (?, ?, ?, ?, ?, ?, ?, 'standalone', NULL)")
                defer { sqlite3_finalize(statement) }
                try bind(generation.thoughtID.uuidString, to: 1, in: statement); try bind(generation.personaID.uuidString, to: 2, in: statement); try bind(generation.userRequest, to: 3, in: statement); try bind(generation.provider, to: 4, in: statement); try bind(generation.model, to: 5, in: statement); try bind(Int32(generation.promptVersion), to: 6, in: statement); try bind(generation.generatedAt.timeIntervalSince1970, to: 7, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            createRollingBackupIfPossible()
        }
    }

    public func saveUsage(_ record: AIAPIUsageRecord) throws {
        try lock.withLock {
            let statement = try prepare("INSERT INTO ai_api_usage (id, started_at, finished_at, feature, persona_id, provider, model, status, input_characters, output_characters, input_tokens, output_tokens, total_tokens, latency_milliseconds, external_brain_used, retrieved_chunk_count, error_category, source_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            try bind(record.id.uuidString, to: 1, in: statement); try bind(record.startedAt.timeIntervalSince1970, to: 2, in: statement); try bindOptional(record.finishedAt?.timeIntervalSince1970, to: 3, in: statement)
            try bind(record.feature.rawValue, to: 4, in: statement); try bindOptional(record.personaID?.uuidString, to: 5, in: statement); try bind(record.provider, to: 6, in: statement); try bind(record.model, to: 7, in: statement); try bind(record.status.rawValue, to: 8, in: statement)
            try bind(Int32(record.inputCharacters), to: 9, in: statement); try bind(Int32(record.outputCharacters), to: 10, in: statement); try bindOptional(record.inputTokens.map(Double.init), to: 11, in: statement); try bindOptional(record.outputTokens.map(Double.init), to: 12, in: statement); try bindOptional(record.totalTokens.map(Double.init), to: 13, in: statement); try bindOptional(record.latencyMilliseconds.map(Double.init), to: 14, in: statement)
            try bind(record.externalBrainUsed ? Int32(1) : Int32(0), to: 15, in: statement); try bind(Int32(record.retrievedChunkCount), to: 16, in: statement); try bindOptional(record.errorCategory?.rawValue, to: 17, in: statement); try bindOptional(record.sourceType?.rawValue, to: 18, in: statement)
            try stepDone(statement)
        }
    }

    public func fetchUsage(from start: Date?, to end: Date?) throws -> [AIAPIUsageRecord] {
        try lock.withLock {
            var clauses: [String] = []; if start != nil { clauses.append("started_at >= ?") }; if end != nil { clauses.append("started_at < ?") }
            let sql = "SELECT id, started_at, finished_at, feature, persona_id, provider, model, status, input_characters, output_characters, input_tokens, output_tokens, total_tokens, latency_milliseconds, external_brain_used, retrieved_chunk_count, error_category, source_type FROM ai_api_usage" + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) + " ORDER BY started_at ASC, id ASC"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            var index: Int32 = 1; if let start { try bind(start.timeIntervalSince1970, to: index, in: statement); index += 1 }; if let end { try bind(end.timeIntervalSince1970, to: index, in: statement) }
            var values: [AIAPIUsageRecord] = []; var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: idText)), let featureText = sqlite3_column_text(statement, 3), let feature = AIAPIFeature(rawValue: String(cString: featureText)), let providerText = sqlite3_column_text(statement, 5), let modelText = sqlite3_column_text(statement, 6), let statusText = sqlite3_column_text(statement, 7), let status = AIAPICallStatus(rawValue: String(cString: statusText)) else { throw SQLiteThoughtRepositoryError.invalidRecord }
                func optionalInt(_ column: Int32) -> Int? { sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column)) }
                let personaID = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : UUID(uuidString: String(cString: sqlite3_column_text(statement, 4)))
                let category = sqlite3_column_type(statement, 16) == SQLITE_NULL ? nil : AIAPIErrorCategory(rawValue: String(cString: sqlite3_column_text(statement, 16)))
                let sourceType = sqlite3_column_type(statement, 17) == SQLITE_NULL ? nil : KnowledgeDraftSource(rawValue: String(cString: sqlite3_column_text(statement, 17)))
                values.append(.init(id: id, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), finishedAt: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), feature: feature, personaID: personaID, provider: String(cString: providerText), model: String(cString: modelText), status: status, inputCharacters: Int(sqlite3_column_int64(statement, 8)), outputCharacters: Int(sqlite3_column_int64(statement, 9)), inputTokens: optionalInt(10), outputTokens: optionalInt(11), totalTokens: optionalInt(12), latencyMilliseconds: optionalInt(13), externalBrainUsed: sqlite3_column_int(statement, 14) != 0, retrievedChunkCount: Int(sqlite3_column_int64(statement, 15)), errorCategory: category, sourceType: sourceType))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }; return values
        }
    }

    public func saveKnowledgeDraft(_ draft: KnowledgeDraft) throws { try lock.withLock { try saveKnowledgeDraftUnlocked(draft) } }
    private func saveKnowledgeDraftUnlocked(_ draft: KnowledgeDraft) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let tags = String(data: try encoder.encode(draft.tags), encoding: .utf8)!, related = String(data: try encoder.encode(draft.relatedDocuments), encoding: .utf8)!, provenance = String(data: try encoder.encode(draft.provenance), encoding: .utf8)!
        let s = try prepare("INSERT OR REPLACE INTO knowledge_drafts(id,title,body,draft_type,project,tags_json,source_type,provenance_json,review_status,sync_status,github_path,created_at,updated_at,approved_at,promoted_at,rejected_at,knowledge_path,knowledge_sha,related_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(s) }
        let strings: [String?] = [draft.id.uuidString,draft.title,draft.body,draft.type.rawValue,draft.project,tags,draft.source.rawValue,provenance,draft.reviewStatus.rawValue,draft.syncStatus.rawValue,draft.savedPath]
        for (offset,value) in strings.enumerated() { try bindOptional(value, to: Int32(offset + 1), in: s) }
        try bind(draft.createdAt.timeIntervalSince1970, to: 12, in: s); try bind(draft.updatedAt.timeIntervalSince1970, to: 13, in: s); try bindOptional(draft.approvedAt?.timeIntervalSince1970, to: 14, in: s); try bindOptional(draft.promotedAt?.timeIntervalSince1970, to: 15, in: s); try bindOptional(draft.rejectedAt?.timeIntervalSince1970, to: 16, in: s); try bindOptional(draft.knowledgePath, to: 17, in: s); try bindOptional(draft.knowledgeSHA, to: 18, in: s); try bind(related, to: 19, in: s); try stepDone(s)
        let delete = try prepare("DELETE FROM knowledge_drafts_fts WHERE id = ?"); defer { sqlite3_finalize(delete) }; try bind(draft.id.uuidString,to:1,in:delete); try stepDone(delete)
        let index = try prepare("INSERT INTO knowledge_drafts_fts(id,title,body,tags,source_type) VALUES(?,?,?,?,?)"); defer { sqlite3_finalize(index) }; try bind(draft.id.uuidString,to:1,in:index); try bind(draft.title,to:2,in:index); try bind(draft.body,to:3,in:index); try bind(draft.tags.joined(separator:" "),to:4,in:index); try bind(draft.source.rawValue,to:5,in:index); try stepDone(index)
    }
    public func deleteKnowledgeDraft(id: UUID) throws { try lock.withLock { try transaction {
        let deleteIndex = try prepare("DELETE FROM knowledge_drafts_fts WHERE id = ?"); defer { sqlite3_finalize(deleteIndex) }; try bind(id.uuidString,to:1,in:deleteIndex); try stepDone(deleteIndex)
        let deleteDraft = try prepare("DELETE FROM knowledge_drafts WHERE id = ?"); defer { sqlite3_finalize(deleteDraft) }; try bind(id.uuidString,to:1,in:deleteDraft); try stepDone(deleteDraft)
    } } }
    public func fetchKnowledgeDrafts() throws -> [KnowledgeDraft] { try lock.withLock { try queryKnowledgeDrafts("SELECT id,title,body,draft_type,project,tags_json,source_type,provenance_json,review_status,sync_status,github_path,created_at,updated_at,approved_at,promoted_at,rejected_at,knowledge_path,knowledge_sha,related_json FROM knowledge_drafts ORDER BY updated_at DESC,id DESC") } }
    public func fetchKnowledgeDraft(id: UUID) throws -> KnowledgeDraft? { try lock.withLock { try queryKnowledgeDrafts("SELECT id,title,body,draft_type,project,tags_json,source_type,provenance_json,review_status,sync_status,github_path,created_at,updated_at,approved_at,promoted_at,rejected_at,knowledge_path,knowledge_sha,related_json FROM knowledge_drafts WHERE id = ?", bind: { try self.bind(id.uuidString, to: 1, in: $0) }).first } }
    public func searchKnowledgeDrafts(query: String) throws -> [KnowledgeDraft] { try lock.withLock {
        let terms = query.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }.prefix(12); guard !terms.isEmpty else { return [] }; let match = terms.map { "\"\($0.replacingOccurrences(of:"\"",with:"\"\""))\"" }.joined(separator:" OR ")
        return try queryKnowledgeDrafts("SELECT d.id,d.title,d.body,d.draft_type,d.project,d.tags_json,d.source_type,d.provenance_json,d.review_status,d.sync_status,d.github_path,d.created_at,d.updated_at,d.approved_at,d.promoted_at,d.rejected_at,d.knowledge_path,d.knowledge_sha,d.related_json FROM knowledge_drafts_fts f JOIN knowledge_drafts d ON d.id=f.id WHERE knowledge_drafts_fts MATCH ? ORDER BY bm25(knowledge_drafts_fts),d.updated_at DESC", bind:{ try self.bind(match,to:1,in:$0) })
    } }
    public func savePromotedKnowledge(draft: KnowledgeDraft, document: KnowledgeDocument) throws { try lock.withLock { try transaction {
        guard draft.reviewStatus == .promoted, draft.knowledgePath == document.path, draft.knowledgeSHA == document.sha else { throw SQLiteThoughtRepositoryError.invalidRecord }
        try saveKnowledgeDraftUnlocked(draft)
        let encoder = JSONEncoder(); let tags = String(data: try encoder.encode(document.tags), encoding: .utf8)!
        let s = try prepare("INSERT INTO knowledge_documents(id,draft_id,title,path,sha,source_type,tags_json,markdown,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(s) }; for (offset,value) in [document.id.uuidString,document.draftID.uuidString,document.title,document.path,document.sha,document.source.rawValue,tags,document.markdown].enumerated() { try bind(value, to: Int32(offset + 1), in: s) }; try bind(document.createdAt.timeIntervalSince1970, to: 9, in: s); try bind(document.updatedAt.timeIntervalSince1970, to: 10, in: s); try stepDone(s)
    } } }
    public func fetchKnowledgeDocuments() throws -> [KnowledgeDocument] { try lock.withLock {
        let s = try prepare("SELECT id,draft_id,title,path,sha,source_type,tags_json,markdown,created_at,updated_at,status,superseded_by_knowledge_id,superseded_at,archived_at,retrieval_count,last_retrieved_at FROM knowledge_documents ORDER BY updated_at DESC,id DESC"); defer { sqlite3_finalize(s) }; var values: [KnowledgeDocument] = []; var result = sqlite3_step(s); let decoder = JSONDecoder()
        while result == SQLITE_ROW { guard let id = UUID(uuidString: text(s,0)), let draftID = UUID(uuidString: text(s,1)), let source = KnowledgeDraftSource(rawValue: text(s,5)), let data = text(s,6).data(using:.utf8),let status=KnowledgeDocumentStatus(rawValue:text(s,10)) else { throw SQLiteThoughtRepositoryError.invalidRecord }; values.append(.init(id:id,draftID:draftID,title:text(s,2),path:text(s,3),sha:text(s,4),source:source,tags:try decoder.decode([String].self,from:data),markdown:text(s,7),createdAt:Date(timeIntervalSince1970:sqlite3_column_double(s,8)),updatedAt:Date(timeIntervalSince1970:sqlite3_column_double(s,9)),status:status,supersededByKnowledgeID:optionalText(s,11).flatMap { UUID(uuidString:$0) },supersededAt:optionalDate(s,12),archivedAt:optionalDate(s,13),retrievalCount:Int(sqlite3_column_int64(s,14)),lastRetrievedAt:optionalDate(s,15))); result = sqlite3_step(s) }; guard result == SQLITE_DONE else { throw lastError() }; return values
    } }
    public func saveKnowledgeDocument(_ document: KnowledgeDocument) throws { try lock.withLock { let s=try prepare("UPDATE knowledge_documents SET status=?,superseded_by_knowledge_id=?,superseded_at=?,archived_at=?,retrieval_count=?,last_retrieved_at=? WHERE id=?"); defer { sqlite3_finalize(s) }; try bind(document.status.rawValue,to:1,in:s); try bindOptional(document.supersededByKnowledgeID?.uuidString,to:2,in:s); try bindOptional(document.supersededAt?.timeIntervalSince1970,to:3,in:s); try bindOptional(document.archivedAt?.timeIntervalSince1970,to:4,in:s); try bind(Int32(document.retrievalCount),to:5,in:s); try bindOptional(document.lastRetrievedAt?.timeIntervalSince1970,to:6,in:s); try bind(document.id.uuidString,to:7,in:s); try stepDone(s); guard sqlite3_changes(database)==1 else { throw SQLiteThoughtRepositoryError.invalidRecord } } }
    public func recordKnowledgeRetrieval(paths:[String],at date:Date) throws { guard !paths.isEmpty else{return}; try lock.withLock { let s=try prepare("UPDATE knowledge_documents SET retrieval_count=retrieval_count+1,last_retrieved_at=? WHERE path=? AND status='active'"); defer { sqlite3_finalize(s) }; for path in Set(paths) { sqlite3_reset(s); sqlite3_clear_bindings(s); try bind(date.timeIntervalSince1970,to:1,in:s); try bind(path,to:2,in:s); try stepDone(s) } } }
    public func replaceKnowledgeQualityCandidates(_ candidates:[KnowledgeQualityCandidate]) throws { try lock.withLock { try transaction { try execute("DELETE FROM knowledge_quality_candidates WHERE status = 'open'"); for candidate in candidates { let s=try prepare("INSERT INTO knowledge_quality_candidates(id,candidate_type,knowledge_id,related_knowledge_id,score,reason,status,created_at,resolved_at) SELECT ?,?,?,?,?,?,?,?,NULL WHERE NOT EXISTS(SELECT 1 FROM knowledge_quality_candidates WHERE status IN ('dismissed','resolved') AND candidate_type=? AND knowledge_id=? AND COALESCE(related_knowledge_id,'')=COALESCE(?,''))"); defer { sqlite3_finalize(s) }; try bind(candidate.id.uuidString,to:1,in:s); try bind(candidate.type.rawValue,to:2,in:s); try bind(candidate.knowledgeID.uuidString,to:3,in:s); try bindOptional(candidate.relatedKnowledgeID?.uuidString,to:4,in:s); try bind(candidate.score,to:5,in:s); try bind(candidate.reason,to:6,in:s); try bind(candidate.status.rawValue,to:7,in:s); try bind(candidate.createdAt.timeIntervalSince1970,to:8,in:s); try bind(candidate.type.rawValue,to:9,in:s); try bind(candidate.knowledgeID.uuidString,to:10,in:s); try bindOptional(candidate.relatedKnowledgeID?.uuidString,to:11,in:s); try stepDone(s) } } } }
    public func fetchKnowledgeQualityCandidates() throws -> [KnowledgeQualityCandidate] { try lock.withLock { let s=try prepare("SELECT id,candidate_type,knowledge_id,related_knowledge_id,score,reason,status,created_at,resolved_at FROM knowledge_quality_candidates ORDER BY status ASC,score DESC,created_at DESC"); defer { sqlite3_finalize(s) }; var values:[KnowledgeQualityCandidate]=[]; var result=sqlite3_step(s); while result==SQLITE_ROW { guard let id=UUID(uuidString:text(s,0)),let type=KnowledgeQualityCandidateType(rawValue:text(s,1)),let knowledgeID=UUID(uuidString:text(s,2)),let status=KnowledgeQualityCandidateStatus(rawValue:text(s,6)) else { throw SQLiteThoughtRepositoryError.invalidRecord }; values.append(.init(id:id,knowledgeID:knowledgeID,relatedKnowledgeID:optionalText(s,3).flatMap { UUID(uuidString:$0) },type:type,score:sqlite3_column_double(s,4),reason:text(s,5),status:status,createdAt:Date(timeIntervalSince1970:sqlite3_column_double(s,7)),resolvedAt:optionalDate(s,8))); result=sqlite3_step(s) }; guard result==SQLITE_DONE else { throw lastError() }; return values } }
    public func saveKnowledgeQualityCandidate(_ candidate:KnowledgeQualityCandidate) throws { try lock.withLock { let s=try prepare("UPDATE knowledge_quality_candidates SET status=?,resolved_at=? WHERE id=?"); defer { sqlite3_finalize(s) }; try bind(candidate.status.rawValue,to:1,in:s); try bindOptional(candidate.resolvedAt?.timeIntervalSince1970,to:2,in:s); try bind(candidate.id.uuidString,to:3,in:s); try stepDone(s); guard sqlite3_changes(database)==1 else { throw SQLiteThoughtRepositoryError.invalidRecord } } }
    public func saveKnowledgeLifecycleEvent(_ event: KnowledgeLifecycleEvent) throws { try lock.withLock { let s = try prepare("INSERT INTO knowledge_lifecycle_events(id,draft_id,event_type,source_type,created_at) VALUES(?,?,?,?,?)"); defer { sqlite3_finalize(s) }; try bind(event.id.uuidString,to:1,in:s); try bind(event.draftID.uuidString,to:2,in:s); try bind(event.type.rawValue,to:3,in:s); try bind(event.source.rawValue,to:4,in:s); try bind(event.createdAt.timeIntervalSince1970,to:5,in:s); try stepDone(s) } }
    public func fetchKnowledgeLifecycleEvents() throws -> [KnowledgeLifecycleEvent] { try lock.withLock { let s=try prepare("SELECT id,draft_id,event_type,source_type,created_at FROM knowledge_lifecycle_events ORDER BY created_at DESC,id DESC"); defer { sqlite3_finalize(s) }; var values:[KnowledgeLifecycleEvent]=[]; var result=sqlite3_step(s); while result == SQLITE_ROW { guard let id=UUID(uuidString:text(s,0)),let draftID=UUID(uuidString:text(s,1)),let type=KnowledgeLifecycleEventType(rawValue:text(s,2)),let source=KnowledgeDraftSource(rawValue:text(s,3)) else { throw SQLiteThoughtRepositoryError.invalidRecord }; values.append(.init(id:id,draftID:draftID,type:type,source:source,createdAt:Date(timeIntervalSince1970:sqlite3_column_double(s,4)))); result=sqlite3_step(s) }; guard result == SQLITE_DONE else { throw lastError() }; return values } }

    public func saveGeneratedReply(_ thought: Thought, authorPersonaID: UUID, targetThoughtID: UUID, generation: AIPostGeneration, relationID: UUID) throws {
        try lock.withLock {
            try transaction {
                let duplicateStatement = try prepare("SELECT 1 FROM ai_post_generations WHERE generation_kind = 'reply' AND reply_target_thought_id = ? AND persona_id = ? LIMIT 1")
                defer { sqlite3_finalize(duplicateStatement) }
                try bind(targetThoughtID.uuidString, to: 1, in: duplicateStatement)
                try bind(authorPersonaID.uuidString, to: 2, in: duplicateStatement)
                guard sqlite3_step(duplicateStatement) == SQLITE_DONE else { throw AIPostError.duplicateReply }
                let author = try queryPersona(id: authorPersonaID)
                guard author.kind == .ai, author.deletedAt == nil, generation.kind == .reply,
                      generation.thoughtID == thought.id, generation.personaID == authorPersonaID,
                      generation.replyTargetThoughtID == targetThoughtID,
                      let target = try query("SELECT id, body, created_at, updated_at, deleted_at FROM thoughts WHERE id = ? LIMIT 1", bind: { try self.bind(targetThoughtID.uuidString, to: 1, in: $0) }).first,
                      target.deletedAt == nil else { throw SQLiteThoughtRepositoryError.invalidRecord }
                try executeThoughtInsert(thought, conflictClause: "")
                try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: authorPersonaID)
                let relation = ThoughtRelation(id: relationID, sourceThoughtID: thought.id, targetThoughtID: targetThoughtID, type: .repliesTo, createdAt: thought.createdAt)
                try validate(relation); try executeRelationInsert(relation)
                let statement = try prepare("INSERT INTO ai_post_generations (thought_id, persona_id, user_request, provider, model, prompt_version, generated_at, generation_kind, reply_target_thought_id) VALUES (?, ?, ?, ?, ?, ?, ?, 'reply', ?)")
                defer { sqlite3_finalize(statement) }
                try bind(thought.id.uuidString, to: 1, in: statement); try bind(authorPersonaID.uuidString, to: 2, in: statement); try bind(generation.userRequest, to: 3, in: statement); try bind(generation.provider, to: 4, in: statement); try bind(generation.model, to: 5, in: statement); try bind(Int32(generation.promptVersion), to: 6, in: statement); try bind(generation.generatedAt.timeIntervalSince1970, to: 7, in: statement); try bind(targetThoughtID.uuidString, to: 8, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            createRollingBackupIfPossible()
        }
    }

    public func fetchAIReplies(to thoughtID: UUID) throws -> [Thought] { try lock.withLock { try query("SELECT t.id, t.body, t.created_at, t.updated_at, t.deleted_at FROM thought_relations r JOIN thoughts t ON t.id = r.source_thought_id WHERE r.target_thought_id = ? AND r.relation_type = 'repliesTo' AND t.deleted_at IS NULL ORDER BY t.created_at ASC, t.id ASC", bind: { try self.bind(thoughtID.uuidString, to: 1, in: $0) }) } }
    public func fetchReplyTargets(for thoughtIDs: [UUID]) throws -> [UUID: UUID] {
        guard !thoughtIDs.isEmpty else { return [:] }
        return try lock.withLock {
            let placeholders = Array(repeating: "?", count: thoughtIDs.count).joined(separator: ",")
            let statement = try prepare("SELECT source_thought_id, target_thought_id FROM thought_relations WHERE relation_type = 'repliesTo' AND source_thought_id IN (\(placeholders))")
            defer { sqlite3_finalize(statement) }; for (offset, id) in thoughtIDs.enumerated() { try bind(id.uuidString, to: Int32(offset + 1), in: statement) }
            var output: [UUID: UUID] = [:]; var result = sqlite3_step(statement)
            while result == SQLITE_ROW { guard let s = sqlite3_column_text(statement, 0), let t = sqlite3_column_text(statement, 1), let source = UUID(uuidString: String(cString: s)), let target = UUID(uuidString: String(cString: t)) else { throw SQLiteThoughtRepositoryError.invalidRecord }; output[source] = target; result = sqlite3_step(statement) }
            guard result == SQLITE_DONE else { throw lastError() }; return output
        }
    }
    public func fetchAIPostGeneration(for thoughtID: UUID) throws -> AIPostGeneration? { try lock.withLock {
        let statement = try prepare("SELECT thought_id, persona_id, user_request, provider, model, prompt_version, generated_at, generation_kind, reply_target_thought_id FROM ai_post_generations WHERE thought_id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }; try bind(thoughtID.uuidString, to: 1, in: statement); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let tid = sqlite3_column_text(statement, 0), let pid = sqlite3_column_text(statement, 1), let req = sqlite3_column_text(statement, 2), let provider = sqlite3_column_text(statement, 3), let model = sqlite3_column_text(statement, 4), let kindText = sqlite3_column_text(statement, 7), let t = UUID(uuidString: String(cString: tid)), let p = UUID(uuidString: String(cString: pid)), let kind = AIPostGeneration.Kind(rawValue: String(cString: kindText)) else { throw SQLiteThoughtRepositoryError.invalidRecord }
        let replyID = sqlite3_column_text(statement, 8).flatMap { UUID(uuidString: String(cString: $0)) }
        return AIPostGeneration(thoughtID: t, personaID: p, userRequest: String(cString: req), provider: String(cString: provider), model: String(cString: model), promptVersion: Int(sqlite3_column_int(statement, 5)), generatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)), kind: kind, replyTargetThoughtID: replyID)
    } }
    public func fetchActiveAIReplyPersona(id: UUID) throws -> Persona? { try lock.withLock { let persona = try? queryPersona(id: id); guard persona?.kind == .ai, persona?.deletedAt == nil else { return nil }; return persona } }
    public func fetchRecentAIStatements(personaID: UUID, limit: Int) throws -> [Thought] { try lock.withLock {
        guard limit > 0 else { return [] }
        return try query("SELECT t.id, t.body, t.created_at, t.updated_at, t.deleted_at FROM thoughts t JOIN thought_authors a ON a.thought_id = t.id WHERE a.persona_id = ? AND t.deleted_at IS NULL ORDER BY t.created_at DESC, t.id DESC LIMIT ?", bind: { statement in try self.bind(personaID.uuidString, to: 1, in: statement); try self.bind(Int32(limit), to: 2, in: statement) })
    } }

    public func loadAIReplyContext(targetThoughtID: UUID, maximumEntries: Int) throws -> AIReplyContext { try lock.withLock {
        guard maximumEntries > 0, try queryByID(targetThoughtID) != nil else { throw SQLiteThoughtRepositoryError.invalidRecord }
        var currentID: UUID? = targetThoughtID, visited = Set<UUID>(), newestFirst: [AIReplyContextEntry] = [], traversed: [ThoughtRelation] = []
        while let id = currentID, visited.insert(id).inserted, newestFirst.count < maximumEntries {
            if let thought = try queryByID(id), thought.deletedAt == nil {
                let authorStatement = try prepare("SELECT p.id, p.display_name, p.handle, p.kind, p.icon_data, p.icon_mime_type, p.created_at, p.updated_at, p.deleted_at FROM thought_authors a JOIN personas p ON p.id = a.persona_id WHERE a.thought_id = ? LIMIT 1")
                defer { sqlite3_finalize(authorStatement) }; try bind(id.uuidString, to: 1, in: authorStatement)
                guard sqlite3_step(authorStatement) == SQLITE_ROW else { throw SQLiteThoughtRepositoryError.invalidRecord }
                newestFirst.append(AIReplyContextEntry(thought: thought, author: try decodePersona(authorStatement)))
            }
            let relationStatement = try prepare("SELECT id, source_thought_id, target_thought_id, relation_type, created_at FROM thought_relations WHERE source_thought_id = ? AND relation_type = 'repliesTo' ORDER BY created_at ASC, id ASC LIMIT 1")
            defer { sqlite3_finalize(relationStatement) }; try bind(id.uuidString, to: 1, in: relationStatement)
            guard sqlite3_step(relationStatement) == SQLITE_ROW,
                  let relationIDText = sqlite3_column_text(relationStatement, 0), let sourceText = sqlite3_column_text(relationStatement, 1), let targetText = sqlite3_column_text(relationStatement, 2),
                  let relationID = UUID(uuidString: String(cString: relationIDText)), let sourceID = UUID(uuidString: String(cString: sourceText)), let parentID = UUID(uuidString: String(cString: targetText)) else { break }
            traversed.append(ThoughtRelation(id: relationID, sourceThoughtID: sourceID, targetThoughtID: parentID, type: .repliesTo, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(relationStatement, 4))))
            currentID = parentID
        }
        return AIReplyContext(entries: Array(newestFirst.reversed()), targetThoughtID: targetThoughtID, relations: Array(traversed.reversed()))
    } }
    public func createHumanReply(body: String, targetThoughtID: UUID, mentionedPersonaID: UUID?, now: Date, thoughtID: UUID, relationID: UUID) throws -> Thought? {
        guard let body = ThoughtDraft.validBody(from: body) else { return nil }
        return try lock.withLock {
            let thought = Thought(id: thoughtID, body: body, createdAt: now), relation = ThoughtRelation(id: relationID, sourceThoughtID: thoughtID, targetThoughtID: targetThoughtID, type: .repliesTo, createdAt: now)
            try transaction {
                guard let target = try queryByID(targetThoughtID), target.deletedAt == nil else { throw SQLiteThoughtRepositoryError.invalidRecord }
                try executeThoughtInsert(thought, conflictClause: ""); try executeThoughtAuthorInsert(thoughtID: thoughtID, personaID: Persona.defaultHumanID)
                if let mentionedPersonaID {
                    let persona = try queryPersona(id: mentionedPersonaID), token = "@\(persona.handle)", range = (body as NSString).range(of: token, options: .caseInsensitive)
                    guard persona.deletedAt == nil else { throw SQLiteThoughtRepositoryError.invalidRecord }
                    let statement = try prepare("INSERT INTO thought_mentions (thought_id, persona_id, handle_snapshot, range_location, range_length, created_at) VALUES (?, ?, ?, ?, ?, ?)")
                    defer { sqlite3_finalize(statement) }; try bind(thoughtID.uuidString, to: 1, in: statement); try bind(mentionedPersonaID.uuidString, to: 2, in: statement); try bind(persona.handle, to: 3, in: statement); try bind(Int32(range.location == NSNotFound ? 0 : range.location), to: 4, in: statement); try bind(Int32(range.location == NSNotFound ? 0 : range.length), to: 5, in: statement); try bind(now.timeIntervalSince1970, to: 6, in: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw SQLiteThoughtRepositoryError.invalidRecord }
                }
                try validate(relation); try executeRelationInsert(relation)
            }
            createRollingBackupIfPossible(); return thought
        }
    }

    public func fetchTimeline() throws -> [Thought] {
        try lock.withLock {
            try query("""
                SELECT id, body, created_at, updated_at, deleted_at
                FROM thoughts WHERE deleted_at IS NULL
                ORDER BY created_at DESC, id DESC
                """)
        }
    }

    public func fetchTimelinePage(limit: Int, before cursor: Thought?) throws -> [Thought] {
        guard limit > 0 else { return [] }
        return try lock.withLock {
            if let cursor {
                return try query("""
                    SELECT id, body, created_at, updated_at, deleted_at
                    FROM thoughts
                    WHERE deleted_at IS NULL
                      AND (created_at, id) < (?, ?)
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """, bind: { statement in
                        try self.bind(cursor.createdAt.timeIntervalSince1970, to: 1, in: statement)
                        try self.bind(cursor.id.uuidString, to: 2, in: statement)
                        try self.bind(Int32(limit), to: 3, in: statement)
                    })
            }
            return try query("""
                SELECT id, body, created_at, updated_at, deleted_at
                FROM thoughts
                WHERE deleted_at IS NULL
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """, bind: { statement in
                    try self.bind(Int32(limit), to: 1, in: statement)
                })
        }
    }

    public func fetchByID(_ id: UUID) throws -> Thought? {
        try lock.withLock {
            let values = try query("""
                SELECT id, body, created_at, updated_at, deleted_at
                FROM thoughts WHERE id = ? LIMIT 1
                """, bind: { statement in
                    try self.bind(id.uuidString, to: 1, in: statement)
                })
            return values.first
        }
    }

    public func fetchAll() throws -> [Thought] {
        try lock.withLock {
            try query("""
                SELECT id, body, created_at, updated_at, deleted_at
                FROM thoughts ORDER BY created_at DESC, id DESC
                """)
        }
    }

    public func fetchThoughts(from startDate: Date, to endDate: Date) throws -> [Thought] {
        try lock.withLock {
            try query("""
                SELECT id, body, created_at, updated_at, deleted_at
                FROM thoughts
                WHERE deleted_at IS NULL AND created_at >= ? AND created_at < ?
                ORDER BY created_at ASC, id ASC
                """, bind: { statement in
                    try self.bind(startDate.timeIntervalSince1970, to: 1, in: statement)
                    try self.bind(endDate.timeIntervalSince1970, to: 2, in: statement)
                })
        }
    }

    public func fetchHumanThoughts(from startDate: Date, to endDate: Date) throws -> [Thought] {
        try lock.withLock {
            try query("""
                SELECT t.id, t.body, t.created_at, t.updated_at, t.deleted_at
                FROM thoughts t
                JOIN thought_authors a ON a.thought_id = t.id
                JOIN personas p ON p.id = a.persona_id
                WHERE t.deleted_at IS NULL
                  AND t.created_at >= ? AND t.created_at < ?
                  AND p.kind = 'human'
                ORDER BY t.created_at ASC, t.id ASC
                """, bind: { statement in
                    try self.bind(startDate.timeIntervalSince1970, to: 1, in: statement)
                    try self.bind(endDate.timeIntervalSince1970, to: 2, in: statement)
                })
        }
    }

    public func softDelete(id: UUID, at date: Date) throws -> Bool {
        try lock.withLock {
            let statement = try prepare("UPDATE thoughts SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL")
            defer { sqlite3_finalize(statement) }
            try bind(date.timeIntervalSince1970, to: 1, in: statement)
            try bind(date.timeIntervalSince1970, to: 2, in: statement)
            try bind(id.uuidString, to: 3, in: statement)
            try stepDone(statement)
            let changed = sqlite3_changes(database) > 0
            if changed { createRollingBackupIfPossible() }
            return changed
        }
    }

    public func search(query: String) throws -> [Thought] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try lock.withLock {
            try self.query("""
                SELECT id, body, created_at, updated_at, deleted_at
                FROM thoughts
                WHERE deleted_at IS NULL AND body LIKE ? ESCAPE '\\' COLLATE NOCASE
                ORDER BY created_at DESC, id DESC
                """, bind: { statement in
                    try self.bind("%\(escaped)%", to: 1, in: statement)
                })
        }
    }

    public func fetchAnalytics(_ request: ThoughtAnalyticsRequest) throws -> ThoughtAnalyticsSnapshot {
        try lock.withLock {
            let daily = try queryDailyAnalytics(request.days)
            let weekdayOrder = (0..<7).map { (($0 + request.firstWeekday - 1) % 7) + 1 }
            let weekday = weekdayOrder.map { value in
                WeekdayThoughtCount(
                    weekday: value,
                    count: zip(request.days, daily).filter { $0.0.weekday == value }.reduce(0) { $0 + $1.1.count }
                )
            }
            let timeCounts = try queryTimeOfDayAnalytics(request.timeWindows)
            let todayCount = daily.last?.count ?? 0
            let sevenDayCount = daily.suffix(7).reduce(0) { $0 + $1.count }
            let thirtyDayCount = daily.reduce(0) { $0 + $1.count }
            return ThoughtAnalyticsSnapshot(
                period: request.period,
                summary: .init(
                    todayCount: todayCount,
                    pastSevenDaysCount: sevenDayCount,
                    pastThirtyDaysCount: thirtyDayCount,
                    activeDayCount: daily.filter { $0.count > 0 }.count
                ),
                dailyCounts: daily,
                weekdayCounts: weekday,
                timeOfDayCounts: TimeOfDay.allCases.map {
                    TimeOfDayThoughtCount(timeOfDay: $0, count: timeCounts[$0, default: 0])
                },
                topTags: try queryTopTags(in: request.period, limit: 5),
                thoughtsWithContinuationsCount: try queryThoughtsWithContinuationsCount(in: request.period)
            )
        }
    }

    public func addTag(named name: String, to thoughtID: UUID, at date: Date) throws -> ThoughtTagAssignment {
        guard let displayName = ThoughtTag.displayName(from: name) else { return .invalidName }
        let normalizedName = ThoughtTag.normalize(displayName)
        return try lock.withLock {
            var assignment: ThoughtTagAssignment = .invalidName
            try transaction {
                guard try queryByID(thoughtID)?.deletedAt == nil else {
                    throw SQLiteThoughtRepositoryError.database("active Thought not found")
                }
                let candidate = ThoughtTag(name: displayName, normalizedName: normalizedName, createdAt: date)
                let tagInsert = try prepare("INSERT OR IGNORE INTO tags(id, name, normalized_name, created_at) VALUES (?, ?, ?, ?)")
                defer { sqlite3_finalize(tagInsert) }
                try bind(candidate.id.uuidString, to: 1, in: tagInsert)
                try bind(candidate.name, to: 2, in: tagInsert)
                try bind(candidate.normalizedName, to: 3, in: tagInsert)
                try bind(candidate.createdAt.timeIntervalSince1970, to: 4, in: tagInsert)
                try stepDone(tagInsert)
                guard let tag = try queryTag(normalizedName: normalizedName) else {
                    throw SQLiteThoughtRepositoryError.invalidRecord
                }

                let linkInsert = try prepare("INSERT OR IGNORE INTO thought_tags(thought_id, tag_id, created_at) VALUES (?, ?, ?)")
                defer { sqlite3_finalize(linkInsert) }
                try bind(thoughtID.uuidString, to: 1, in: linkInsert)
                try bind(tag.id.uuidString, to: 2, in: linkInsert)
                try bind(date.timeIntervalSince1970, to: 3, in: linkInsert)
                try stepDone(linkInsert)
                assignment = sqlite3_changes(database) == 1 ? .added(tag) : .alreadyAttached(tag)
            }
            if case .added = assignment { createRollingBackupIfPossible() }
            return assignment
        }
    }

    public func removeTag(id tagID: UUID, from thoughtID: UUID) throws -> Bool {
        try lock.withLock {
            var removed = false
            try transaction {
                let statement = try prepare("DELETE FROM thought_tags WHERE thought_id = ? AND tag_id = ?")
                defer { sqlite3_finalize(statement) }
                try bind(thoughtID.uuidString, to: 1, in: statement)
                try bind(tagID.uuidString, to: 2, in: statement)
                try stepDone(statement)
                removed = sqlite3_changes(database) == 1
            }
            if removed { createRollingBackupIfPossible() }
            return removed
        }
    }

    public func fetchTags(for thoughtID: UUID) throws -> [ThoughtTag] {
        try lock.withLock {
            try queryTags("""
                SELECT tags.id, tags.name, tags.normalized_name, tags.created_at
                FROM tags
                JOIN thought_tags ON thought_tags.tag_id = tags.id
                JOIN thoughts ON thoughts.id = thought_tags.thought_id
                WHERE thoughts.id = ? AND thoughts.deleted_at IS NULL
                ORDER BY tags.normalized_name ASC, tags.id ASC
                """, bind: { try self.bind(thoughtID.uuidString, to: 1, in: $0) })
        }
    }

    public func fetchAllTags() throws -> [ThoughtTag] {
        try lock.withLock {
            try queryTags("""
                SELECT DISTINCT tags.id, tags.name, tags.normalized_name, tags.created_at
                FROM tags
                JOIN thought_tags ON thought_tags.tag_id = tags.id
                JOIN thoughts ON thoughts.id = thought_tags.thought_id
                WHERE thoughts.deleted_at IS NULL
                ORDER BY tags.normalized_name ASC, tags.id ASC
                """)
        }
    }

    public func fetchThoughts(taggedWith tagID: UUID) throws -> [Thought] {
        try lock.withLock {
            try query("""
                SELECT thoughts.id, thoughts.body, thoughts.created_at, thoughts.updated_at, thoughts.deleted_at
                FROM thoughts
                JOIN thought_tags ON thought_tags.thought_id = thoughts.id
                WHERE thought_tags.tag_id = ? AND thoughts.deleted_at IS NULL
                ORDER BY thoughts.created_at DESC, thoughts.id DESC
                """, bind: { try self.bind(tagID.uuidString, to: 1, in: $0) })
        }
    }

    public func fetchThoughts(from startDate: Date, to endDate: Date, taggedWith tagID: UUID) throws -> [Thought] {
        try lock.withLock {
            try query("""
                SELECT thoughts.id, thoughts.body, thoughts.created_at, thoughts.updated_at, thoughts.deleted_at
                FROM thoughts
                JOIN thought_tags ON thought_tags.thought_id = thoughts.id
                WHERE thought_tags.tag_id = ?
                  AND thoughts.deleted_at IS NULL
                  AND thoughts.created_at >= ? AND thoughts.created_at < ?
                ORDER BY thoughts.created_at ASC, thoughts.id ASC
                """, bind: { statement in
                    try self.bind(tagID.uuidString, to: 1, in: statement)
                    try self.bind(startDate.timeIntervalSince1970, to: 2, in: statement)
                    try self.bind(endDate.timeIntervalSince1970, to: 3, in: statement)
                })
        }
    }

    public func save(_ summary: ReviewSummary) throws {
        try lock.withLock {
            do {
                let statement = try prepare("""
                    INSERT INTO review_summaries(
                        id, period_start, period_end, content, created_at,
                        provider, model, prompt_version, thought_count
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(summary.id.uuidString, to: 1, in: statement)
                try bind(summary.periodStart.timeIntervalSince1970, to: 2, in: statement)
                try bind(summary.periodEnd.timeIntervalSince1970, to: 3, in: statement)
                try bind(summary.content, to: 4, in: statement)
                try bind(summary.createdAt.timeIntervalSince1970, to: 5, in: statement)
                try bind(summary.provider, to: 6, in: statement)
                try bind(summary.model, to: 7, in: statement)
                try bind(Int32(summary.promptVersion), to: 8, in: statement)
                try bind(Int32(summary.thoughtCount), to: 9, in: statement)
                try stepDone(statement)
            }
            createRollingBackupIfPossible()
        }
    }

    public func fetchSummaries(from startDate: Date, to endDate: Date) throws -> [ReviewSummary] {
        try lock.withLock {
            let statement = try prepare("""
                SELECT id, period_start, period_end, content, created_at,
                       provider, model, prompt_version, thought_count
                FROM review_summaries
                WHERE period_start = ? AND period_end = ?
                ORDER BY created_at DESC, id DESC
                """)
            defer { sqlite3_finalize(statement) }
            try bind(startDate.timeIntervalSince1970, to: 1, in: statement)
            try bind(endDate.timeIntervalSince1970, to: 2, in: statement)
            var output: [ReviewSummary] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                output.append(try decodeReviewSummary(statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }
            return output
        }
    }

    public func fetchSummary(id: UUID) throws -> ReviewSummary? {
        try lock.withLock {
            let statement = try prepare("""
                SELECT id, period_start, period_end, content, created_at,
                       provider, model, prompt_version, thought_count
                FROM review_summaries WHERE id = ? LIMIT 1
                """)
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, to: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw lastError() }
            return try decodeReviewSummary(statement)
        }
    }

    public func deleteSummary(id: UUID) throws -> Bool {
        try lock.withLock {
            let changed: Bool
            do {
                let statement = try prepare("DELETE FROM review_summaries WHERE id = ?")
                defer { sqlite3_finalize(statement) }
                try bind(id.uuidString, to: 1, in: statement)
                try stepDone(statement)
                changed = sqlite3_changes(database) == 1
            }
            if changed { createRollingBackupIfPossible() }
            return changed
        }
    }

    public func saveDailySummary(_ summary: DailySummary) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(summary.content)
            guard let json = String(data: data, encoding: .utf8) else { throw SQLiteThoughtRepositoryError.invalidRecord }
            let statement = try prepare("""
                INSERT INTO daily_summaries(id, day_start, day_end, content_json, created_at, provider, model, prompt_version, thought_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day_start) DO UPDATE SET
                  id=excluded.id, day_end=excluded.day_end, content_json=excluded.content_json,
                  created_at=excluded.created_at, provider=excluded.provider, model=excluded.model,
                  prompt_version=excluded.prompt_version, thought_count=excluded.thought_count
                """)
            defer { sqlite3_finalize(statement) }
            try bind(summary.id.uuidString, to: 1, in: statement)
            try bind(summary.dayStart.timeIntervalSince1970, to: 2, in: statement)
            try bind(summary.dayEnd.timeIntervalSince1970, to: 3, in: statement)
            try bind(json, to: 4, in: statement)
            try bind(summary.createdAt.timeIntervalSince1970, to: 5, in: statement)
            try bind(summary.provider, to: 6, in: statement)
            try bind(summary.model, to: 7, in: statement)
            try bind(Int32(summary.promptVersion), to: 8, in: statement)
            try bind(Int32(summary.thoughtCount), to: 9, in: statement)
            try stepDone(statement)
            createRollingBackupIfPossible()
        }
    }

    public func fetchDailySummary(dayStart: Date) throws -> DailySummary? {
        try lock.withLock {
            let statement = try prepare("SELECT id, day_start, day_end, content_json, created_at, provider, model, prompt_version, thought_count FROM daily_summaries WHERE day_start = ? LIMIT 1")
            defer { sqlite3_finalize(statement) }
            try bind(dayStart.timeIntervalSince1970, to: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw lastError() }
            return try decodeDailySummary(statement)
        }
    }

    public func fetchDailySummaries(from start: Date, to end: Date) throws -> [DailySummary] {
        try lock.withLock {
            let statement = try prepare("SELECT id, day_start, day_end, content_json, created_at, provider, model, prompt_version, thought_count FROM daily_summaries WHERE day_start >= ? AND day_start < ? ORDER BY created_at DESC, id DESC")
            defer { sqlite3_finalize(statement) }
            try bind(start.timeIntervalSince1970, to: 1, in: statement); try bind(end.timeIntervalSince1970, to: 2, in: statement)
            var output: [DailySummary] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW { output.append(try decodeDailySummary(statement)); result = sqlite3_step(statement) }
            guard result == SQLITE_DONE else { throw lastError() }
            return output
        }
    }

    public func saveWeeklySummary(_ summary: WeeklySummary) throws {
        try lock.withLock {
            let json = try encodedJSON(summary.content)
            let statement = try prepare("""
                INSERT INTO weekly_summaries(id, week_start, week_end, content_json, created_at, provider, model, prompt_version, thought_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(week_start) DO UPDATE SET id=excluded.id, week_end=excluded.week_end, content_json=excluded.content_json, created_at=excluded.created_at, provider=excluded.provider, model=excluded.model, prompt_version=excluded.prompt_version, thought_count=excluded.thought_count
                """)
            defer { sqlite3_finalize(statement) }
            try bind(summary.id.uuidString, to: 1, in: statement); try bind(summary.weekStart.timeIntervalSince1970, to: 2, in: statement); try bind(summary.weekEnd.timeIntervalSince1970, to: 3, in: statement); try bind(json, to: 4, in: statement); try bind(summary.createdAt.timeIntervalSince1970, to: 5, in: statement); try bind(summary.provider, to: 6, in: statement); try bind(summary.model, to: 7, in: statement); try bind(Int32(summary.promptVersion), to: 8, in: statement); try bind(Int32(summary.thoughtCount), to: 9, in: statement)
            try stepDone(statement); createRollingBackupIfPossible()
        }
    }

    public func fetchWeeklySummary(weekStart: Date) throws -> WeeklySummary? {
        try lock.withLock {
            let statement = try prepare("SELECT id, week_start, week_end, content_json, created_at, provider, model, prompt_version, thought_count FROM weekly_summaries WHERE week_start = ? LIMIT 1")
            defer { sqlite3_finalize(statement) }; try bind(weekStart.timeIntervalSince1970, to: 1, in: statement)
            let result = sqlite3_step(statement); if result == SQLITE_DONE { return nil }; guard result == SQLITE_ROW else { throw lastError() }
            return try decodeWeeklySummary(statement)
        }
    }

    public func fetchWeeklySummaries() throws -> [WeeklySummary] {
        try lock.withLock {
            let statement = try prepare("SELECT id, week_start, week_end, content_json, created_at, provider, model, prompt_version, thought_count FROM weekly_summaries ORDER BY week_start DESC")
            defer { sqlite3_finalize(statement) }; var values: [WeeklySummary] = []; var result = sqlite3_step(statement)
            while result == SQLITE_ROW { values.append(try decodeWeeklySummary(statement)); result = sqlite3_step(statement) }
            guard result == SQLITE_DONE else { throw lastError() }; return values
        }
    }

    public func saveWeeklyPlan(_ plan: WeeklyPlan) throws {
        try lock.withLock {
            let json = try encodedJSON(plan.content)
            let statement = try prepare("""
                INSERT INTO weekly_plans(id, target_week_start, target_week_end, source_summary_id, content_json, created_at, updated_at, provider, model, prompt_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(target_week_start) DO UPDATE SET id=excluded.id, target_week_end=excluded.target_week_end, source_summary_id=excluded.source_summary_id, content_json=excluded.content_json, updated_at=excluded.updated_at, provider=excluded.provider, model=excluded.model, prompt_version=excluded.prompt_version
                """)
            defer { sqlite3_finalize(statement) }
            try bind(plan.id.uuidString, to: 1, in: statement); try bind(plan.targetWeekStart.timeIntervalSince1970, to: 2, in: statement); try bind(plan.targetWeekEnd.timeIntervalSince1970, to: 3, in: statement); try bind(plan.sourceSummaryID.uuidString, to: 4, in: statement); try bind(json, to: 5, in: statement); try bind(plan.createdAt.timeIntervalSince1970, to: 6, in: statement); try bind(plan.updatedAt.timeIntervalSince1970, to: 7, in: statement); try bind(plan.provider, to: 8, in: statement); try bind(plan.model, to: 9, in: statement); try bind(Int32(plan.promptVersion), to: 10, in: statement)
            try stepDone(statement); createRollingBackupIfPossible()
        }
    }

    public func fetchWeeklyPlan(targetWeekStart: Date) throws -> WeeklyPlan? {
        try lock.withLock {
            let statement = try prepare("SELECT id, target_week_start, target_week_end, source_summary_id, content_json, created_at, updated_at, provider, model, prompt_version FROM weekly_plans WHERE target_week_start = ? LIMIT 1")
            defer { sqlite3_finalize(statement) }; try bind(targetWeekStart.timeIntervalSince1970, to: 1, in: statement)
            let result = sqlite3_step(statement); if result == SQLITE_DONE { return nil }; guard result == SQLITE_ROW else { throw lastError() }
            return try decodeWeeklyPlan(statement)
        }
    }

    public func fetchAllApps() throws -> [SecondBrainApp] {
        try lock.withLock {
            try querySecondBrainApps(
                "SELECT id, name, description, icon, kind, launch_target_type, launch_target_value, category, is_favorite, sort_order, created_at, updated_at FROM secondbrain_apps ORDER BY sort_order ASC, name COLLATE NOCASE ASC, id ASC"
            )
        }
    }

    public func fetchApp(id: UUID) throws -> SecondBrainApp? {
        try lock.withLock {
            try querySecondBrainApps(
                "SELECT id, name, description, icon, kind, launch_target_type, launch_target_value, category, is_favorite, sort_order, created_at, updated_at FROM secondbrain_apps WHERE id = ? LIMIT 1",
                bind: { try self.bind(id.uuidString, to: 1, in: $0) }
            ).first
        }
    }

    public func createApp(_ app: SecondBrainApp) throws {
        try lock.withLock {
            guard try !secondBrainAppExists(id: app.id) else {
                throw SecondBrainAppRepositoryError.duplicateID(app.id)
            }
            try executeSecondBrainAppInsert(app)
            createRollingBackupIfPossible()
        }
    }

    @discardableResult
    public func seedDefaultAppsIfNeeded(now: Date) throws -> Int {
        try lock.withLock {
            let result = try seedDefaultAppsIfNeededLocked(now: now)
            if result.changed { createRollingBackupIfPossible() }
            return result.insertedCount
        }
    }

    public func updateApp(_ app: SecondBrainApp) throws {
        try lock.withLock {
            guard let existing = try querySecondBrainApps(
                "SELECT id, name, description, icon, kind, launch_target_type, launch_target_value, category, is_favorite, sort_order, created_at, updated_at FROM secondbrain_apps WHERE id = ? LIMIT 1",
                bind: { try self.bind(app.id.uuidString, to: 1, in: $0) }
            ).first else {
                throw SecondBrainAppRepositoryError.notFound(app.id)
            }
            guard existing.createdAt == app.createdAt else {
                throw SecondBrainAppRepositoryError.createdAtChanged(app.id)
            }
            let statement = try prepare("UPDATE secondbrain_apps SET name = ?, description = ?, icon = ?, kind = ?, launch_target_type = ?, launch_target_value = ?, category = ?, is_favorite = ?, sort_order = ?, updated_at = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(app.name, to: 1, in: statement)
            try bind(app.description, to: 2, in: statement)
            try bind(app.icon, to: 3, in: statement)
            try bind(app.kind.rawValue, to: 4, in: statement)
            try bind(app.launchTarget.storageKind.rawValue, to: 5, in: statement)
            try bind(app.launchTarget.storageValue, to: 6, in: statement)
            try bind(app.category, to: 7, in: statement)
            try bind(app.isFavorite ? Int32(1) : Int32(0), to: 8, in: statement)
            try bind(Int64(app.sortOrder), to: 9, in: statement)
            try bind(app.updatedAt.timeIntervalSince1970, to: 10, in: statement)
            try bind(app.id.uuidString, to: 11, in: statement)
            try stepDone(statement)
            createRollingBackupIfPossible()
        }
    }

    public func deleteApp(id: UUID) throws {
        try lock.withLock {
            guard try secondBrainAppExists(id: id) else {
                throw SecondBrainAppRepositoryError.notFound(id)
            }
            let statement = try prepare("DELETE FROM secondbrain_apps WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, to: 1, in: statement)
            try stepDone(statement)
            createRollingBackupIfPossible()
        }
    }

    public func create(_ relation: ThoughtRelation) throws {
        try lock.withLock {
            try validate(relation)
            try executeRelationInsert(relation)
            createRollingBackupIfPossible()
        }
    }

    public func fetchBySourceThoughtID(_ id: UUID) throws -> [ThoughtRelation] {
        try lock.withLock { try queryRelations(where: "source_thought_id = ?", id: id) }
    }

    public func fetchByTargetThoughtID(_ id: UUID) throws -> [ThoughtRelation] {
        try lock.withLock { try queryRelations(where: "target_thought_id = ?", id: id) }
    }

    public func fetchContinuationSource(for thoughtID: UUID) throws -> ThoughtRelation? {
        try fetchBySourceThoughtID(thoughtID).first { $0.type == .continues }
    }

    public func fetchContinuations(of thoughtID: UUID) throws -> [ThoughtRelation] {
        try fetchByTargetThoughtID(thoughtID).filter { $0.type == .continues }
    }

    public func fetchContinuationCounts(for thoughtIDs: [UUID]) throws -> [UUID: Int] {
        guard !thoughtIDs.isEmpty else { return [:] }
        return try lock.withLock {
            let placeholders = Array(repeating: "?", count: thoughtIDs.count).joined(separator: ",")
            let statement = try prepare("""
                SELECT target_thought_id, COUNT(*) FROM thought_relations
                WHERE relation_type = 'continues' AND target_thought_id IN (\(placeholders))
                GROUP BY target_thought_id
                """)
            defer { sqlite3_finalize(statement) }
            for (offset, id) in thoughtIDs.enumerated() {
                try bind(id.uuidString, to: Int32(offset + 1), in: statement)
            }
            var output: [UUID: Int] = [:]
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: idText)) else {
                    throw SQLiteThoughtRepositoryError.invalidRecord
                }
                output[id] = Int(sqlite3_column_int(statement, 1))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }
            return output
        }
    }

    public func createContinuation(
        body: String,
        parentThoughtID: UUID,
        now: Date,
        thoughtID: UUID
    ) throws -> Thought? {
        guard let body = ThoughtDraft.validBody(from: body) else { return nil }
        return try createContinuation(
            Thought(id: thoughtID, body: body, createdAt: now),
            parentThoughtID: parentThoughtID,
            relationID: UUID()
        )
    }

    @discardableResult
    func createContinuation(
        _ thought: Thought,
        parentThoughtID: UUID,
        relationID: UUID
    ) throws -> Thought {
        try lock.withLock {
            let relation = ThoughtRelation(
                id: relationID,
                sourceThoughtID: thought.id,
                targetThoughtID: parentThoughtID,
                createdAt: thought.createdAt
            )
            try transaction {
                try executeThoughtInsert(thought, conflictClause: "")
                try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: Persona.defaultHumanID)
                try validate(relation)
                try executeRelationInsert(relation)
            }
            createRollingBackupIfPossible()
            return thought
        }
    }

    private func queryDailyAnalytics(_ days: [ThoughtAnalyticsDay]) throws -> [DailyThoughtCount] {
        let values = Array(repeating: "(?, ?, ?)", count: days.count).joined(separator: ",")
        let statement = try prepare("""
            WITH periods(day_index, day_start, day_end) AS (VALUES \(values))
            SELECT periods.day_index, COUNT(thoughts.id)
            FROM periods
            LEFT JOIN thoughts ON thoughts.deleted_at IS NULL
              AND thoughts.created_at >= periods.day_start
              AND thoughts.created_at < periods.day_end
            GROUP BY periods.day_index
            ORDER BY periods.day_index ASC
            """)
        defer { sqlite3_finalize(statement) }
        for (index, day) in days.enumerated() {
            let position = Int32(index * 3 + 1)
            try bind(Int32(index), to: position, in: statement)
            try bind(day.interval.start.timeIntervalSince1970, to: position + 1, in: statement)
            try bind(day.interval.end.timeIntervalSince1970, to: position + 2, in: statement)
        }
        var counts = Array(repeating: 0, count: days.count)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let index = Int(sqlite3_column_int(statement, 0))
            guard counts.indices.contains(index) else { throw SQLiteThoughtRepositoryError.invalidRecord }
            counts[index] = Int(sqlite3_column_int64(statement, 1))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return zip(days, counts).map { DailyThoughtCount(date: $0.interval.start, count: $1) }
    }

    private func queryTimeOfDayAnalytics(
        _ windows: [ThoughtAnalyticsTimeWindow]
    ) throws -> [TimeOfDay: Int] {
        let values = Array(repeating: "(?, ?, ?)", count: windows.count).joined(separator: ",")
        let statement = try prepare("""
            WITH windows(bucket, window_start, window_end) AS (VALUES \(values))
            SELECT windows.bucket, COUNT(thoughts.id)
            FROM windows
            LEFT JOIN thoughts ON thoughts.deleted_at IS NULL
              AND thoughts.created_at >= windows.window_start
              AND thoughts.created_at < windows.window_end
            GROUP BY windows.bucket
            ORDER BY windows.bucket ASC
            """)
        defer { sqlite3_finalize(statement) }
        for (index, window) in windows.enumerated() {
            let position = Int32(index * 3 + 1)
            try bind(Int32(window.timeOfDay.rawValue), to: position, in: statement)
            try bind(window.interval.start.timeIntervalSince1970, to: position + 1, in: statement)
            try bind(window.interval.end.timeIntervalSince1970, to: position + 2, in: statement)
        }
        var counts: [TimeOfDay: Int] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let bucket = TimeOfDay(rawValue: Int(sqlite3_column_int(statement, 0))) else {
                throw SQLiteThoughtRepositoryError.invalidRecord
            }
            counts[bucket] = Int(sqlite3_column_int64(statement, 1))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return counts
    }

    private func queryTopTags(in period: DateInterval, limit: Int) throws -> [TagThoughtCount] {
        let statement = try prepare("""
            SELECT tags.id, tags.name, tags.normalized_name, tags.created_at, COUNT(thought_tags.thought_id)
            FROM tags
            JOIN thought_tags ON thought_tags.tag_id = tags.id
            JOIN thoughts ON thoughts.id = thought_tags.thought_id
            WHERE thoughts.deleted_at IS NULL
              AND thoughts.created_at >= ? AND thoughts.created_at < ?
            GROUP BY tags.id, tags.name, tags.normalized_name, tags.created_at
            ORDER BY COUNT(thought_tags.thought_id) DESC, tags.normalized_name ASC, tags.id ASC
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(period.start.timeIntervalSince1970, to: 1, in: statement)
        try bind(period.end.timeIntervalSince1970, to: 2, in: statement)
        try bind(Int32(limit), to: 3, in: statement)
        var output: [TagThoughtCount] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idText)),
                  let nameText = sqlite3_column_text(statement, 1),
                  let normalizedText = sqlite3_column_text(statement, 2) else {
                throw SQLiteThoughtRepositoryError.invalidRecord
            }
            output.append(.init(
                tag: ThoughtTag(
                    id: id,
                    name: String(cString: nameText),
                    normalizedName: String(cString: normalizedText),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                ),
                count: Int(sqlite3_column_int64(statement, 4))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return output
    }

    private func queryThoughtsWithContinuationsCount(in period: DateInterval) throws -> Int {
        let statement = try prepare("""
            SELECT COUNT(DISTINCT parent.id)
            FROM thought_relations AS relation
            JOIN thoughts AS parent ON parent.id = relation.target_thought_id
            JOIN thoughts AS child ON child.id = relation.source_thought_id
            WHERE relation.relation_type = 'continues'
              AND parent.deleted_at IS NULL AND child.deleted_at IS NULL
              AND parent.created_at >= ? AND parent.created_at < ?
              AND child.created_at >= ? AND child.created_at < ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(period.start.timeIntervalSince1970, to: 1, in: statement)
        try bind(period.end.timeIntervalSince1970, to: 2, in: statement)
        try bind(period.start.timeIntervalSince1970, to: 3, in: statement)
        try bind(period.end.timeIntervalSince1970, to: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Keeps two SQLite-native snapshots beside the canonical database. Backup
    /// errors are logged but never turn an already successful post/delete into a
    /// user-visible failure.
    private func createRollingBackupIfPossible() {
        guard let database else { return }
        let olderURL = databaseURL.appendingPathExtension("backup.2")
        let latestURL = databaseURL.appendingPathExtension("backup.1")
        let temporaryURL = databaseURL.appendingPathExtension("backup.tmp")
        try? fileManager.removeItem(at: temporaryURL)

        do { try Self.createSnapshot(from: database, at: temporaryURL, fileManager: fileManager) }
        catch {
            NSLog("Thought database backup failed: %@", String(describing: error))
            return
        }

        do {
            try? fileManager.removeItem(at: olderURL)
            if fileManager.fileExists(atPath: latestURL.path) {
                try fileManager.moveItem(at: latestURL, to: olderURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: latestURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            NSLog("Thought database backup rotation failed: %@", String(describing: error))
        }
    }

    private static func createSnapshot(from source: OpaquePointer, at destinationURL: URL, fileManager: FileManager) throws {
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var destination: OpaquePointer?
        let openResult = sqlite3_open_v2(destinationURL.path, &destination, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let destination { sqlite3_close(destination) }
            throw SQLiteThoughtRepositoryError.open(message)
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(destination)))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            try? fileManager.removeItem(at: destinationURL)
            throw SQLiteThoughtRepositoryError.database(String(cString: sqlite3_errmsg(destination)))
        }
    }

    private func open() throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let connection { sqlite3_close(connection) }
            throw SQLiteThoughtRepositoryError.open(message)
        }
        database = connection
    }

    private func configureAndMigrateSchema() throws {
        try execute("PRAGMA foreign_keys = ON")
        let version = try scalarInt("PRAGMA user_version")
        guard version <= Self.schemaVersion else {
            throw SQLiteThoughtRepositoryError.database("unsupported schema version \(version)")
        }
        if version == 0 {
            try transaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS thoughts (
                        id TEXT PRIMARY KEY NOT NULL,
                        body TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        deleted_at REAL NULL
                    )
                    """)
                try execute("CREATE INDEX IF NOT EXISTS thoughts_timeline_idx ON thoughts(deleted_at, created_at DESC, id DESC)")
                try execute("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY NOT NULL, completed_at REAL NOT NULL)")
                try execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try transaction {
                try execute("""
                    CREATE TABLE thought_relations (
                        id TEXT PRIMARY KEY NOT NULL,
                        source_thought_id TEXT NOT NULL REFERENCES thoughts(id),
                        target_thought_id TEXT NOT NULL REFERENCES thoughts(id),
                        relation_type TEXT NOT NULL CHECK (relation_type = 'continues'),
                        created_at REAL NOT NULL,
                        CHECK (source_thought_id <> target_thought_id),
                        UNIQUE (source_thought_id, target_thought_id, relation_type)
                    )
                    """)
                try execute("CREATE INDEX thought_relations_source_idx ON thought_relations(source_thought_id)")
                try execute("CREATE INDEX thought_relations_target_idx ON thought_relations(target_thought_id)")
                try execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try transaction {
                try execute("""
                    CREATE TABLE review_summaries (
                        id TEXT PRIMARY KEY NOT NULL,
                        period_start REAL NOT NULL,
                        period_end REAL NOT NULL,
                        content TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        provider TEXT NOT NULL,
                        model TEXT NOT NULL,
                        prompt_version INTEGER NOT NULL,
                        thought_count INTEGER NOT NULL CHECK (thought_count > 0),
                        CHECK (period_start < period_end)
                    )
                    """)
                try execute("CREATE INDEX review_summaries_period_idx ON review_summaries(period_start, period_end, created_at DESC, id DESC)")
                try execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try transaction {
                try execute("""
                    CREATE TABLE tags (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        normalized_name TEXT NOT NULL UNIQUE,
                        created_at REAL NOT NULL,
                        CHECK (length(normalized_name) > 0)
                    )
                    """)
                try execute("""
                    CREATE TABLE thought_tags (
                        thought_id TEXT NOT NULL REFERENCES thoughts(id),
                        tag_id TEXT NOT NULL REFERENCES tags(id),
                        created_at REAL NOT NULL,
                        PRIMARY KEY (thought_id, tag_id)
                    )
                    """)
                try execute("CREATE INDEX thought_tags_tag_idx ON thought_tags(tag_id, thought_id)")
                try execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            try transaction {
                try execute("""
                    CREATE TABLE daily_summaries (
                        id TEXT PRIMARY KEY NOT NULL,
                        day_start REAL NOT NULL UNIQUE,
                        day_end REAL NOT NULL,
                        content_json TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        provider TEXT NOT NULL,
                        model TEXT NOT NULL,
                        prompt_version INTEGER NOT NULL,
                        thought_count INTEGER NOT NULL CHECK (thought_count > 0),
                        CHECK (day_start < day_end)
                    )
                    """)
                try execute("CREATE INDEX daily_summaries_created_idx ON daily_summaries(created_at DESC, id DESC)")
                try execute("PRAGMA user_version = 5")
            }
        }
        if version < 6 {
            try transaction {
                try execute("""
                    CREATE TABLE personas (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        account_id TEXT NOT NULL DEFAULT 'owner',
                        biography TEXT NOT NULL DEFAULT '',
                        kind TEXT NOT NULL CHECK (kind IN ('human', 'ai')),
                        icon_data BLOB NULL,
                        icon_mime_type TEXT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        deleted_at REAL NULL
                    )
                    """)
                try execute("""
                    CREATE TABLE thought_authors (
                        thought_id TEXT PRIMARY KEY NOT NULL REFERENCES thoughts(id),
                        persona_id TEXT NOT NULL REFERENCES personas(id)
                    )
                    """)
                try execute("CREATE INDEX thought_authors_persona_idx ON thought_authors(persona_id, thought_id)")
                let now = Date().timeIntervalSince1970
                let persona = try prepare("INSERT INTO personas (id, display_name, kind, created_at, updated_at) VALUES (?, '自分', 'human', ?, ?)")
                defer { sqlite3_finalize(persona) }
                try bind(Persona.defaultHumanID.uuidString, to: 1, in: persona)
                try bind(now, to: 2, in: persona); try bind(now, to: 3, in: persona)
                guard sqlite3_step(persona) == SQLITE_DONE else { throw lastError() }
                try execute("INSERT INTO thought_authors (thought_id, persona_id) SELECT id, '\(Persona.defaultHumanID.uuidString)' FROM thoughts")
                try execute("PRAGMA user_version = 6")
            }
        }
        if version < 7 {
            try transaction {
                try execute("CREATE TABLE ai_persona_configurations (persona_id TEXT PRIMARY KEY NOT NULL REFERENCES personas(id), role TEXT NOT NULL, instructions TEXT NOT NULL, updated_at REAL NOT NULL, CHECK (length(role) > 0), CHECK (length(instructions) > 0))")
                try execute("CREATE TABLE ai_post_generations (thought_id TEXT PRIMARY KEY NOT NULL REFERENCES thoughts(id), persona_id TEXT NOT NULL REFERENCES personas(id), user_request TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, prompt_version INTEGER NOT NULL, generated_at REAL NOT NULL, generation_kind TEXT NOT NULL DEFAULT 'standalone' CHECK (generation_kind IN ('standalone', 'reply')), reply_target_thought_id TEXT NULL REFERENCES thoughts(id))")
                try execute("CREATE INDEX ai_post_generations_persona_idx ON ai_post_generations(persona_id, generated_at DESC)")
                try execute("PRAGMA user_version = 7")
            }
        }
        if version < 8 {
            try transaction {
                try execute("CREATE TABLE thought_mentions (thought_id TEXT PRIMARY KEY NOT NULL REFERENCES thoughts(id), persona_id TEXT NOT NULL REFERENCES personas(id), created_at REAL NOT NULL)")
                try execute("CREATE INDEX thought_mentions_persona_idx ON thought_mentions(persona_id, created_at DESC)")
                try execute("PRAGMA user_version = 8")
            }
        }
        if version < 9 {
            try transaction {
                try addColumnIfMissing(table: "ai_post_generations", column: "generation_kind", definition: "TEXT NOT NULL DEFAULT 'standalone' CHECK (generation_kind IN ('standalone', 'reply'))")
                try addColumnIfMissing(table: "ai_post_generations", column: "reply_target_thought_id", definition: "TEXT NULL REFERENCES thoughts(id)")
                try execute("ALTER TABLE thought_relations RENAME TO thought_relations_v8")
                try execute("""
                    CREATE TABLE thought_relations (
                        id TEXT PRIMARY KEY NOT NULL,
                        source_thought_id TEXT NOT NULL REFERENCES thoughts(id),
                        target_thought_id TEXT NOT NULL REFERENCES thoughts(id),
                        relation_type TEXT NOT NULL CHECK (relation_type IN ('continues', 'repliesTo')),
                        created_at REAL NOT NULL,
                        CHECK (source_thought_id <> target_thought_id),
                        UNIQUE (source_thought_id, target_thought_id, relation_type)
                    )
                    """)
                try execute("INSERT INTO thought_relations SELECT * FROM thought_relations_v8")
                try execute("DROP TABLE thought_relations_v8")
                try execute("CREATE INDEX thought_relations_source_idx ON thought_relations(source_thought_id)")
                try execute("CREATE INDEX thought_relations_target_idx ON thought_relations(target_thought_id)")
                try execute("CREATE INDEX IF NOT EXISTS ai_post_generations_reply_target_idx ON ai_post_generations(reply_target_thought_id, generated_at ASC)")
                try execute("PRAGMA user_version = 9")
            }
        }
        if version < 10 {
            try transaction {
                try createAIAPIUsageTableIfMissing()
                try execute("PRAGMA user_version = 10")
            }
        }
        if version < 11 {
            try transaction {
                try addColumnIfMissing(table: "ai_api_usage", column: "source_type", definition: "TEXT NULL")
                try execute("PRAGMA user_version = 11")
            }
        }
        if version < 12 {
            try transaction {
                try execute("CREATE TABLE knowledge_drafts(id TEXT PRIMARY KEY NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,draft_type TEXT NOT NULL,project TEXT NOT NULL,tags_json TEXT NOT NULL,source_type TEXT NOT NULL,provenance_json TEXT NOT NULL,review_status TEXT NOT NULL,sync_status TEXT NOT NULL,github_path TEXT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL,approved_at REAL NULL,promoted_at REAL NULL,rejected_at REAL NULL,knowledge_path TEXT NULL,knowledge_sha TEXT NULL,related_json TEXT NOT NULL)")
                try execute("CREATE INDEX knowledge_drafts_status_updated_idx ON knowledge_drafts(review_status,updated_at DESC)")
                try execute("CREATE VIRTUAL TABLE knowledge_drafts_fts USING fts5(id UNINDEXED,title,body,tags,source_type,tokenize='trigram')")
                try execute("CREATE TABLE knowledge_documents(id TEXT PRIMARY KEY NOT NULL,draft_id TEXT UNIQUE NOT NULL,title TEXT NOT NULL,path TEXT UNIQUE NOT NULL,sha TEXT NOT NULL,source_type TEXT NOT NULL,tags_json TEXT NOT NULL,markdown TEXT NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL,FOREIGN KEY(draft_id) REFERENCES knowledge_drafts(id))")
                try execute("CREATE TABLE knowledge_lifecycle_events(id TEXT PRIMARY KEY NOT NULL,draft_id TEXT NOT NULL,event_type TEXT NOT NULL,source_type TEXT NOT NULL,created_at REAL NOT NULL)")
                try execute("PRAGMA user_version = 12")
            }
        }
        if version < 13 {
            try transaction {
                try addColumnIfMissing(table: "knowledge_documents", column: "status", definition: "TEXT NOT NULL DEFAULT 'active'")
                try addColumnIfMissing(table: "knowledge_documents", column: "superseded_by_knowledge_id", definition: "TEXT NULL")
                try addColumnIfMissing(table: "knowledge_documents", column: "superseded_at", definition: "REAL NULL")
                try addColumnIfMissing(table: "knowledge_documents", column: "archived_at", definition: "REAL NULL")
                try addColumnIfMissing(table: "knowledge_documents", column: "retrieval_count", definition: "INTEGER NOT NULL DEFAULT 0")
                try addColumnIfMissing(table: "knowledge_documents", column: "last_retrieved_at", definition: "REAL NULL")
                try execute("CREATE TABLE knowledge_quality_candidates(id TEXT PRIMARY KEY NOT NULL,candidate_type TEXT NOT NULL,knowledge_id TEXT NOT NULL,related_knowledge_id TEXT NULL,score REAL NOT NULL,reason TEXT NOT NULL,status TEXT NOT NULL,created_at REAL NOT NULL,resolved_at REAL NULL)")
                try execute("CREATE INDEX knowledge_quality_status_idx ON knowledge_quality_candidates(status,candidate_type,score DESC)")
                try execute("PRAGMA user_version = 13")
            }
        }
        let requiresColumnRepair = try
            !tableColumns("ai_post_generations").isSuperset(of: ["generation_kind", "reply_target_thought_id"]) ||
            !tableColumns("ai_persona_configurations").contains("auto_reply_enabled") ||
            !tableExists("ai_api_usage") || !tableColumns("ai_api_usage").contains("source_type") ||
            !tableColumns("knowledge_documents").isSuperset(of: ["status", "superseded_by_knowledge_id", "superseded_at", "archived_at", "retrieval_count", "last_retrieved_at"])
        if version < 14 || requiresColumnRepair {
            try transaction {
                try addColumnIfMissing(table: "ai_post_generations", column: "generation_kind", definition: "TEXT NOT NULL DEFAULT 'standalone' CHECK (generation_kind IN ('standalone', 'reply'))")
                try addColumnIfMissing(table: "ai_post_generations", column: "reply_target_thought_id", definition: "TEXT NULL REFERENCES thoughts(id)")
                try createAIAPIUsageTableIfMissing()
                try addColumnIfMissing(table: "ai_api_usage", column: "source_type", definition: "TEXT NULL")
                try addColumnIfMissing(table: "knowledge_documents", column: "status", definition: "TEXT NOT NULL DEFAULT 'active'")
                try addColumnIfMissing(table: "knowledge_documents", column: "superseded_by_knowledge_id", definition: "TEXT NULL")
                try addColumnIfMissing(table: "knowledge_documents", column: "superseded_at", definition: "REAL NULL")
                try addColumnIfMissing(table: "knowledge_documents", column: "archived_at", definition: "REAL NULL")
                try addColumnIfMissing(table: "knowledge_documents", column: "retrieval_count", definition: "INTEGER NOT NULL DEFAULT 0")
                try addColumnIfMissing(table: "knowledge_documents", column: "last_retrieved_at", definition: "REAL NULL")
                try execute("CREATE INDEX IF NOT EXISTS ai_post_generations_reply_target_idx ON ai_post_generations(reply_target_thought_id, generated_at ASC)")
                try execute("PRAGMA user_version = 14")
            }
        }
        let supportsReplies = try relationTableSupportsReplies()
        if version < 15 || !supportsReplies {
            try transaction {
                if try !relationTableSupportsReplies() {
                    try execute("ALTER TABLE thought_relations RENAME TO thought_relations_legacy")
                    try execute("""
                        CREATE TABLE thought_relations (
                            id TEXT PRIMARY KEY NOT NULL,
                            source_thought_id TEXT NOT NULL REFERENCES thoughts(id),
                            target_thought_id TEXT NOT NULL REFERENCES thoughts(id),
                            relation_type TEXT NOT NULL CHECK (relation_type IN ('continues', 'repliesTo')),
                            created_at REAL NOT NULL,
                            CHECK (source_thought_id <> target_thought_id),
                            UNIQUE (source_thought_id, target_thought_id, relation_type)
                        )
                        """)
                    try execute("INSERT INTO thought_relations SELECT * FROM thought_relations_legacy")
                    try execute("DROP TABLE thought_relations_legacy")
                    try execute("CREATE INDEX thought_relations_source_idx ON thought_relations(source_thought_id)")
                    try execute("CREATE INDEX thought_relations_target_idx ON thought_relations(target_thought_id)")
                }
                try execute("PRAGMA user_version = 15")
            }
        }
        if version < 16 {
            try transaction {
                try addColumnIfMissing(table: "personas", column: "handle", definition: "TEXT NULL")
                try execute("UPDATE personas SET handle = CASE WHEN kind = 'human' THEN 'myself' ELSE 'ai_' || lower(substr(replace(id, '-', ''), 1, 8)) END WHERE handle IS NULL OR handle = ''")
                try execute("CREATE UNIQUE INDEX IF NOT EXISTS personas_handle_unique_idx ON personas(handle COLLATE NOCASE)")
                try execute("ALTER TABLE thought_mentions RENAME TO thought_mentions_v15")
                try execute("""
                    CREATE TABLE thought_mentions (
                        thought_id TEXT NOT NULL REFERENCES thoughts(id),
                        persona_id TEXT NOT NULL REFERENCES personas(id),
                        handle_snapshot TEXT NOT NULL,
                        range_location INTEGER NOT NULL CHECK (range_location >= 0),
                        range_length INTEGER NOT NULL CHECK (range_length >= 0),
                        created_at REAL NOT NULL,
                        PRIMARY KEY (thought_id, persona_id, range_location)
                    )
                    """)
                try execute("INSERT INTO thought_mentions SELECT m.thought_id, m.persona_id, p.handle, 0, 0, m.created_at FROM thought_mentions_v15 m JOIN personas p ON p.id = m.persona_id")
                try execute("DROP TABLE thought_mentions_v15")
                try execute("CREATE INDEX thought_mentions_persona_idx ON thought_mentions(persona_id, created_at DESC)")
                try execute("PRAGMA user_version = 16")
            }
        }
        let requiresAutoReplyRepair = try !tableColumns("ai_persona_configurations").contains("auto_reply_enabled")
        if version < 17 || requiresAutoReplyRepair {
            try transaction {
                try addColumnIfMissing(table: "ai_persona_configurations", column: "auto_reply_enabled", definition: "INTEGER NOT NULL DEFAULT 1 CHECK (auto_reply_enabled IN (0, 1))")
                try execute("PRAGMA user_version = 17")
            }
        }
        try repairPersonaAccountSchemaIfNeeded()
        let requiresProviderRepair = try !tableColumns("ai_persona_configurations").contains("provider")
        if version < 19 || requiresProviderRepair {
            try transaction {
                try addColumnIfMissing(table: "ai_persona_configurations", column: "provider", definition: "TEXT NOT NULL DEFAULT 'firebase-ai-logic' CHECK (provider IN ('firebase-ai-logic', 'openai'))")
                try execute("PRAGMA user_version = 19")
            }
        }
        if version < 20 {
            try transaction {
                try execute("CREATE TABLE weekly_summaries(id TEXT PRIMARY KEY NOT NULL,week_start REAL NOT NULL UNIQUE,week_end REAL NOT NULL,content_json TEXT NOT NULL,created_at REAL NOT NULL,provider TEXT NOT NULL,model TEXT NOT NULL,prompt_version INTEGER NOT NULL,thought_count INTEGER NOT NULL CHECK (thought_count > 0),CHECK (week_start < week_end))")
                try execute("CREATE INDEX weekly_summaries_start_idx ON weekly_summaries(week_start DESC)")
                try execute("CREATE TABLE weekly_plans(id TEXT PRIMARY KEY NOT NULL,target_week_start REAL NOT NULL UNIQUE,target_week_end REAL NOT NULL,source_summary_id TEXT NOT NULL,content_json TEXT NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL,provider TEXT NOT NULL,model TEXT NOT NULL,prompt_version INTEGER NOT NULL,CHECK (target_week_start < target_week_end))")
                try execute("CREATE INDEX weekly_plans_start_idx ON weekly_plans(target_week_start DESC)")
                try execute("PRAGMA user_version = 20")
            }
        }
        if version < 21 {
            try transaction {
                try execute("""
                    CREATE TABLE secondbrain_apps (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                        description TEXT NOT NULL,
                        icon TEXT NOT NULL,
                        kind TEXT NOT NULL CHECK (kind IN ('native', 'web', 'localWeb', 'external')),
                        launch_target_type TEXT NOT NULL CHECK (launch_target_type IN ('nativeFeature', 'webURL', 'localURL', 'deepLink')),
                        launch_target_value TEXT NOT NULL CHECK (length(launch_target_value) > 0),
                        category TEXT NOT NULL,
                        is_favorite INTEGER NOT NULL CHECK (is_favorite IN (0, 1)),
                        sort_order INTEGER NOT NULL CHECK (sort_order >= 0),
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL CHECK (updated_at >= created_at),
                        CHECK (
                            (kind = 'native' AND launch_target_type = 'nativeFeature') OR
                            (kind = 'web' AND launch_target_type = 'webURL') OR
                            (kind = 'localWeb' AND launch_target_type = 'localURL') OR
                            (kind = 'external' AND launch_target_type IN ('webURL', 'deepLink'))
                        )
                    )
                    """)
                try execute("CREATE INDEX secondbrain_apps_order_idx ON secondbrain_apps(sort_order ASC, name COLLATE NOCASE ASC, id ASC)")
                try execute("CREATE INDEX secondbrain_apps_favorite_idx ON secondbrain_apps(is_favorite DESC, sort_order ASC)")
                try execute("PRAGMA user_version = 21")
            }
        }
        if version < 22 {
            try transaction {
                try execute("""
                    CREATE TABLE secondbrain_default_app_seed_history (
                        app_id TEXT PRIMARY KEY NOT NULL,
                        catalog_version INTEGER NOT NULL CHECK (catalog_version > 0),
                        seeded_at REAL NOT NULL
                    )
                    """)
                try execute("CREATE INDEX secondbrain_default_app_seed_version_idx ON secondbrain_default_app_seed_history(catalog_version, seeded_at)")
                try execute("PRAGMA user_version = 22")
            }
        }
    }

    private func relationTableSupportsReplies() throws -> Bool {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'thought_relations' LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let sql = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: sql).contains("repliesTo")
    }

    private func validateDatabaseHealth() throws {
        let quickCheck = try prepare("PRAGMA quick_check")
        defer { sqlite3_finalize(quickCheck) }
        guard sqlite3_step(quickCheck) == SQLITE_ROW,
              let quickCheckText = sqlite3_column_text(quickCheck, 0),
              String(cString: quickCheckText) == "ok" else {
            throw SQLiteThoughtRepositoryError.database("database health check failed: quick_check")
        }

        let foreignKeyCheck = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(foreignKeyCheck) }
        guard sqlite3_step(foreignKeyCheck) == SQLITE_DONE else {
            throw SQLiteThoughtRepositoryError.database("database health check failed: foreign_key_check")
        }

        let requiredColumns: [String: Set<String>] = [
            "thoughts": ["id", "body", "created_at", "updated_at", "deleted_at"],
            "thought_relations": ["id", "source_thought_id", "target_thought_id", "relation_type", "created_at"],
            "personas": ["id", "display_name", "account_id", "biography", "handle", "kind", "created_at", "updated_at", "deleted_at"],
            "thought_authors": ["thought_id", "persona_id"],
            "thought_mentions": ["thought_id", "persona_id", "handle_snapshot", "range_location", "range_length", "created_at"],
            "tags": ["id", "name", "normalized_name", "created_at"],
            "thought_tags": ["thought_id", "tag_id", "created_at"],
            "ai_persona_configurations": ["persona_id", "role", "instructions", "auto_reply_enabled", "provider", "updated_at"],
            "ai_post_generations": ["thought_id", "persona_id", "generation_kind", "reply_target_thought_id"],
            "daily_summaries": ["id", "day_start", "day_end", "content_json"],
            "weekly_summaries": ["id", "week_start", "week_end", "content_json"],
            "weekly_plans": ["id", "target_week_start", "target_week_end", "source_summary_id", "content_json"],
            "secondbrain_apps": ["id", "name", "description", "icon", "kind", "launch_target_type", "launch_target_value", "category", "is_favorite", "sort_order", "created_at", "updated_at"],
            "secondbrain_default_app_seed_history": ["app_id", "catalog_version", "seeded_at"],
            "ai_api_usage": ["id", "feature", "status", "source_type"],
            "knowledge_drafts": ["id", "body", "review_status", "sync_status"],
            "knowledge_documents": ["id", "draft_id", "status", "retrieval_count"],
            "knowledge_lifecycle_events": ["id", "draft_id", "event_type"],
            "knowledge_quality_candidates": ["id", "candidate_type", "knowledge_id", "status"]
        ]
        for (table, columns) in requiredColumns {
            guard try tableExists(table), try tableColumns(table).isSuperset(of: columns) else {
                throw SQLiteThoughtRepositoryError.database("database health check failed: schema \(table)")
            }
        }
        guard try relationTableSupportsReplies() else {
            throw SQLiteThoughtRepositoryError.database("database health check failed: thought_relations constraint")
        }
    }

    private func createAIAPIUsageTableIfMissing() throws {
        guard try !tableExists("ai_api_usage") else { return }
        try execute("CREATE TABLE ai_api_usage (id TEXT PRIMARY KEY NOT NULL, started_at REAL NOT NULL, finished_at REAL NULL, feature TEXT NOT NULL, persona_id TEXT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('success', 'failed', 'cancelled')), input_characters INTEGER NOT NULL CHECK (input_characters >= 0), output_characters INTEGER NOT NULL CHECK (output_characters >= 0), input_tokens INTEGER NULL CHECK (input_tokens IS NULL OR input_tokens >= 0), output_tokens INTEGER NULL CHECK (output_tokens IS NULL OR output_tokens >= 0), total_tokens INTEGER NULL CHECK (total_tokens IS NULL OR total_tokens >= 0), latency_milliseconds INTEGER NULL CHECK (latency_milliseconds IS NULL OR latency_milliseconds >= 0), external_brain_used INTEGER NOT NULL CHECK (external_brain_used IN (0, 1)), retrieved_chunk_count INTEGER NOT NULL CHECK (retrieved_chunk_count >= 0), error_category TEXT NULL, source_type TEXT NULL)")
        try execute("CREATE INDEX ai_api_usage_started_idx ON ai_api_usage(started_at DESC)")
        try execute("CREATE INDEX ai_api_usage_dimensions_idx ON ai_api_usage(feature, persona_id, provider, model, status, started_at DESC)")
    }

    private func tableExists(_ table: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(table, to: 1, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result == SQLITE_ROW
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        guard try !tableColumns(table).contains(column) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func repairPersonaAccountSchemaIfNeeded() throws {
        let columns = try tableColumns("personas")
        let hasUniqueAccountConstraint = try hasSingleColumnUniqueIndex(table: "personas", column: "account_id")

        if hasUniqueAccountConstraint {
            try rebuildPersonasWithoutUniqueAccount()
        } else if !columns.contains("account_id") || !columns.contains("biography") {
            try transaction {
                try addColumnIfMissing(table: "personas", column: "account_id", definition: "TEXT NOT NULL DEFAULT '\(Self.localAccountID)'")
                try addColumnIfMissing(table: "personas", column: "biography", definition: "TEXT NOT NULL DEFAULT ''")
                try execute("UPDATE personas SET account_id = '\(Self.localAccountID)' WHERE account_id = ''")
                try execute("PRAGMA user_version = 18")
            }
        } else if try scalarInt("PRAGMA user_version") < 18 {
            try execute("PRAGMA user_version = 18")
        }
    }

    private func hasSingleColumnUniqueIndex(table: String, column: String) throws -> Bool {
        let list = try prepare("PRAGMA index_list(\(table))")
        defer { sqlite3_finalize(list) }
        var result = sqlite3_step(list)
        while result == SQLITE_ROW {
            guard sqlite3_column_int(list, 2) != 0, let nameText = sqlite3_column_text(list, 1) else {
                result = sqlite3_step(list)
                continue
            }
            let name = String(cString: nameText).replacingOccurrences(of: "'", with: "''")
            let info = try prepare("PRAGMA index_info('\(name)')")
            defer { sqlite3_finalize(info) }
            var indexedColumns: [String] = []
            var infoResult = sqlite3_step(info)
            while infoResult == SQLITE_ROW {
                if let columnText = sqlite3_column_text(info, 2) { indexedColumns.append(String(cString: columnText)) }
                infoResult = sqlite3_step(info)
            }
            guard infoResult == SQLITE_DONE else { throw lastError() }
            if indexedColumns == [column] { return true }
            result = sqlite3_step(list)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return false
    }

    private func rebuildPersonasWithoutUniqueAccount() throws {
        let columns = try tableColumns("personas")
        let accountExpression = columns.contains("account_id")
            ? "COALESCE(NULLIF((SELECT account_id FROM personas WHERE id = '\(Persona.defaultHumanID.uuidString)'), ''), '\(Self.localAccountID)')"
            : "'\(Self.localAccountID)'"
        let biographyExpression = columns.contains("biography") ? "COALESCE(biography, '')" : "''"

        try execute("PRAGMA foreign_keys = OFF")
        do {
            try transaction {
                try execute("""
                    CREATE TABLE personas_new (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        account_id TEXT NOT NULL DEFAULT 'owner',
                        biography TEXT NOT NULL DEFAULT '',
                        handle TEXT NOT NULL,
                        kind TEXT NOT NULL CHECK (kind IN ('human', 'ai')),
                        icon_data BLOB NULL,
                        icon_mime_type TEXT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        deleted_at REAL NULL
                    )
                    """)
                try execute("INSERT INTO personas_new (id, display_name, account_id, biography, handle, kind, icon_data, icon_mime_type, created_at, updated_at, deleted_at) SELECT id, display_name, \(accountExpression), \(biographyExpression), handle, kind, icon_data, icon_mime_type, created_at, updated_at, deleted_at FROM personas")
                try execute("DROP TABLE personas")
                try execute("ALTER TABLE personas_new RENAME TO personas")
                try execute("CREATE UNIQUE INDEX personas_handle_unique_idx ON personas(handle COLLATE NOCASE)")
                try execute("PRAGMA user_version = 18")
            }
            try execute("PRAGMA foreign_keys = ON")
            let foreignKeyCheck = try prepare("PRAGMA foreign_key_check")
            defer { sqlite3_finalize(foreignKeyCheck) }
            guard sqlite3_step(foreignKeyCheck) == SQLITE_DONE else {
                throw SQLiteThoughtRepositoryError.database("persona account migration failed: foreign_key_check")
            }
#if DEBUG
            NSLog("[AIPersona][SQLite] repaired personas.account_id UNIQUE constraint")
#endif
        } catch {
            try? execute("PRAGMA foreign_keys = ON")
            throw error
        }
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { throw SQLiteThoughtRepositoryError.invalidRecord }
            columns.insert(String(cString: name))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return columns
    }

    private func migrateLegacyJSONIfNeeded() throws {
        guard try !migrationCompleted("legacy_json_v1") else { return }
        guard fileManager.fileExists(atPath: legacyJSONURL.path) else {
            try markMigrationCompleted("legacy_json_v1")
            return
        }

        let thoughts: [Thought]
        do {
            let data = try Data(contentsOf: legacyJSONURL)
            thoughts = try Self.jsonDecoder.decode([Thought].self, from: data)
        } catch {
            throw SQLiteThoughtRepositoryError.migration(String(describing: error))
        }

        do {
            try transaction {
                for thought in thoughts {
                    try executeThoughtInsert(thought, conflictClause: "OR IGNORE")
                    try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: Persona.defaultHumanID, conflictClause: "OR IGNORE")
                }
                for thought in thoughts {
                    guard try queryByID(thought.id) == thought else {
                        throw SQLiteThoughtRepositoryError.migration("import verification failed for \(thought.id)")
                    }
                }
                try insertMigrationMarker("legacy_json_v1")
            }
        } catch {
            // The transaction rolls back and the source JSON is intentionally never removed.
            throw SQLiteThoughtRepositoryError.migration(String(describing: error))
        }
    }

    private func migrationCompleted(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM migrations WHERE name = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(name, to: 1, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result == SQLITE_ROW
    }

    private func markMigrationCompleted(_ name: String) throws {
        try transaction { try insertMigrationMarker(name) }
    }

    private func insertMigrationMarker(_ name: String) throws {
        let statement = try prepare("INSERT OR IGNORE INTO migrations(name, completed_at) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(name, to: 1, in: statement)
        try bind(Date().timeIntervalSince1970, to: 2, in: statement)
        try stepDone(statement)
    }

    private func executeThoughtInsert(_ thought: Thought, conflictClause: String) throws {
        let statement = try prepare("INSERT \(conflictClause) INTO thoughts(id, body, created_at, updated_at, deleted_at) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(thought.id.uuidString, to: 1, in: statement)
        try bind(thought.body, to: 2, in: statement)
        try bind(thought.createdAt.timeIntervalSince1970, to: 3, in: statement)
        try bind(thought.updatedAt.timeIntervalSince1970, to: 4, in: statement)
        if let deletedAt = thought.deletedAt {
            try bind(deletedAt.timeIntervalSince1970, to: 5, in: statement)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        try stepDone(statement)
    }

    private func executeRelationInsert(_ relation: ThoughtRelation) throws {
        let statement = try prepare("INSERT INTO thought_relations(id, source_thought_id, target_thought_id, relation_type, created_at) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(relation.id.uuidString, to: 1, in: statement)
        try bind(relation.sourceThoughtID.uuidString, to: 2, in: statement)
        try bind(relation.targetThoughtID.uuidString, to: 3, in: statement)
        try bind(relation.type.rawValue, to: 4, in: statement)
        try bind(relation.createdAt.timeIntervalSince1970, to: 5, in: statement)
        try stepDone(statement)
    }

    private func validate(_ relation: ThoughtRelation) throws {
        guard relation.sourceThoughtID != relation.targetThoughtID else {
            throw SQLiteThoughtRepositoryError.selfRelation
        }
        let existingParent = try prepare("SELECT 1 FROM thought_relations WHERE source_thought_id = ? LIMIT 1")
        defer { sqlite3_finalize(existingParent) }
        try bind(relation.sourceThoughtID.uuidString, to: 1, in: existingParent)
        guard sqlite3_step(existingParent) == SQLITE_DONE else { throw SQLiteThoughtRepositoryError.cycle }
        let statement = try prepare("""
            WITH RECURSIVE ancestors(id) AS (
                SELECT target_thought_id FROM thought_relations
                WHERE source_thought_id = ?
                UNION
                SELECT relation.target_thought_id
                FROM thought_relations relation JOIN ancestors ON relation.source_thought_id = ancestors.id
            )
            SELECT 1 FROM ancestors WHERE id = ? LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        try bind(relation.targetThoughtID.uuidString, to: 1, in: statement)
        try bind(relation.sourceThoughtID.uuidString, to: 2, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        if result == SQLITE_ROW { throw SQLiteThoughtRepositoryError.cycle }
    }

    private func queryRelations(where clause: String, id: UUID) throws -> [ThoughtRelation] {
        let statement = try prepare("""
            SELECT id, source_thought_id, target_thought_id, relation_type, created_at
            FROM thought_relations WHERE \(clause) ORDER BY created_at ASC, id ASC
            """)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        var output: [ThoughtRelation] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let sourceText = sqlite3_column_text(statement, 1),
                  let targetText = sqlite3_column_text(statement, 2),
                  let typeText = sqlite3_column_text(statement, 3),
                  let relationID = UUID(uuidString: String(cString: idText)),
                  let sourceID = UUID(uuidString: String(cString: sourceText)),
                  let targetID = UUID(uuidString: String(cString: targetText)),
                  let type = ThoughtRelation.RelationType(rawValue: String(cString: typeText)) else {
                throw SQLiteThoughtRepositoryError.invalidRecord
            }
            output.append(ThoughtRelation(
                id: relationID,
                sourceThoughtID: sourceID,
                targetThoughtID: targetID,
                type: type,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return output
    }

    private func queryByID(_ id: UUID) throws -> Thought? {
        try query("SELECT id, body, created_at, updated_at, deleted_at FROM thoughts WHERE id = ? LIMIT 1", bind: {
            try self.bind(id.uuidString, to: 1, in: $0)
        }).first
    }

    private func executeThoughtAuthorInsert(thoughtID: UUID, personaID: UUID, conflictClause: String = "") throws {
        let statement = try prepare("INSERT \(conflictClause) INTO thought_authors (thought_id, persona_id) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(thoughtID.uuidString, to: 1, in: statement)
        try bind(personaID.uuidString, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func queryPersona(id: UUID) throws -> Persona {
        let statement = try prepare("SELECT id, display_name, handle, kind, icon_data, icon_mime_type, created_at, updated_at, deleted_at FROM personas WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteThoughtRepositoryError.invalidRecord }
        return try decodePersona(statement)
    }

    private func queryPersonas(_ clause: String) throws -> [Persona] {
        let statement = try prepare("SELECT id, display_name, handle, kind, icon_data, icon_mime_type, created_at, updated_at, deleted_at FROM personas \(clause) ORDER BY created_at ASC, id ASC")
        defer { sqlite3_finalize(statement) }
        var output: [Persona] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { output.append(try decodePersona(statement)); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw lastError() }
        return output
    }

    private func executePersonaInsert(_ persona: Persona) throws {
        guard ActorHandle.normalize(persona.handle) == persona.handle else { throw SQLiteThoughtRepositoryError.invalidRecord }
        let accountID = try currentLocalAccountID()
        let statement = try prepare("INSERT INTO personas (id, display_name, account_id, handle, kind, icon_data, icon_mime_type, created_at, updated_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(persona.id.uuidString, to: 1, in: statement); try bind(persona.displayName, to: 2, in: statement); try bind(accountID, to: 3, in: statement); try bind(persona.handle, to: 4, in: statement); try bind(persona.kind.rawValue, to: 5, in: statement)
        try bindOptional(persona.iconData, to: 6, in: statement); try bindOptional(persona.iconMIMEType, to: 7, in: statement)
        try bind(persona.createdAt.timeIntervalSince1970, to: 8, in: statement); try bind(persona.updatedAt.timeIntervalSince1970, to: 9, in: statement); try bindOptional(persona.deletedAt?.timeIntervalSince1970, to: 10, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func currentLocalAccountID() throws -> String {
        let statement = try prepare("SELECT account_id FROM personas WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(Persona.defaultHumanID.uuidString, to: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            let value = String(cString: text)
            return value.isEmpty ? Self.localAccountID : value
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return Self.localAccountID
    }

    private func executeAIConfigurationUpsert(_ configuration: AIPersonaConfiguration) throws {
        let statement = try prepare("INSERT INTO ai_persona_configurations (persona_id, role, instructions, auto_reply_enabled, provider, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(persona_id) DO UPDATE SET role = excluded.role, instructions = excluded.instructions, auto_reply_enabled = excluded.auto_reply_enabled, provider = excluded.provider, updated_at = excluded.updated_at")
        defer { sqlite3_finalize(statement) }
        try bind(configuration.personaID.uuidString, to: 1, in: statement); try bind(configuration.role, to: 2, in: statement); try bind(configuration.instructions, to: 3, in: statement); try bind(configuration.autoReplyEnabled ? Int32(1) : Int32(0), to: 4, in: statement); try bind(configuration.provider.rawValue, to: 5, in: statement); try bind(configuration.updatedAt.timeIntervalSince1970, to: 6, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func decodePersona(_ statement: OpaquePointer, columnOffset: Int32 = 0) throws -> Persona {
        guard let idText = sqlite3_column_text(statement, columnOffset), let nameText = sqlite3_column_text(statement, columnOffset + 1), let handleText = sqlite3_column_text(statement, columnOffset + 2),
              let kindText = sqlite3_column_text(statement, columnOffset + 3), let id = UUID(uuidString: String(cString: idText)),
              let kind = PersonaKind(rawValue: String(cString: kindText)) else { throw SQLiteThoughtRepositoryError.invalidRecord }
        let iconData: Data?
        if sqlite3_column_type(statement, columnOffset + 4) == SQLITE_NULL { iconData = nil }
        else if let bytes = sqlite3_column_blob(statement, columnOffset + 4) { iconData = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, columnOffset + 4))) }
        else { iconData = Data() }
        let mime = sqlite3_column_type(statement, columnOffset + 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, columnOffset + 5))
        return Persona(id: id, displayName: String(cString: nameText), handle: String(cString: handleText), kind: kind, iconData: iconData, iconMIMEType: mime,
                       createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, columnOffset + 6)),
                       updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, columnOffset + 7)),
                       deletedAt: sqlite3_column_type(statement, columnOffset + 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, columnOffset + 8)))
    }

    private func query(_ sql: String, bind binder: (OpaquePointer) throws -> Void = { _ in }) throws -> [Thought] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binder(statement)
        var output: [Thought] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let bodyText = sqlite3_column_text(statement, 1),
                  let id = UUID(uuidString: String(cString: idText)) else {
                throw SQLiteThoughtRepositoryError.invalidRecord
            }
            output.append(Thought(
                id: id,
                body: String(cString: bodyText),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                deletedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return output
    }

    private func scalarInt(_ sql: String) throws -> Int32 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return sqlite3_column_int(statement, 0)
    }

    private func queryKnowledgeDrafts(_ sql: String, bind binder: (OpaquePointer) throws -> Void = { _ in }) throws -> [KnowledgeDraft] {
        let s = try prepare(sql); defer { sqlite3_finalize(s) }; try binder(s); var values: [KnowledgeDraft] = []; var result = sqlite3_step(s); let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: text(s,0)), let type = KnowledgeDraftType(rawValue:text(s,3)), let source = KnowledgeDraftSource(rawValue:text(s,6)), let status = KnowledgeDraftReviewStatus(rawValue:text(s,8)), let sync = KnowledgeGitHubSyncStatus(rawValue:text(s,9)), let tagsData = text(s,5).data(using:.utf8), let provenanceData = text(s,7).data(using:.utf8), let relatedData = text(s,18).data(using:.utf8) else { throw SQLiteThoughtRepositoryError.invalidRecord }
            func date(_ column:Int32)->Date? { sqlite3_column_type(s,column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970:sqlite3_column_double(s,column)) }
            values.append(.init(id:id,title:text(s,1),type:type,project:text(s,4),tags:try decoder.decode([String].self,from:tagsData),source:source,createdAt:Date(timeIntervalSince1970:sqlite3_column_double(s,11)),updatedAt:Date(timeIntervalSince1970:sqlite3_column_double(s,12)),body:text(s,2),relatedDocuments:try decoder.decode([ExternalBrainRetrievedChunk].self,from:relatedData),savedPath:optionalText(s,10),reviewStatus:status,syncStatus:sync,provenance:try decoder.decode(KnowledgeDraftProvenance.self,from:provenanceData),approvedAt:date(13),promotedAt:date(14),rejectedAt:date(15),knowledgePath:optionalText(s,16),knowledgeSHA:optionalText(s,17)))
            result = sqlite3_step(s)
        }
        guard result == SQLITE_DONE else { throw lastError() }; return values
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement,column).map { String(cString:$0) } ?? "" }
    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? { sqlite3_column_type(statement,column) == SQLITE_NULL ? nil : text(statement,column) }
    private func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? { sqlite3_column_type(statement,column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970:sqlite3_column_double(statement,column)) }

    private func secondBrainAppExists(id: UUID) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM secondbrain_apps WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result == SQLITE_ROW
    }

    private func defaultAppSeedHistoryExists(id: UUID) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM secondbrain_default_app_seed_history WHERE app_id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result == SQLITE_ROW
    }

    private func seedDefaultAppsIfNeededLocked(now: Date) throws -> (insertedCount: Int, changed: Bool) {
        let defaultApps = try SecondBrainDefaultApps.all(createdAt: now)
        var insertedCount = 0
        var changed = false
        try transaction {
            for app in defaultApps {
                guard try !defaultAppSeedHistoryExists(id: app.id) else { continue }
                if try !secondBrainAppExists(id: app.id) {
                    try executeSecondBrainAppInsert(app)
                    insertedCount += 1
                }
                let statement = try prepare("INSERT INTO secondbrain_default_app_seed_history(app_id, catalog_version, seeded_at) VALUES (?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                try bind(app.id.uuidString, to: 1, in: statement)
                try bind(Int32(SecondBrainDefaultApps.catalogVersion), to: 2, in: statement)
                try bind(now.timeIntervalSince1970, to: 3, in: statement)
                try stepDone(statement)
                changed = true
            }
        }
        return (insertedCount, changed)
    }

    private func executeSecondBrainAppInsert(_ app: SecondBrainApp) throws {
        let statement = try prepare("INSERT INTO secondbrain_apps(id, name, description, icon, kind, launch_target_type, launch_target_value, category, is_favorite, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bindSecondBrainApp(app, to: statement)
        try stepDone(statement)
    }

    private func bindSecondBrainApp(_ app: SecondBrainApp, to statement: OpaquePointer) throws {
        try bind(app.id.uuidString, to: 1, in: statement)
        try bind(app.name, to: 2, in: statement)
        try bind(app.description, to: 3, in: statement)
        try bind(app.icon, to: 4, in: statement)
        try bind(app.kind.rawValue, to: 5, in: statement)
        try bind(app.launchTarget.storageKind.rawValue, to: 6, in: statement)
        try bind(app.launchTarget.storageValue, to: 7, in: statement)
        try bind(app.category, to: 8, in: statement)
        try bind(app.isFavorite ? Int32(1) : Int32(0), to: 9, in: statement)
        try bind(Int64(app.sortOrder), to: 10, in: statement)
        try bind(app.createdAt.timeIntervalSince1970, to: 11, in: statement)
        try bind(app.updatedAt.timeIntervalSince1970, to: 12, in: statement)
    }

    private func querySecondBrainApps(_ sql: String, bind binder: (OpaquePointer) throws -> Void = { _ in }) throws -> [SecondBrainApp] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binder(statement)
        var apps: [SecondBrainApp] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)),
                  let kind = SecondBrainAppKind(rawValue: text(statement, 4)),
                  let targetKind = SecondBrainAppLaunchTarget.StorageKind(rawValue: text(statement, 5)) else {
                throw SQLiteThoughtRepositoryError.invalidRecord
            }
            let target = try SecondBrainAppLaunchTarget.restoring(storageKind: targetKind, value: text(statement, 6))
            let app = try SecondBrainApp(
                id: id,
                name: text(statement, 1),
                description: text(statement, 2),
                icon: text(statement, 3),
                kind: kind,
                launchTarget: target,
                category: text(statement, 7),
                isFavorite: sqlite3_column_int(statement, 8) != 0,
                sortOrder: Int(sqlite3_column_int64(statement, 9)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
            )
            apps.append(app)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return apps
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteThoughtRepositoryError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError() }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw lastError() }
    }

    private func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw lastError() }
    }

    private func bindOptional(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        if let value { try bind(value, to: index, in: statement) }
        else if sqlite3_bind_null(statement, index) != SQLITE_OK { throw lastError() }
    }

    private func bindOptional(_ value: Double?, to index: Int32, in statement: OpaquePointer) throws {
        if let value { try bind(value, to: index, in: statement) }
        else if sqlite3_bind_null(statement, index) != SQLITE_OK { throw lastError() }
    }

    private func bindOptional(_ value: Data?, to index: Int32, in statement: OpaquePointer) throws {
        guard let value else { if sqlite3_bind_null(statement, index) != SQLITE_OK { throw lastError() }; return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func queryTag(normalizedName: String) throws -> ThoughtTag? {
        try queryTags(
            "SELECT id, name, normalized_name, created_at FROM tags WHERE normalized_name = ? LIMIT 1",
            bind: { try self.bind(normalizedName, to: 1, in: $0) }
        ).first
    }

    private func queryTags(_ sql: String, bind binder: (OpaquePointer) throws -> Void = { _ in }) throws -> [ThoughtTag] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binder(statement)
        var output: [ThoughtTag] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let nameText = sqlite3_column_text(statement, 1),
                  let normalizedText = sqlite3_column_text(statement, 2),
                  let id = UUID(uuidString: String(cString: idText)) else {
                throw SQLiteThoughtRepositoryError.invalidRecord
            }
            output.append(ThoughtTag(
                id: id,
                name: String(cString: nameText),
                normalizedName: String(cString: normalizedText),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return output
    }

    private func decodeReviewSummary(_ statement: OpaquePointer) throws -> ReviewSummary {
        guard let idText = sqlite3_column_text(statement, 0),
              let contentText = sqlite3_column_text(statement, 3),
              let providerText = sqlite3_column_text(statement, 5),
              let modelText = sqlite3_column_text(statement, 6),
              let id = UUID(uuidString: String(cString: idText)) else {
            throw SQLiteThoughtRepositoryError.invalidRecord
        }
        return ReviewSummary(
            id: id,
            periodStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            periodEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            content: String(cString: contentText),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            provider: String(cString: providerText),
            model: String(cString: modelText),
            promptVersion: Int(sqlite3_column_int(statement, 7)),
            thoughtCount: Int(sqlite3_column_int(statement, 8))
        )
    }

    private func decodeDailySummary(_ statement: OpaquePointer) throws -> DailySummary {
        guard let idText = sqlite3_column_text(statement, 0), let jsonText = sqlite3_column_text(statement, 3),
              let providerText = sqlite3_column_text(statement, 5), let modelText = sqlite3_column_text(statement, 6),
              let id = UUID(uuidString: String(cString: idText)),
              let data = String(cString: jsonText).data(using: .utf8) else { throw SQLiteThoughtRepositoryError.invalidRecord }
        let content = try JSONDecoder().decode(DailySummaryContent.self, from: data)
        return DailySummary(id: id, dayStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), dayEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), content: content, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), provider: String(cString: providerText), model: String(cString: modelText), promptVersion: Int(sqlite3_column_int(statement, 7)), thoughtCount: Int(sqlite3_column_int(statement, 8)))
    }

    private func decodeWeeklySummary(_ statement: OpaquePointer) throws -> WeeklySummary {
        guard let id = UUID(uuidString: text(statement, 0)), let data = text(statement, 3).data(using: .utf8) else { throw SQLiteThoughtRepositoryError.invalidRecord }
        return WeeklySummary(id: id, weekStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), weekEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), content: try JSONDecoder().decode(WeeklySummaryContent.self, from: data), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), provider: text(statement, 5), model: text(statement, 6), promptVersion: Int(sqlite3_column_int(statement, 7)), thoughtCount: Int(sqlite3_column_int(statement, 8)))
    }

    private func decodeWeeklyPlan(_ statement: OpaquePointer) throws -> WeeklyPlan {
        guard let id = UUID(uuidString: text(statement, 0)), let sourceID = UUID(uuidString: text(statement, 3)), let data = text(statement, 4).data(using: .utf8) else { throw SQLiteThoughtRepositoryError.invalidRecord }
        return WeeklyPlan(id: id, targetWeekStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), targetWeekEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), sourceSummaryID: sourceID, content: try JSONDecoder().decode(WeeklyPlanContent.self, from: data), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)), provider: text(statement, 7), model: text(statement, 8), promptVersion: Int(sqlite3_column_int(statement, 9)))
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let result = String(data: data, encoding: .utf8) else { throw SQLiteThoughtRepositoryError.invalidRecord }
        return result
    }

    private func bind(_ value: Int32, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int(statement, index, value) == SQLITE_OK else { throw lastError() }
    }

    private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw lastError() }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func lastError() -> SQLiteThoughtRepositoryError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed")
    }

    private func sqliteErrorMessage(fallback error: Error) -> String {
        guard let database else { return "database is closed; \(error.localizedDescription)" }
        let message = String(cString: sqlite3_errmsg(database))
        let code = sqlite3_errcode(database)
        let extendedCode = sqlite3_extended_errcode(database)
        return "sqlite3_errmsg=\(message) (code=\(code), extended=\(extendedCode)); \(error.localizedDescription)"
    }

    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
