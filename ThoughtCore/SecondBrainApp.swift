import Foundation

public enum SecondBrainAppKind: String, Codable, CaseIterable, Sendable {
    case native
    case web
    case localWeb
    case external
}

/// SecondBrain内で解決できるNative機能だけを列挙する。
/// ThoughtはSecondBrain Coreであり、App catalogの項目にはしない。
public enum SecondBrainNativeFeature: String, Codable, CaseIterable, Sendable {
    case ai
    case knowledge
    case insights
}

public enum SecondBrainAppLaunchTarget: Equatable, Codable, Sendable {
    case nativeFeature(SecondBrainNativeFeature)
    case webURL(String)
    case localURL(String)
    case deepLink(String)

    public enum StorageKind: String, Codable, Sendable {
        case nativeFeature
        case webURL
        case localURL
        case deepLink
    }

    public var storageKind: StorageKind {
        switch self {
        case .nativeFeature: .nativeFeature
        case .webURL: .webURL
        case .localURL: .localURL
        case .deepLink: .deepLink
        }
    }

    public var storageValue: String {
        switch self {
        case .nativeFeature(let feature): feature.rawValue
        case .webURL(let value), .localURL(let value), .deepLink(let value): value
        }
    }

    public static func restoring(storageKind: StorageKind, value: String) throws -> Self {
        switch storageKind {
        case .nativeFeature:
            guard let feature = SecondBrainNativeFeature(rawValue: value) else {
                throw SecondBrainAppValidationError.invalidNativeFeature
            }
            return .nativeFeature(feature)
        case .webURL: return .webURL(value)
        case .localURL: return .localURL(value)
        case .deepLink: return .deepLink(value)
        }
    }
}

public struct SecondBrainApp: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let icon: String
    public let kind: SecondBrainAppKind
    public let launchTarget: SecondBrainAppLaunchTarget
    public let category: String
    public let isFavorite: Bool
    public let sortOrder: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        icon: String = "square.grid.2x2",
        kind: SecondBrainAppKind,
        launchTarget: SecondBrainAppLaunchTarget,
        category: String = "その他",
        isFavorite: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIcon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUpdatedAt = updatedAt ?? createdAt

        guard !normalizedName.isEmpty else { throw SecondBrainAppValidationError.emptyName }
        guard sortOrder >= 0 else { throw SecondBrainAppValidationError.invalidSortOrder }
        guard resolvedUpdatedAt >= createdAt else { throw SecondBrainAppValidationError.updatedBeforeCreated }
        try SecondBrainAppValidator.validate(kind: kind, launchTarget: launchTarget)

        self.id = id
        self.name = normalizedName
        self.description = normalizedDescription
        self.icon = normalizedIcon.isEmpty ? "square.grid.2x2" : normalizedIcon
        self.kind = kind
        self.launchTarget = launchTarget
        self.category = normalizedCategory.isEmpty ? "その他" : normalizedCategory
        self.isFavorite = isFavorite
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = resolvedUpdatedAt
    }
}

public enum SecondBrainAppValidationError: Error, LocalizedError, Equatable {
    case emptyName
    case invalidSortOrder
    case updatedBeforeCreated
    case incompatibleLaunchTarget
    case invalidURL
    case insecureWebURL
    case nonLocalURL
    case dangerousScheme
    case invalidDeepLink
    case invalidNativeFeature

    public var errorDescription: String? {
        switch self {
        case .emptyName: "App名を入力してください。"
        case .invalidSortOrder: "表示順は0以上で指定してください。"
        case .updatedBeforeCreated: "更新日時は作成日時より前にできません。"
        case .incompatibleLaunchTarget: "App種別と起動先の組み合わせが一致しません。"
        case .invalidURL: "起動先URLが不正です。"
        case .insecureWebURL: "Web Appの起動先にはhttps://を使用してください。"
        case .nonLocalURL: "Local WebにはローカルネットワークのURLを指定してください。"
        case .dangerousScheme: "安全でないURL schemeは使用できません。"
        case .invalidDeepLink: "Deep Linkが不正です。"
        case .invalidNativeFeature: "未対応のNative機能です。"
        }
    }
}

