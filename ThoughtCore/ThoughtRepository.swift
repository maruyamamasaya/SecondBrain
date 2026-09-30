import Foundation

public protocol ThoughtRepository: Sendable {
    func create(_ thought: Thought) throws
    func fetchTimeline() throws -> [Thought]
    /// 任意cursorより前の未削除ThoughtをTimeline降順で返す。
    /// 実装は`(createdAt, id)`を安定したkeyset cursorとして扱う。
    func fetchTimelinePage(limit: Int, before cursor: Thought?) throws -> [Thought]
    /// Searches active Thought bodies using a literal, trimmed substring.
    /// An empty normalized query returns no results.
    func search(query: String) throws -> [Thought]
    func fetchByID(_ id: UUID) throws -> Thought?
    func fetchAll() throws -> [Thought]
    /// Returns active Thoughts in ascending creation order. `from` is inclusive
    /// and `to` is exclusive.
    func fetchThoughts(from startDate: Date, to endDate: Date) throws -> [Thought]
    /// Returns only active Thoughts authored by a Human Persona, in ascending
    /// creation order. This is the source boundary for Daily Summary.
    func fetchHumanThoughts(from startDate: Date, to endDate: Date) throws -> [Thought]
    @discardableResult func softDelete(id: UUID, at date: Date) throws -> Bool
}

/// A small repository useful for previews and domain tests. SQLite is the app's durable store.
public final class MemoryThoughtRepository: ThoughtRepository, AuthoredThoughtRepository, ThoughtMentionRepository, AIPersonaRepository, AIThoughtReplyRepository, HumanThoughtReplyRepository, ThoughtRelationRepository, ThoughtContinuationRepository, ThoughtTagRepository, ThoughtAnalyticsRepository, ReviewSummaryRepository, DailySummaryRepository, WeeklyReviewRepository, SecondBrainAppRepository, PersonaRepository, @unchecked Sendable {
    private var records: [Thought]
    private var relations: [ThoughtRelation]
    private var summaries: [ReviewSummary]
    private var dailySummaries: [DailySummary]
    private var weeklySummaries: [WeeklySummary] = []
    private var weeklyPlans: [WeeklyPlan] = []
    private var tags: [ThoughtTag]
    private var thoughtTagIDs: [UUID: Set<UUID>]
    private var defaultPersona = Persona(id: Persona.defaultHumanID, displayName: "自分", handle: "myself", kind: .human)
    private var personas: [UUID: Persona] = [:]
    private var authorIDs: [UUID: UUID] = [:]
    private var aiConfigurations: [UUID: AIPersonaConfiguration] = [:]
    private var aiGenerations: [UUID: AIPostGeneration] = [:]
    private var mentionsByThoughtID: [UUID: [ThoughtMention]] = [:]
    private var secondBrainApps: [UUID: SecondBrainApp] = [:]
    private var seededDefaultAppIDs: Set<UUID> = []
    private let lock = NSLock()

    public init(records: [Thought] = [], relations: [ThoughtRelation] = [], summaries: [ReviewSummary] = [], dailySummaries: [DailySummary] = [], tags: [ThoughtTag] = [], thoughtTagIDs: [UUID: Set<UUID>] = [:]) {
        self.records = records
        self.relations = relations
        self.summaries = summaries
        self.dailySummaries = dailySummaries
        self.tags = tags
        self.thoughtTagIDs = thoughtTagIDs
        personas[Persona.defaultHumanID] = defaultPersona
        authorIDs = Dictionary(uniqueKeysWithValues: records.map { ($0.id, Persona.defaultHumanID) })
        let defaultApps = (try? SecondBrainDefaultApps.all()) ?? []
        secondBrainApps = Dictionary(uniqueKeysWithValues: defaultApps.map { ($0.id, $0) })
        seededDefaultAppIDs = Set(defaultApps.map(\.id))
    }

    public func create(_ thought: Thought) throws {
        try create(thought, authorPersonaID: Persona.defaultHumanID)
    }

