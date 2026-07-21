// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation

/// Loads bundled definitions and optional user overrides from Application Support.
/// Invalid user files are ignored safely and reported through `loadIssues`.
public final class SyntaxDefinitionStore: @unchecked Sendable {
    public struct LoadIssue: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case notRegularFile
            case fileTooLarge
            case unreadable
            case invalidDefinition
        }

        public let url: URL
        public let reason: Reason
    }

    enum Resolution: Equatable {
        case plain
        case definition(LanguageDefinition)
        case unknown
    }

    public static let shared = SyntaxDefinitionStore()
    private static let maximumDefinitionBytes = 512 * 1_024
    private static let plainAliases: Set<String> =
        ["", "plain", "plaintext", "text", "none", "txt"]

    private struct Snapshot {
        var byName: [String: LanguageDefinition] = [:]
        var ordered: [LanguageDefinition] = []
        var userNames: Set<String> = []
        var sourceURLs: [String: URL] = [:]
        var issues: [LoadIssue] = []
        var defaultLanguage = "plain"
    }

    private let lock = NSLock()
    private let bundle: Bundle
    private let userDirectoryURL: URL
    private var snapshot = Snapshot()

    public var defaultLanguage: String {
        get { lock.withLock { snapshot.defaultLanguage } }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            lock.withLock { snapshot.defaultLanguage = normalized.isEmpty ? "plain" : normalized }
        }
    }

    public var loadIssues: [LoadIssue] { lock.withLock { snapshot.issues } }

    init(bundle: Bundle = .module, userDirectory: URL? = nil) {
        self.bundle = bundle
        self.userDirectoryURL = userDirectory ?? SyntaxDefinitionStore.userDirectory
        reload()
    }

    public func reload() {
        let bundled = loadBundled()
        let user = loadUser()
        var definitionsByName: [String: (LanguageDefinition, URL, Bool)] = [:]
        for item in bundled.definitions { definitionsByName[item.0.name] = (item.0, item.1, false) }
        for item in user.definitions { definitionsByName[item.0.name] = (item.0, item.1, true) }

        let orderedEntries = definitionsByName.values.sorted {
            let comparison = $0.0.label.localizedCaseInsensitiveCompare($1.0.label)
            return comparison == .orderedSame ? $0.0.name < $1.0.name : comparison == .orderedAscending
        }
        var map: [String: LanguageDefinition] = [:]
        for (definition, _, _) in orderedEntries { map[definition.name] = definition }
        // Canonical ids always win. Aliases are deterministic and cannot hijack
        // another definition's canonical fence id.
        for (definition, _, _) in orderedEntries {
            for alias in definition.aliases where map[alias] == nil { map[alias] = definition }
        }

        var next = Snapshot(
            byName: map,
            ordered: orderedEntries.map(\.0),
            userNames: Set(orderedEntries.compactMap { $0.2 ? $0.0.name : nil }),
            sourceURLs: Dictionary(uniqueKeysWithValues: orderedEntries.map { ($0.0.name, $0.1) }),
            issues: bundled.issues + user.issues)
        lock.withLock {
            next.defaultLanguage = snapshot.defaultLanguage
            snapshot = next
        }
    }

    func resolve(_ language: String?) -> Resolution {
        let key = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.plainAliases.contains(key) { return .plain }
        return lock.withLock {
            snapshot.byName[key].map(Resolution.definition) ?? .unknown
        }
    }

    /// User-facing label for an explicitly named fenced-code language.
    /// Plain-text aliases deliberately return nil: they describe the absence
    /// of syntax rather than a language worth surfacing in the editor chrome.
    func displayLabel(for language: String?) -> String? {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        switch resolve(trimmed) {
        case .plain:
            return nil
        case .definition(let definition):
            return definition.displayName ?? definition.name
        case .unknown:
            return trimmed
        }
    }

    public func availableLanguages() -> [(id: String, label: String)] {
        lock.withLock {
            [("plain", "Plain Text")] + snapshot.ordered.map { ($0.name, $0.label) }
        }
    }

    public func isUserDefinition(_ name: String) -> Bool {
        lock.withLock { snapshot.userNames.contains(name.lowercased()) }
    }

    public func fileURL(forName name: String) -> URL? {
        lock.withLock { snapshot.sourceURLs[name.lowercased()] }
    }

    public static var userDirectory: URL {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)) ?? fallback
        return base.appendingPathComponent("FloralMD/Syntaxes", isDirectory: true)
    }

    private typealias LoadResult = (
        definitions: [(LanguageDefinition, URL)],
        issues: [LoadIssue]
    )

    private func loadBundled() -> LoadResult {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Syntaxes") ?? []
        return load(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }, requireRegularFile: false)
    }

    private func loadUser() -> LoadResult {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: userDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return ([], []) }
        let jsonURLs = urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return load(jsonURLs, requireRegularFile: true)
    }

    private func load(_ urls: [URL], requireRegularFile: Bool) -> LoadResult {
        var definitions: [(LanguageDefinition, URL)] = []
        var issues: [LoadIssue] = []
        for url in urls {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if requireRegularFile,
               values?.isRegularFile != true || values?.isSymbolicLink == true {
                issues.append(.init(url: url, reason: .notRegularFile))
                continue
            }
            if let size = values?.fileSize, size > Self.maximumDefinitionBytes {
                issues.append(.init(url: url, reason: .fileTooLarge))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                issues.append(.init(url: url, reason: .unreadable))
                continue
            }
            guard data.count <= Self.maximumDefinitionBytes else {
                issues.append(.init(url: url, reason: .fileTooLarge))
                continue
            }
            guard let definition = try? JSONDecoder().decode(LanguageDefinition.self, from: data) else {
                issues.append(.init(url: url, reason: .invalidDefinition))
                continue
            }
            definitions.append((definition, url))
        }
        return (definitions, issues)
    }
}