public enum SecondBrainAppRepositoryError: Error, LocalizedError, Equatable {
    case duplicateID(UUID)
    case notFound(UUID)
    case createdAtChanged(UUID)

    public var errorDescription: String? {
        switch self {
        case .duplicateID: "同じIDのAppがすでに存在します。"
        case .notFound: "対象のAppが見つかりません。"
        case .createdAtChanged: "Appの作成日時は変更できません。"
        }
    }
}

public protocol SecondBrainAppRepository: Sendable {
    func fetchAllApps() throws -> [SecondBrainApp]
    func fetchApp(id: UUID) throws -> SecondBrainApp?
    func createApp(_ app: SecondBrainApp) throws
    func updateApp(_ app: SecondBrainApp) throws
    func deleteApp(id: UUID) throws
    @discardableResult func seedDefaultAppsIfNeeded(now: Date) throws -> Int
}

public enum SecondBrainAppLaunchCommand: Equatable, Sendable {
    case native(SecondBrainNativeFeature)
    case externalURL(URL, confirmation: String)
}

/// 保存時と起動時の両方で同じDomain policyを適用する。
public enum SecondBrainAppLaunchPolicy {
    public static func prepare(_ app: SecondBrainApp) throws -> SecondBrainAppLaunchCommand {
        _ = try SecondBrainApp(
            id: app.id,
            name: app.name,
            description: app.description,
            icon: app.icon,
            kind: app.kind,
            launchTarget: app.launchTarget,
            category: app.category,
            isFavorite: app.isFavorite,
            sortOrder: app.sortOrder,
            createdAt: app.createdAt,
            updatedAt: app.updatedAt
        )

        switch app.launchTarget {
        case .nativeFeature(let feature):
            return .native(feature)
        case .webURL(let value):
            guard let url = URL(string: value), let host = url.host else {
                throw SecondBrainAppValidationError.invalidURL
            }
            return .externalURL(url, confirmation: host)
        case .localURL(let value):
            guard let url = URL(string: value), let host = url.host else {
                throw SecondBrainAppValidationError.invalidURL
            }
            let endpoint = url.port.map { "\(host):\($0)" } ?? host
            return .externalURL(url, confirmation: "Local Web: \(endpoint)")
        case .deepLink(let value):
            guard let url = URL(string: value), let scheme = url.scheme else {
                throw SecondBrainAppValidationError.invalidDeepLink
            }
            return .externalURL(url, confirmation: "\(scheme)://")
        }
    }
}

public extension SecondBrainAppRepository {
    @discardableResult
    func seedDefaultAppsIfNeeded() throws -> Int {
        try seedDefaultAppsIfNeeded(now: Date())
    }
}

public enum SecondBrainDefaultApps {
    public static let catalogVersion = 2

    public static let sharedMemoID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
    public static let myWikiID = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
    public static let studyID = UUID(uuidString: "40000000-0000-4000-8000-000000000003")!
    public static let toolID = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
    public static let studyAppID = UUID(uuidString: "40000000-0000-4000-8000-000000000005")!

    public static func all(createdAt: Date = Date()) throws -> [SecondBrainApp] {
        try [
            SecondBrainApp(
                id: sharedMemoID,
                name: "Shared Memo",
                description: "共有メモ / 簡易メモツール",
                icon: "note.text",
                kind: .web,
                launchTarget: .webURL("https://maruyamamasaya.github.io/memo-tool/shared-memo/"),
                category: "メモ",
                isFavorite: true,
                sortOrder: 10,
                createdAt: createdAt
            ),
            SecondBrainApp(
                id: myWikiID,
                name: "My Wiki",
                description: "個人Wiki / Knowledge / 興味・情報整理",
                icon: "books.vertical",
                kind: .web,
                launchTarget: .webURL("https://maruyamamasaya.github.io/my-wiki/"),
                category: "Knowledge",
                isFavorite: true,
                sortOrder: 20,
                createdAt: createdAt
            ),
            SecondBrainApp(
                id: studyID,
                name: "Study",
                description: "学習 / 勉強用ツール",
                icon: "graduationcap",
                kind: .web,
                launchTarget: .webURL("https://maruyamamasaya.github.io/study/#/"),
                category: "学習",
                isFavorite: false,
                sortOrder: 30,
                createdAt: createdAt
            ),
            SecondBrainApp(
                id: studyAppID,
                name: "Study App",
                description: "学習用Webアプリ",
                icon: "book.closed",
                kind: .web,
                launchTarget: .webURL("https://study-app-maruyama.maruyama-001.chatgpt.site/"),
                category: "学習",
                isFavorite: false,
                sortOrder: 35,
                createdAt: createdAt
            ),
            SecondBrainApp(
                id: toolID,
                name: "Tool",
                description: "個人用ユーティリティ / Tool集",
                icon: "wrench.and.screwdriver",
                kind: .web,
                launchTarget: .webURL("https://maruyamamasaya.github.io/tool/"),
                category: "ユーティリティ",
                isFavorite: false,
                sortOrder: 40,
                createdAt: createdAt
            )
        ]
    }
}

