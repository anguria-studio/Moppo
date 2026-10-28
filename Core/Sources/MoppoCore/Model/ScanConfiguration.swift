import Foundation

/// A shared exclusion for a folder, file, tool item, or filename pattern.
/// The app and the CLI both read and write these rules.
public struct ExclusionRule: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case folder, pattern, item }
    public var id: UUID = UUID()
    public var kind: Kind
    /// A folder path, a file path, a complete tool item URL, or a filename pattern.
    public var value: String
    /// Built-in rules that protect credentials. The user cannot delete them.
    public var isLocked: Bool = false

    public init(id: UUID = UUID(), kind: Kind, value: String, isLocked: Bool = false) {
        self.id = id
        self.kind = kind
        self.value = value
        self.isLocked = isLocked
    }

    public static func folder(_ url: URL) -> Self {
        Self(kind: .folder, value: url.standardizedFileURL.path)
    }

    public static func pattern(_ glob: String, isLocked: Bool = false) -> Self {
        Self(kind: .pattern, value: glob, isLocked: isLocked)
    }

    /// The rules for Never Offer This Again on one row.
    /// Model rules identify manifests or repository folders, so shared blobs stay protected.
    /// Returns an empty list when the row cannot be excluded.
    public static func rules(for entry: FileEntry) -> [Self] {
        guard entry.canExcludeFromCleanup else { return [] }
        return entry.exclusionURLs.map { url in
            let value = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
            let isDirectory = url.isFileURL
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return Self(kind: isDirectory ? .folder : .item, value: value)
        }
    }

    /// Adds rules whose values are not already present. Returns the rules that it added.
    public static func merge(_ added: [Self], into rules: inout [Self]) -> [Self] {
        var inserted: [Self] = []
        for rule in added where !rules.contains(where: { $0.kind != .pattern && $0.value == rule.value }) {
            rules.append(rule)
            inserted.append(rule)
        }
        return inserted
    }
}

/// Reads the same preference keys without changing application settings.
public struct ScanConfiguration: Sendable {
    public static let applicationDomain = "com.tommasolaterza.Moppo"
    public static let categoriesEnabledByDefault = true
    public static let categoriesKey = "settings.categoryEnabled"
    public static let exclusionsKey = "settings.exclusions"
    public static let defaultExclusions: [ExclusionRule] = [
        .pattern("*.sparsebundle", isLocked: true), .pattern("*.keychain-db", isLocked: true)
    ]
    public var enabledCategories: Set<CategoryID>
    public var excludedPaths: [String]
    public var excludedPatterns: [String]

    public init(enabledCategories: Set<CategoryID> = Set(CategoryID.allCases),
                excludedPaths: [String] = [], excludedPatterns: [String] = []) {
        self.enabledCategories = enabledCategories
        self.excludedPaths = excludedPaths
        self.excludedPatterns = excludedPatterns
    }

    public init(defaults: UserDefaults) throws {
        enabledCategories = Set(try Self.readCategories(from: defaults).filter(\.value).map(\.key))
        let exclusions = try Self.readExclusions(from: defaults)
        excludedPaths = exclusions.filter { $0.kind != .pattern }.map(\.value)
        excludedPatterns = exclusions.filter { $0.kind == .pattern }.map(\.value)
    }

    public static func current() throws -> Self {
        guard let defaults = UserDefaults(suiteName: applicationDomain) else { throw ConfigurationError.invalidCategories }
        return try Self(defaults: defaults)
    }

    public enum ConfigurationError: Error { case invalidCategories, invalidExclusions, unavailable }

    /// Posted after another process changes the saved exclusions. The app reloads its rules.
    public static let exclusionsChangedNotification = Notification.Name(applicationDomain + ".exclusionsChanged")

    /// Adds rules to the app's saved exclusions without removing other rules.
    /// Rules only remove items from cleanup results. They never permit removal.
    public static func addExclusions(_ added: [ExclusionRule], to defaults: UserDefaults) throws -> [ExclusionRule] {
        var rules = try readExclusions(from: defaults)
        let inserted = ExclusionRule.merge(added, into: &rules)
        guard !inserted.isEmpty else { return [] }
        defaults.set(try JSONEncoder().encode(rules), forKey: exclusionsKey)
        return inserted
    }

    /// Writes to the app's preferences and tells a running app to reload its rules.
    public static func addExclusions(_ added: [ExclusionRule]) throws -> [ExclusionRule] {
        guard let defaults = UserDefaults(suiteName: applicationDomain) else { throw ConfigurationError.unavailable }
        let inserted = try addExclusions(added, to: defaults)
        if !inserted.isEmpty {
            defaults.synchronize()
            DistributedNotificationCenter.default().postNotificationName(
                exclusionsChangedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
        return inserted
    }

    public static func readCategories(from defaults: UserDefaults, strict: Bool = true) throws -> [CategoryID: Bool] {
        let object = defaults.object(forKey: categoriesKey)
        guard !strict || object == nil || object is [String: Any] else { throw ConfigurationError.invalidCategories }
        let stored = object as? [String: Any] ?? [:]
        return try Dictionary(uniqueKeysWithValues: CategoryID.allCases.map { category in
            if let value = stored[category.rawValue], !(value is Bool), strict { throw ConfigurationError.invalidCategories }
            return (category, stored[category.rawValue] as? Bool ?? categoriesEnabledByDefault)
        })
    }

    public static func readExclusions(from defaults: UserDefaults) throws -> [ExclusionRule] {
        var rules = defaultExclusions
        if let object = defaults.object(forKey: exclusionsKey) {
            guard let data = object as? Data,
                  let decoded = try? JSONDecoder().decode([ExclusionRule].self, from: data)
            else { throw ConfigurationError.invalidExclusions }
            // An item value is a file path or a complete tool item URL, such as a Docker image.
            guard decoded.allSatisfy({ rule in
                guard !rule.value.isEmpty else { return false }
                return switch rule.kind {
                case .folder: rule.value.hasPrefix("/")
                case .item: rule.value.hasPrefix("/") || URL(string: rule.value)?.scheme != nil
                case .pattern: true
                }
            }) else { throw ConfigurationError.invalidExclusions }
            rules = decoded.map { rule in
                var normalized = rule
                if rule.kind != .pattern, rule.value.hasPrefix("/") {
                    normalized.value = URL(fileURLWithPath: rule.value).standardizedFileURL.path
                }
                return normalized
            }
        }
        for rule in defaultExclusions {
            if let index = rules.firstIndex(where: { $0.kind == rule.kind && $0.value == rule.value }) {
                rules[index].isLocked = true
            } else { rules.insert(rule, at: 0) }
        }
        return rules
    }
}
