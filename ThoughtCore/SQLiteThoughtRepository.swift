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

public final class SQLiteThoughtRepository: ThoughtRepository, AuthoredThoughtRepository, ThoughtMentionRepository, AIPersonaRepository, ThoughtRelationRepository, ThoughtContinuationRepository, ThoughtTagRepository, ThoughtAnalyticsRepository, ReviewSummaryRepository, DailySummaryRepository, PersonaRepository, @unchecked Sendable {
    public static let schemaVersion: Int32 = 11

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
        try lock.withLock {
            try transaction {
                try executeThoughtInsert(thought, conflictClause: ""); try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: authorPersonaID)
                if let mentionedPersonaID {
                    let statement = try prepare("INSERT INTO thought_mentions (thought_id, persona_id, created_at) SELECT ?, id, ? FROM personas WHERE id = ? AND kind = 'ai' AND deleted_at IS NULL")
                    defer { sqlite3_finalize(statement) }
                    try bind(thought.id.uuidString, to: 1, in: statement); try bind(thought.createdAt.timeIntervalSince1970, to: 2, in: statement); try bind(mentionedPersonaID.uuidString, to: 3, in: statement)
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
            let statement = try prepare("SELECT m.thought_id, p.id, p.display_name, p.kind, p.icon_data, p.icon_mime_type, p.created_at, p.updated_at, p.deleted_at, p.account_id, p.biography FROM thought_mentions m JOIN personas p ON p.id = m.persona_id WHERE m.thought_id IN (\(placeholders))")
            defer { sqlite3_finalize(statement) }
            for (offset, id) in thoughtIDs.enumerated() { try bind(id.uuidString, to: Int32(offset + 1), in: statement) }
            var output: [UUID: Persona] = [:]; var result = sqlite3_step(statement)
            while result == SQLITE_ROW { guard let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) else { throw SQLiteThoughtRepositoryError.invalidRecord }; output[id] = try decodePersona(statement, columnOffset: 1); result = sqlite3_step(statement) }
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

    public func fetchThoughts(authoredBy personaID: UUID) throws -> [Thought] {
        try lock.withLock { try query("SELECT t.id, t.body, t.created_at, t.updated_at, t.deleted_at FROM thoughts t JOIN thought_authors a ON a.thought_id = t.id WHERE a.persona_id = ? AND t.deleted_at IS NULL ORDER BY t.created_at DESC, t.id DESC", bind: { try self.bind(personaID.uuidString, to: 1, in: $0) }) }
    }

    public func fetchPersona(for thoughtID: UUID) throws -> Persona? {
        try lock.withLock {
            let statement = try prepare("""
                SELECT p.id, p.display_name, p.kind, p.icon_data, p.icon_mime_type, p.created_at, p.updated_at, p.deleted_at, p.account_id, p.biography
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
                SELECT a.thought_id, p.id, p.display_name, p.kind, p.icon_data, p.icon_mime_type, p.created_at, p.updated_at, p.deleted_at, p.account_id, p.biography
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
            let statement = try prepare("UPDATE personas SET display_name = ?, account_id = ?, biography = ?, icon_data = ?, icon_mime_type = ?, updated_at = ?, deleted_at = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(persona.displayName, to: 1, in: statement)
            try bind(persona.accountID, to: 2, in: statement); try bind(persona.biography, to: 3, in: statement)
            try bindOptional(persona.iconData, to: 4, in: statement)
            try bindOptional(persona.iconMIMEType, to: 5, in: statement)
            try bind(persona.updatedAt.timeIntervalSince1970, to: 6, in: statement)
            try bindOptional(persona.deletedAt?.timeIntervalSince1970, to: 7, in: statement)
            try bind(persona.id.uuidString, to: 8, in: statement)
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
            let statement = try prepare("SELECT persona_id, role, instructions, updated_at, connection_id FROM ai_persona_configurations")
            defer { sqlite3_finalize(statement) }
            var output: [UUID: AIPersonaConfiguration] = [:]; var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0), let roleText = sqlite3_column_text(statement, 1), let instructionsText = sqlite3_column_text(statement, 2), let id = UUID(uuidString: String(cString: idText)) else { throw SQLiteThoughtRepositoryError.invalidRecord }
                let connectionID = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : UUID(uuidString: String(cString: sqlite3_column_text(statement, 4)))
                output[id] = AIPersonaConfiguration(personaID: id, role: String(cString: roleText), instructions: String(cString: instructionsText), connectionID: connectionID, updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))); result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }; return output
        }
    }

    public func saveAIConfiguration(_ configuration: AIPersonaConfiguration) throws {
        try lock.withLock { try executeAIConfigurationUpsert(configuration); createRollingBackupIfPossible() }
    }

    public func createAIPersona(_ persona: Persona, configuration: AIPersonaConfiguration) throws {
        try lock.withLock { try transaction { try executePersonaInsert(persona); try executeAIConfigurationUpsert(configuration) }; createRollingBackupIfPossible() }
    }

    public func saveGeneratedThought(_ thought: Thought, authorPersonaID: UUID, generation: AIPostGeneration) throws {
        try lock.withLock {
            try transaction {
                let author = try queryPersona(id: authorPersonaID)
                guard author.kind == .ai, author.deletedAt == nil else { throw SQLiteThoughtRepositoryError.invalidRecord }
                try executeThoughtInsert(thought, conflictClause: ""); try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: authorPersonaID)
                let statement = try prepare("INSERT INTO ai_post_generations (thought_id, persona_id, user_request, provider, model, prompt_version, generated_at, request_id, parent_thought_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                try bind(generation.thoughtID.uuidString, to: 1, in: statement); try bind(generation.personaID.uuidString, to: 2, in: statement); try bind(generation.userRequest, to: 3, in: statement); try bind(generation.provider, to: 4, in: statement); try bind(generation.model, to: 5, in: statement); try bind(Int32(generation.promptVersion), to: 6, in: statement); try bind(generation.generatedAt.timeIntervalSince1970, to: 7, in: statement); try bindOptional(generation.requestID?.uuidString, to: 8, in: statement); try bindOptional(generation.parentThoughtID?.uuidString, to: 9, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            createRollingBackupIfPossible()
        }
    }

    public func fetchAIConnections() throws -> [AIConnection] {
        try lock.withLock {
            let statement = try prepare("SELECT id, label, provider, model, is_enabled, created_at, updated_at FROM ai_connections ORDER BY created_at, id")
            defer { sqlite3_finalize(statement) }
            var values: [AIConnection] = []; var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: idText)), let label = sqlite3_column_text(statement, 1), let provider = sqlite3_column_text(statement, 2), let model = sqlite3_column_text(statement, 3) else { throw SQLiteThoughtRepositoryError.invalidRecord }
                values.append(AIConnection(id: id, label: String(cString: label), provider: String(cString: provider), model: String(cString: model), isEnabled: sqlite3_column_int(statement, 4) != 0, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw lastError() }; return values
        }
    }

    public func saveAIConnection(_ connection: AIConnection) throws {
        try lock.withLock {
            let statement = try prepare("INSERT INTO ai_connections(id, label, provider, model, is_enabled, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET label=excluded.label, provider=excluded.provider, model=excluded.model, is_enabled=excluded.is_enabled, updated_at=excluded.updated_at")
            defer { sqlite3_finalize(statement) }
            try bind(connection.id.uuidString, to: 1, in: statement); try bind(connection.label, to: 2, in: statement); try bind(connection.provider, to: 3, in: statement); try bind(connection.model, to: 4, in: statement); try bind(Int32(connection.isEnabled ? 1 : 0), to: 5, in: statement); try bind(connection.createdAt.timeIntervalSince1970, to: 6, in: statement); try bind(connection.updatedAt.timeIntervalSince1970, to: 7, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }; createRollingBackupIfPossible()
        }
    }

    public func saveGeneratedContinuation(_ thought: Thought, parentThoughtID: UUID, authorPersonaID: UUID, generation: AIPostGeneration) throws {
        try lock.withLock {
            try transaction {
                let author = try queryPersona(id: authorPersonaID)
                guard author.kind == .ai, author.deletedAt == nil, try queryByID(parentThoughtID)?.deletedAt == nil else { throw SQLiteThoughtRepositoryError.invalidRecord }
                let relation = ThoughtRelation(sourceThoughtID: thought.id, targetThoughtID: parentThoughtID, createdAt: thought.createdAt)
                try executeThoughtInsert(thought, conflictClause: ""); try executeThoughtAuthorInsert(thoughtID: thought.id, personaID: authorPersonaID); try validate(relation); try executeRelationInsert(relation)
                let statement = try prepare("INSERT INTO ai_post_generations (thought_id, persona_id, user_request, provider, model, prompt_version, generated_at, request_id, parent_thought_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                try bind(thought.id.uuidString, to: 1, in: statement); try bind(authorPersonaID.uuidString, to: 2, in: statement); try bind(generation.userRequest, to: 3, in: statement); try bind(generation.provider, to: 4, in: statement); try bind(generation.model, to: 5, in: statement); try bind(Int32(generation.promptVersion), to: 6, in: statement); try bind(generation.generatedAt.timeIntervalSince1970, to: 7, in: statement); try bindOptional(generation.requestID?.uuidString, to: 8, in: statement); try bind(parentThoughtID.uuidString, to: 9, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            createRollingBackupIfPossible()
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
                try execute("CREATE TABLE ai_post_generations (thought_id TEXT PRIMARY KEY NOT NULL REFERENCES thoughts(id), persona_id TEXT NOT NULL REFERENCES personas(id), user_request TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, prompt_version INTEGER NOT NULL, generated_at REAL NOT NULL)")
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
                try execute("ALTER TABLE personas ADD COLUMN account_id TEXT NOT NULL DEFAULT ''")
                try execute("ALTER TABLE personas ADD COLUMN biography TEXT NOT NULL DEFAULT ''")
                try execute("UPDATE personas SET account_id = 'owner' WHERE id = '\(Persona.defaultHumanID.uuidString)'")
                try execute("UPDATE personas SET account_id = 'ai_' || lower(substr(replace(id, '-', ''), 1, 8)) WHERE kind = 'ai' AND account_id = ''")
                try execute("CREATE UNIQUE INDEX personas_account_id_unique ON personas(account_id)")
                try execute("PRAGMA user_version = 9")
            }
        }
        if version < 10 {
            try transaction {
                try execute("CREATE TABLE ai_connections (id TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, is_enabled INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
                try execute("ALTER TABLE ai_persona_configurations ADD COLUMN connection_id TEXT NULL REFERENCES ai_connections(id)")
                let id = "00000000-0000-0000-0000-000000000010"
                let now = Date().timeIntervalSince1970
                let statement = try prepare("INSERT INTO ai_connections(id, label, provider, model, is_enabled, created_at, updated_at) VALUES (?, 'Firebase AI Logic', 'firebase-ai-logic', 'gemini-3.7-flash', 1, ?, ?)")
                defer { sqlite3_finalize(statement) }
                try bind(id, to: 1, in: statement); try bind(now, to: 2, in: statement); try bind(now, to: 3, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
                try execute("UPDATE ai_persona_configurations SET connection_id = '\(id)' WHERE connection_id IS NULL")
                try execute("PRAGMA user_version = 10")
            }
        }
        if version < 11 {
            try transaction {
                try execute("ALTER TABLE ai_post_generations ADD COLUMN request_id TEXT NULL")
                try execute("ALTER TABLE ai_post_generations ADD COLUMN parent_thought_id TEXT NULL REFERENCES thoughts(id)")
                try execute("CREATE UNIQUE INDEX ai_post_generations_request_unique ON ai_post_generations(request_id) WHERE request_id IS NOT NULL")
                try execute("PRAGMA user_version = 11")
            }
        }
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
        let statement = try prepare("""
            WITH RECURSIVE ancestors(id) AS (
                SELECT target_thought_id FROM thought_relations
                WHERE source_thought_id = ? AND relation_type = 'continues'
                UNION
                SELECT relation.target_thought_id
                FROM thought_relations relation JOIN ancestors ON relation.source_thought_id = ancestors.id
                WHERE relation.relation_type = 'continues'
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
        let statement = try prepare("SELECT id, display_name, kind, icon_data, icon_mime_type, created_at, updated_at, deleted_at, account_id, biography FROM personas WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteThoughtRepositoryError.invalidRecord }
        return try decodePersona(statement)
    }

    private func queryPersonas(_ clause: String) throws -> [Persona] {
        let statement = try prepare("SELECT id, display_name, kind, icon_data, icon_mime_type, created_at, updated_at, deleted_at, account_id, biography FROM personas \(clause) ORDER BY created_at ASC, id ASC")
        defer { sqlite3_finalize(statement) }
        var output: [Persona] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { output.append(try decodePersona(statement)); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw lastError() }
        return output
    }

    private func executePersonaInsert(_ persona: Persona) throws {
        let statement = try prepare("INSERT INTO personas (id, display_name, kind, account_id, biography, icon_data, icon_mime_type, created_at, updated_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(persona.id.uuidString, to: 1, in: statement); try bind(persona.displayName, to: 2, in: statement); try bind(persona.kind.rawValue, to: 3, in: statement); try bind(persona.accountID, to: 4, in: statement); try bind(persona.biography, to: 5, in: statement)
        try bindOptional(persona.iconData, to: 6, in: statement); try bindOptional(persona.iconMIMEType, to: 7, in: statement)
        try bind(persona.createdAt.timeIntervalSince1970, to: 8, in: statement); try bind(persona.updatedAt.timeIntervalSince1970, to: 9, in: statement); try bindOptional(persona.deletedAt?.timeIntervalSince1970, to: 10, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func executeAIConfigurationUpsert(_ configuration: AIPersonaConfiguration) throws {
        let statement = try prepare("INSERT INTO ai_persona_configurations (persona_id, role, instructions, updated_at, connection_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(persona_id) DO UPDATE SET role = excluded.role, instructions = excluded.instructions, updated_at = excluded.updated_at, connection_id = excluded.connection_id")
        defer { sqlite3_finalize(statement) }
        try bind(configuration.personaID.uuidString, to: 1, in: statement); try bind(configuration.role, to: 2, in: statement); try bind(configuration.instructions, to: 3, in: statement); try bind(configuration.updatedAt.timeIntervalSince1970, to: 4, in: statement); try bindOptional(configuration.connectionID?.uuidString, to: 5, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func decodePersona(_ statement: OpaquePointer, columnOffset: Int32 = 0) throws -> Persona {
        guard let idText = sqlite3_column_text(statement, columnOffset), let nameText = sqlite3_column_text(statement, columnOffset + 1),
              let kindText = sqlite3_column_text(statement, columnOffset + 2), let id = UUID(uuidString: String(cString: idText)),
              let kind = PersonaKind(rawValue: String(cString: kindText)) else { throw SQLiteThoughtRepositoryError.invalidRecord }
        let iconData: Data?
        if sqlite3_column_type(statement, columnOffset + 3) == SQLITE_NULL { iconData = nil }
        else if let bytes = sqlite3_column_blob(statement, columnOffset + 3) { iconData = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, columnOffset + 3))) }
        else { iconData = Data() }
        let mime = sqlite3_column_type(statement, columnOffset + 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, columnOffset + 4))
        guard let accountText = sqlite3_column_text(statement, columnOffset + 8), let biographyText = sqlite3_column_text(statement, columnOffset + 9) else { throw SQLiteThoughtRepositoryError.invalidRecord }
        return Persona(id: id, displayName: String(cString: nameText), accountID: String(cString: accountText), biography: String(cString: biographyText), kind: kind, iconData: iconData, iconMIMEType: mime,
                       createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, columnOffset + 5)),
                       updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, columnOffset + 6)),
                       deletedAt: sqlite3_column_type(statement, columnOffset + 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, columnOffset + 7)))
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

    private func bind(_ value: Int32, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int(statement, index, value) == SQLITE_OK else { throw lastError() }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func lastError() -> SQLiteThoughtRepositoryError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed")
    }

    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