public enum SecondBrainAppFixtures {
    public static func samples(now: Date = Date(timeIntervalSince1970: 0)) throws -> [SecondBrainApp] {
        try [
            SecondBrainApp(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "HomeMuseum",
                description: "個人用の展示・記録Webアプリ",
                icon: "building.columns",
                kind: .web,
                launchTarget: .webURL("https://example.com/home-museum"),
                category: "Web Apps",
                isFavorite: true,
                sortOrder: 0,
                createdAt: now
            ),
            SecondBrainApp(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                name: "Baby Media",
                description: "ローカルネットワーク上のメディアツール",
                icon: "photo.on.rectangle",
                kind: .localWeb,
                launchTarget: .localURL("http://192.168.1.20:8080"),
                category: "Local Tools",
                sortOrder: 1,
                createdAt: now
            ),
            SecondBrainApp(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                name: "GitHub Monitor",
                description: "Repositoryの状態を確認するWebツール",
                icon: "waveform.path.ecg.rectangle",
                kind: .web,
                launchTarget: .webURL("https://example.com/github-monitor"),
                category: "Developer Tools",
                sortOrder: 2,
                createdAt: now
            )
        ]
    }
}

private enum SecondBrainAppValidator {
    private static let blockedSchemes: Set<String> = ["javascript", "data", "file", "vbscript", "about", "blob"]

    static func validate(kind: SecondBrainAppKind, launchTarget: SecondBrainAppLaunchTarget) throws {
        switch (kind, launchTarget) {
        case (.native, .nativeFeature):
            return
        case (.web, .webURL(let value)), (.external, .webURL(let value)):
            let components = try validatedURL(value)
            guard components.scheme?.lowercased() == "https" else {
                throw SecondBrainAppValidationError.insecureWebURL
            }
        case (.localWeb, .localURL(let value)):
            let components = try validatedURL(value)
            guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw SecondBrainAppValidationError.invalidURL
            }
            guard let host = components.host, isLocalHost(host) else {
                throw SecondBrainAppValidationError.nonLocalURL
            }
        case (.external, .deepLink(let value)):
            let components = try validatedURL(value, requiresHost: false)
            guard let scheme = components.scheme?.lowercased(), scheme != "http", scheme != "https" else {
                throw SecondBrainAppValidationError.invalidDeepLink
            }
        default:
            throw SecondBrainAppValidationError.incompatibleLaunchTarget
        }
    }

    private static func validatedURL(_ value: String, requiresHost: Bool = true) throws -> URLComponents {
        guard !value.isEmpty,
              !value.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty,
              !blockedSchemes.contains(scheme),
              components.user == nil,
              components.password == nil,
              !requiresHost || !(components.host ?? "").isEmpty else {
            if let scheme = URLComponents(string: value)?.scheme?.lowercased(), blockedSchemes.contains(scheme) {
                throw SecondBrainAppValidationError.dangerousScheme
            }
            throw SecondBrainAppValidationError.invalidURL
        }
        return components
    }

    private static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" || (host.contains(":") && (host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd"))) { return true }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        if octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 169 && octets[1] == 254 { return true }
        return octets[0] == 172 && (16...31).contains(octets[1])
    }
}