    public func create(_ thought: Thought, authorPersonaID: UUID) throws {
        try lock.withLock {
            guard personas[authorPersonaID]?.deletedAt == nil else { throw CocoaError(.fileNoSuchFile) }
            records.append(thought); authorIDs[thought.id] = authorPersonaID
        }
    }
    public func create(_ thought: Thought, authorPersonaID: UUID, mentionedPersonaID: UUID?) throws {
        let mentions: [ThoughtMention] = try lock.withLock {
            guard let mentionedPersonaID, let persona = personas[mentionedPersonaID], persona.deletedAt == nil else { return [] }
            let token = "@\(persona.handle)", range = (thought.body as NSString).range(of: token, options: .caseInsensitive)
            return [ThoughtMention(thoughtID: thought.id, personaID: persona.id, handleSnapshot: persona.handle, rangeLocation: range.location == NSNotFound ? 0 : range.location, rangeLength: range.location == NSNotFound ? 0 : range.length, createdAt: thought.createdAt)]
        }
        try create(thought, authorPersonaID: authorPersonaID, mentions: mentions)
    }
    public func create(_ thought: Thought, authorPersonaID: UUID, mentions: [ThoughtMention]) throws {
        try lock.withLock {
            guard personas[authorPersonaID]?.deletedAt == nil else { throw CocoaError(.fileNoSuchFile) }
            for mention in mentions { guard mention.thoughtID == thought.id, personas[mention.personaID]?.deletedAt == nil else { throw CocoaError(.fileNoSuchFile) } }
            mentionsByThoughtID[thought.id] = mentions
            records.append(thought); authorIDs[thought.id] = authorPersonaID
        }
    }
    public func fetchMentionedPersonas(for thoughtIDs: [UUID]) throws -> [UUID: Persona] { lock.withLock { Dictionary(uniqueKeysWithValues: thoughtIDs.compactMap { id in mentionsByThoughtID[id]?.first.flatMap { personas[$0.personaID] }.map { (id, $0) } }) } }
    public func fetchMentions(for thoughtIDs: [UUID]) throws -> [UUID: [ThoughtMention]] { lock.withLock {
        Dictionary(uniqueKeysWithValues: thoughtIDs.compactMap { thoughtID in
            guard let values = mentionsByThoughtID[thoughtID] else { return nil }
            return (thoughtID, values)
        })
    } }

    public func fetchDefaultHumanPersona() throws -> Persona { lock.withLock { defaultPersona } }
    public func fetchPersonas(includeInactive: Bool) throws -> [Persona] { lock.withLock { personas.values.filter { includeInactive || $0.deletedAt == nil }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt } } }
    public func fetchPersona(for thoughtID: UUID) throws -> Persona? {
        lock.withLock { authorIDs[thoughtID].flatMap { personas[$0] } }
    }
    public func fetchPersonas(for thoughtIDs: [UUID]) throws -> [UUID: Persona] { lock.withLock { Dictionary(uniqueKeysWithValues: thoughtIDs.compactMap { id in authorIDs[id].flatMap { personas[$0] }.map { (id, $0) } }) } }
    public func createPersona(_ persona: Persona) throws { try lock.withLock { guard personas[persona.id] == nil, ActorHandle.normalize(persona.handle) == persona.handle, !personas.values.contains(where: { $0.handle == persona.handle }) else { throw CocoaError(.fileWriteFileExists) }; personas[persona.id] = persona } }
    public func updatePersona(_ persona: Persona) throws {
        try lock.withLock { guard ActorHandle.normalize(persona.handle) == persona.handle, !personas.values.contains(where: { $0.id != persona.id && $0.handle == persona.handle }) else { throw CocoaError(.fileWriteFileExists) }; personas[persona.id] = persona; if persona.id == Persona.defaultHumanID { defaultPersona = persona } }
    }
    public func deactivatePersona(id: UUID, at date: Date) throws -> Bool { lock.withLock { guard id != Persona.defaultHumanID, var persona = personas[id], persona.deletedAt == nil else { return false }; persona.deletedAt = date; persona.updatedAt = date; personas[id] = persona; return true } }
    public func fetchAIConfigurations() throws -> [UUID: AIPersonaConfiguration] { lock.withLock { aiConfigurations } }
    public func saveAIConfiguration(_ configuration: AIPersonaConfiguration) throws { lock.withLock { aiConfigurations[configuration.personaID] = configuration } }
    public func createAIPersona(_ persona: Persona, configuration: AIPersonaConfiguration) throws { try lock.withLock { guard persona.kind == .ai, persona.id == configuration.personaID, personas[persona.id] == nil, ActorHandle.normalize(persona.handle) == persona.handle, !personas.values.contains(where: { $0.handle == persona.handle }) else { throw CocoaError(.fileWriteFileExists) }; personas[persona.id] = persona; aiConfigurations[persona.id] = configuration } }
    public func saveGeneratedThought(_ thought: Thought, authorPersonaID: UUID, generation: AIPostGeneration) throws { try lock.withLock { guard personas[authorPersonaID]?.deletedAt == nil, aiConfigurations[authorPersonaID] != nil, generation.thoughtID == thought.id, generation.personaID == authorPersonaID, generation.kind == .standalone, generation.replyTargetThoughtID == nil else { throw CocoaError(.fileNoSuchFile) }; records.append(thought); authorIDs[thought.id] = authorPersonaID; aiGenerations[thought.id] = generation } }
    public func saveGeneratedReply(_ thought: Thought, authorPersonaID: UUID, targetThoughtID: UUID, generation: AIPostGeneration, relationID: UUID) throws { try lock.withLock {
        guard personas[authorPersonaID]?.kind == .ai, personas[authorPersonaID]?.deletedAt == nil, aiConfigurations[authorPersonaID] != nil,
              let target = records.first(where: { $0.id == targetThoughtID }), target.deletedAt == nil,
              generation.thoughtID == thought.id, generation.personaID == authorPersonaID, generation.kind == .reply, generation.replyTargetThoughtID == targetThoughtID else { throw CocoaError(.fileNoSuchFile) }
        guard !aiGenerations.values.contains(where: { $0.kind == .reply && $0.replyTargetThoughtID == targetThoughtID && $0.personaID == authorPersonaID }) else { throw AIPostError.duplicateReply }
        let relation = ThoughtRelation(id: relationID, sourceThoughtID: thought.id, targetThoughtID: targetThoughtID, type: .repliesTo, createdAt: thought.createdAt)
        try validate(relation, includingSource: thought.id)
        records.append(thought); authorIDs[thought.id] = authorPersonaID; aiGenerations[thought.id] = generation; relations.append(relation)
    } }
    public func fetchAIReplies(to thoughtID: UUID) throws -> [Thought] { try lock.withLock {
        let ids = Set(relations.filter { $0.type == .repliesTo && $0.targetThoughtID == thoughtID }.map(\.sourceThoughtID))
        return records.filter { ids.contains($0.id) && $0.deletedAt == nil }.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt < rhs.createdAt
        }
    } }
    public func fetchReplyTargets(for thoughtIDs: [UUID]) throws -> [UUID: UUID] { try lock.withLock {
        let ids = Set(thoughtIDs); return Dictionary(uniqueKeysWithValues: relations.filter { $0.type == .repliesTo && ids.contains($0.sourceThoughtID) }.map { ($0.sourceThoughtID, $0.targetThoughtID) })
    } }
    public func fetchAIPostGeneration(for thoughtID: UUID) throws -> AIPostGeneration? { lock.withLock { aiGenerations[thoughtID] } }
    public func fetchRecentAIStatements(personaID: UUID, limit: Int) throws -> [Thought] { lock.withLock {
        guard limit > 0 else { return [] }
        return records.filter { authorIDs[$0.id] == personaID && $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map { $0 }
    } }
    public func fetchActiveAIReplyPersona(id: UUID) throws -> Persona? { lock.withLock { guard let persona = personas[id], persona.kind == .ai, persona.deletedAt == nil else { return nil }; return persona } }
    public func loadAIReplyContext(targetThoughtID: UUID, maximumEntries: Int) throws -> AIReplyContext { try lock.withLock {
        guard maximumEntries > 0, records.contains(where: { $0.id == targetThoughtID }) else { throw CocoaError(.fileNoSuchFile) }
        var currentID: UUID? = targetThoughtID, visited = Set<UUID>(), newestFirst: [AIReplyContextEntry] = [], traversed: [ThoughtRelation] = []
        while let id = currentID, visited.insert(id).inserted, newestFirst.count < maximumEntries {
            if let thought = records.first(where: { $0.id == id }), thought.deletedAt == nil,
               let authorID = authorIDs[id], let author = personas[authorID] { newestFirst.append(AIReplyContextEntry(thought: thought, author: author)) }
            guard let relation = relations.first(where: { $0.sourceThoughtID == id && $0.type == .repliesTo }) else { break }
            traversed.append(relation); currentID = relation.targetThoughtID
        }
        return AIReplyContext(entries: Array(newestFirst.reversed()), targetThoughtID: targetThoughtID, relations: Array(traversed.reversed()))
    } }
    public func createHumanReply(body: String, targetThoughtID: UUID, mentionedPersonaID: UUID?, now: Date, thoughtID: UUID, relationID: UUID) throws -> Thought? { try lock.withLock {
        guard let body = ThoughtDraft.validBody(from: body), records.contains(where: { $0.id == targetThoughtID && $0.deletedAt == nil }) else { return nil }
        if let mentionedPersonaID { guard personas[mentionedPersonaID]?.deletedAt == nil else { throw CocoaError(.fileNoSuchFile) } }
        let thought = Thought(id: thoughtID, body: body, createdAt: now), relation = ThoughtRelation(id: relationID, sourceThoughtID: thoughtID, targetThoughtID: targetThoughtID, type: .repliesTo, createdAt: now)
        try validate(relation, includingSource: thoughtID); records.append(thought); authorIDs[thoughtID] = Persona.defaultHumanID; if let mentionedPersonaID, let persona = personas[mentionedPersonaID] { mentionsByThoughtID[thoughtID] = [.init(thoughtID: thoughtID, personaID: mentionedPersonaID, handleSnapshot: persona.handle, rangeLocation: 0, rangeLength: 0, createdAt: now)] }; relations.append(relation); return thought
    } }

    public func fetchTimeline() throws -> [Thought] {
        lock.withLock {
            records.filter { $0.deletedAt == nil }.sorted(by: Thought.timelineOrder)
        }
    }

    public func fetchTimelinePage(limit: Int, before cursor: Thought?) throws -> [Thought] {
        guard limit > 0 else { return [] }
        return lock.withLock {
            records
                .filter { thought in
                    guard thought.deletedAt == nil else { return false }
                    guard let cursor else { return true }
                    return thought.createdAt < cursor.createdAt ||
                        (thought.createdAt == cursor.createdAt && thought.id.uuidString < cursor.id.uuidString)
                }
                .sorted(by: Thought.timelineOrder)
                .prefix(limit)
                .map { $0 }
        }
    }

    public func fetchByID(_ id: UUID) throws -> Thought? {
        lock.withLock { records.first { $0.id == id } }
    }

    public func fetchAll() throws -> [Thought] {
        lock.withLock { records.sorted(by: Thought.timelineOrder) }
    }

    public func fetchThoughts(from startDate: Date, to endDate: Date) throws -> [Thought] {
        lock.withLock {
            records
                .filter { $0.deletedAt == nil && $0.createdAt >= startDate && $0.createdAt < endDate }
                .sorted {
                    $0.createdAt == $1.createdAt
                        ? $0.id.uuidString < $1.id.uuidString
                        : $0.createdAt < $1.createdAt
                }
        }
    }

    public func fetchHumanThoughts(from startDate: Date, to endDate: Date) throws -> [Thought] {
        lock.withLock {
            records
                .filter {
                    $0.deletedAt == nil &&
                    $0.createdAt >= startDate && $0.createdAt < endDate &&
                    authorIDs[$0.id].flatMap { personas[$0] }?.kind == .human
                }
                .sorted {
                    $0.createdAt == $1.createdAt
                        ? $0.id.uuidString < $1.id.uuidString
                        : $0.createdAt < $1.createdAt
                }
        }
    }

    public func softDelete(id: UUID, at date: Date) throws -> Bool {
        lock.withLock {
            guard let index = records.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
                return false
            }
            records[index].deletedAt = date
            return true
        }
    }

    public func addTag(named name: String, to thoughtID: UUID, at date: Date) throws -> ThoughtTagAssignment {
        guard let displayName = ThoughtTag.displayName(from: name) else { return .invalidName }
        return lock.withLock {
            guard records.contains(where: { $0.id == thoughtID && $0.deletedAt == nil }) else { return .invalidName }
            let normalized = ThoughtTag.normalize(displayName)
            let tag: ThoughtTag
            if let existing = tags.first(where: { $0.normalizedName == normalized }) {
                tag = existing
            } else {
                tag = ThoughtTag(name: displayName, normalizedName: normalized, createdAt: date)
                tags.append(tag)
            }
            if thoughtTagIDs[thoughtID, default: []].contains(tag.id) { return .alreadyAttached(tag) }
            thoughtTagIDs[thoughtID, default: []].insert(tag.id)
            return .added(tag)
        }
    }

    public func removeTag(id tagID: UUID, from thoughtID: UUID) throws -> Bool {
        lock.withLock { thoughtTagIDs[thoughtID]?.remove(tagID) != nil }
    }

    public func fetchTags(for thoughtID: UUID) throws -> [ThoughtTag] {
        lock.withLock {
            guard records.contains(where: { $0.id == thoughtID && $0.deletedAt == nil }) else { return [] }
            let ids = thoughtTagIDs[thoughtID] ?? []
            return tags.filter { ids.contains($0.id) }.sorted { $0.normalizedName < $1.normalizedName }
        }
    }

    public func fetchAllTags() throws -> [ThoughtTag] {
        lock.withLock {
            let activeIDs = Set(records.filter { $0.deletedAt == nil }.map(\.id))
            let usedTagIDs = Set(thoughtTagIDs.filter { activeIDs.contains($0.key) }.flatMap(\.value))
            return tags.filter { usedTagIDs.contains($0.id) }.sorted { $0.normalizedName < $1.normalizedName }
        }
    }

    public func fetchThoughts(taggedWith tagID: UUID) throws -> [Thought] {
        lock.withLock {
            records.filter { thought in
                thought.deletedAt == nil && thoughtTagIDs[thought.id]?.contains(tagID) == true
            }.sorted(by: Thought.timelineOrder)
        }
    }

    public func fetchThoughts(from startDate: Date, to endDate: Date, taggedWith tagID: UUID) throws -> [Thought] {
        lock.withLock {
            records.filter { thought in
                thought.deletedAt == nil &&
                thought.createdAt >= startDate && thought.createdAt < endDate &&
                thoughtTagIDs[thought.id]?.contains(tagID) == true
            }.sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            }
        }
    }

    public func search(query: String) throws -> [Thought] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return lock.withLock {
            records
                .filter { $0.deletedAt == nil && $0.body.localizedCaseInsensitiveContains(query) }
                .sorted(by: Thought.timelineOrder)
        }
    }

    public func fetchAnalytics(_ request: ThoughtAnalyticsRequest) throws -> ThoughtAnalyticsSnapshot {
        lock.withLock {
            let period = request.period
            let active = records.filter {
                $0.deletedAt == nil && $0.createdAt >= period.start && $0.createdAt < period.end
            }
            let daily = request.days.map { day in
                DailyThoughtCount(
                    date: day.interval.start,
                    count: active.filter { $0.createdAt >= day.interval.start && $0.createdAt < day.interval.end }.count
                )
            }
            let weekdayOrder = (0..<7).map { (($0 + request.firstWeekday - 1) % 7) + 1 }
            let weekday = weekdayOrder.map { value in
                WeekdayThoughtCount(
                    weekday: value,
                    count: zip(request.days, daily).filter { $0.0.weekday == value }.reduce(0) { $0 + $1.1.count }
                )
            }
            let timeOfDay = TimeOfDay.allCases.map { bucket in
                TimeOfDayThoughtCount(
                    timeOfDay: bucket,
                    count: request.timeWindows
                        .filter { $0.timeOfDay == bucket }
                        .reduce(0) { result, window in
                            result + active.filter {
                                $0.createdAt >= window.interval.start && $0.createdAt < window.interval.end
                            }.count
                        }
                )
            }
            let countsByTagID = thoughtTagIDs.reduce(into: [UUID: Int]()) { result, item in
                guard active.contains(where: { $0.id == item.key }) else { return }
                for tagID in item.value { result[tagID, default: 0] += 1 }
            }
            let topTags = tags.compactMap { tag -> TagThoughtCount? in
                guard let count = countsByTagID[tag.id] else { return nil }
                return TagThoughtCount(tag: tag, count: count)
            }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.tag.normalizedName != $1.tag.normalizedName {
                    return $0.tag.normalizedName < $1.tag.normalizedName
                }
                return $0.tag.id.uuidString < $1.tag.id.uuidString
            }.prefix(5)
            let activeIDs = Set(active.map(\.id))
            let continuationParents = Set(relations.compactMap { relation -> UUID? in
                guard relation.type == .continues,
                      activeIDs.contains(relation.sourceThoughtID),
                      activeIDs.contains(relation.targetThoughtID) else { return nil }
                return relation.targetThoughtID
            })
            let todayCount = daily.last?.count ?? 0
            let sevenDayCount = daily.suffix(7).reduce(0) { $0 + $1.count }
            let thirtyDayCount = daily.reduce(0) { $0 + $1.count }
            return ThoughtAnalyticsSnapshot(
                period: period,
                summary: .init(
                    todayCount: todayCount,
                    pastSevenDaysCount: sevenDayCount,
                    pastThirtyDaysCount: thirtyDayCount,
                    activeDayCount: daily.filter { $0.count > 0 }.count
                ),
                dailyCounts: daily,
                weekdayCounts: weekday,
                timeOfDayCounts: timeOfDay,
                topTags: Array(topTags),
                thoughtsWithContinuationsCount: continuationParents.count
            )
        }
    }

    public func save(_ summary: ReviewSummary) throws {
        lock.withLock { summaries.append(summary) }
    }

    public func fetchSummary(id: UUID) throws -> ReviewSummary? {
        lock.withLock { summaries.first { $0.id == id } }
    }

    public func fetchSummaries(from startDate: Date, to endDate: Date) throws -> [ReviewSummary] {
        lock.withLock {
            summaries.filter { $0.periodStart == startDate && $0.periodEnd == endDate }
                .sorted {
                    $0.createdAt == $1.createdAt
                        ? $0.id.uuidString > $1.id.uuidString
                        : $0.createdAt > $1.createdAt
                }
        }
    }

    public func deleteSummary(id: UUID) throws -> Bool {
        lock.withLock {
            guard let index = summaries.firstIndex(where: { $0.id == id }) else { return false }
            summaries.remove(at: index)
            return true
        }
    }

    public func saveDailySummary(_ summary: DailySummary) throws {
        lock.withLock {
            dailySummaries.removeAll { $0.dayStart == summary.dayStart }
            dailySummaries.append(summary)
        }
    }

    public func fetchDailySummary(dayStart: Date) throws -> DailySummary? {
        lock.withLock { dailySummaries.first { $0.dayStart == dayStart } }
    }

    public func fetchDailySummaries(from start: Date, to end: Date) throws -> [DailySummary] {
        lock.withLock { dailySummaries.filter { $0.dayStart >= start && $0.dayStart < end }.sorted { $0.createdAt > $1.createdAt } }
    }

    public func saveWeeklySummary(_ summary: WeeklySummary) throws { lock.withLock { weeklySummaries.removeAll { $0.weekStart == summary.weekStart }; weeklySummaries.append(summary) } }
    public func fetchWeeklySummary(weekStart: Date) throws -> WeeklySummary? { lock.withLock { weeklySummaries.first { $0.weekStart == weekStart } } }
    public func fetchWeeklySummaries() throws -> [WeeklySummary] { lock.withLock { weeklySummaries.sorted { $0.weekStart > $1.weekStart } } }
    public func saveWeeklyPlan(_ plan: WeeklyPlan) throws { lock.withLock { weeklyPlans.removeAll { $0.targetWeekStart == plan.targetWeekStart }; weeklyPlans.append(plan) } }
    public func fetchWeeklyPlan(targetWeekStart: Date) throws -> WeeklyPlan? { lock.withLock { weeklyPlans.first { $0.targetWeekStart == targetWeekStart } } }

    public func fetchAllApps() throws -> [SecondBrainApp] { lock.withLock { orderedApps() } }
    public func fetchApp(id: UUID) throws -> SecondBrainApp? { lock.withLock { secondBrainApps[id] } }
    public func createApp(_ app: SecondBrainApp) throws {
        try lock.withLock {
            guard secondBrainApps[app.id] == nil else { throw SecondBrainAppRepositoryError.duplicateID(app.id) }
            secondBrainApps[app.id] = app
        }
    }
    public func updateApp(_ app: SecondBrainApp) throws {
        try lock.withLock {
            guard let existing = secondBrainApps[app.id] else { throw SecondBrainAppRepositoryError.notFound(app.id) }
            guard existing.createdAt == app.createdAt else { throw SecondBrainAppRepositoryError.createdAtChanged(app.id) }
            secondBrainApps[app.id] = app
        }
    }
    public func deleteApp(id: UUID) throws {
        try lock.withLock {
            guard secondBrainApps.removeValue(forKey: id) != nil else { throw SecondBrainAppRepositoryError.notFound(id) }
        }
    }
    public func seedDefaultAppsIfNeeded(now: Date) throws -> Int {
        try lock.withLock {
            var inserted = 0
            for app in try SecondBrainDefaultApps.all(createdAt: now) where !seededDefaultAppIDs.contains(app.id) {
                if secondBrainApps[app.id] == nil { secondBrainApps[app.id] = app; inserted += 1 }
                seededDefaultAppIDs.insert(app.id)
            }
            return inserted
        }
    }

    private func orderedApps() -> [SecondBrainApp] {
        secondBrainApps.values.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func create(_ relation: ThoughtRelation) throws {
        try lock.withLock {
            try validate(relation)
            relations.append(relation)
        }
    }

    public func fetchBySourceThoughtID(_ id: UUID) throws -> [ThoughtRelation] {
        lock.withLock { ordered(relations.filter { $0.sourceThoughtID == id }) }
    }

    public func fetchByTargetThoughtID(_ id: UUID) throws -> [ThoughtRelation] {
        lock.withLock { ordered(relations.filter { $0.targetThoughtID == id }) }
    }

    public func fetchContinuationSource(for thoughtID: UUID) throws -> ThoughtRelation? {
        try fetchBySourceThoughtID(thoughtID).first { $0.type == .continues }
    }

    public func fetchContinuations(of thoughtID: UUID) throws -> [ThoughtRelation] {
        try fetchByTargetThoughtID(thoughtID).filter { $0.type == .continues }
    }

    public func fetchContinuationCounts(for thoughtIDs: [UUID]) throws -> [UUID: Int] {
        let ids = Set(thoughtIDs)
        return lock.withLock {
            Dictionary(grouping: relations.filter {
                $0.type == .continues && ids.contains($0.targetThoughtID)
            }, by: \.targetThoughtID).mapValues(\.count)
        }
    }

    public func createContinuation(
        body: String,
        parentThoughtID: UUID,
        now: Date,
        thoughtID: UUID
    ) throws -> Thought? {
        guard let body = ThoughtDraft.validBody(from: body) else { return nil }
        return try lock.withLock {
            let thought = Thought(id: thoughtID, body: body, createdAt: now)
            let relation = ThoughtRelation(
                sourceThoughtID: thoughtID,
                targetThoughtID: parentThoughtID,
                createdAt: now
            )
            guard records.contains(where: { $0.id == parentThoughtID }) else {
                throw MemoryRelationError.invalidRelation
            }
            try validate(relation, includingSource: thoughtID)
            records.append(thought)
            relations.append(relation)
            return thought
        }
    }

    private func validate(_ relation: ThoughtRelation, includingSource: UUID? = nil) throws {
        guard relation.sourceThoughtID != relation.targetThoughtID,
              records.contains(where: { $0.id == relation.targetThoughtID }),
              records.contains(where: { $0.id == relation.sourceThoughtID }) || includingSource == relation.sourceThoughtID,
              !relations.contains(where: { $0.sourceThoughtID == relation.sourceThoughtID }),
              !relations.contains(where: {
                  $0.sourceThoughtID == relation.sourceThoughtID &&
                  $0.targetThoughtID == relation.targetThoughtID &&
                  $0.type == relation.type
              }) else {
            throw MemoryRelationError.invalidRelation
        }
        var pending = [relation.targetThoughtID]
        var visited = Set<UUID>()
        while let candidate = pending.popLast() {
            guard visited.insert(candidate).inserted else { continue }
            if candidate == relation.sourceThoughtID { throw MemoryRelationError.invalidRelation }
            pending.append(contentsOf: relations
                .filter { $0.sourceThoughtID == candidate }
                .map(\.targetThoughtID))
        }
    }

    private func ordered(_ values: [ThoughtRelation]) -> [ThoughtRelation] {
        values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
    }
}

private enum MemoryRelationError: Error { case invalidRelation }

extension Thought {
    static func timelineOrder(_ lhs: Thought, _ rhs: Thought) -> Bool {
        lhs.createdAt == rhs.createdAt
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.createdAt > rhs.createdAt
    }
}

public enum ThoughtReviewPeriod {
    public static func today(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        day(containing: date, calendar: calendar)
    }

    public static func yesterday(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -1, to: today)!
        return DateInterval(start: start, end: today)
    }

    public static func pastSevenDays(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        return DateInterval(start: start, end: end)
    }

    public static func currentWeek(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        return DateInterval(start: start, end: end)
    }

    public static func pastThirtyDays(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -29, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        return DateInterval(start: start, end: end)
    }

    public static func currentMonth(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        return DateInterval(start: start, end: end)
    }

    public static func day(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }
}
