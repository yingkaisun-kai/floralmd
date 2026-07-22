import Foundation

/// Storage boundary for the system-owned recent-document list.
///
/// `NSDocumentController` is adapted to this protocol by the app target. Keeping
/// the policy independent makes ordering, deduplication, pruning, and clearing
/// deterministic without replacing the system list as the source of truth.
@MainActor
public protocol RecentDocumentStoring: AnyObject {
    var recentDocumentURLs: [URL] { get }
    var maximumRecentDocumentCount: Int { get }

    func noteNewRecentDocumentURL(_ url: URL)
    func clearRecentDocuments()
}

/// Maintains the system recent-document list as a most-recent-first collection
/// of available local files.
@MainActor
public final class RecentDocumentHistory {
    public typealias AvailabilityCheck = (URL) -> Bool

    private let store: any RecentDocumentStoring
    private let isAvailable: AvailabilityCheck

    public init(
        store: any RecentDocumentStoring,
        isAvailable: @escaping AvailabilityCheck = RecentDocumentHistory.defaultAvailabilityCheck
    ) {
        self.store = store
        self.isAvailable = isAvailable
    }

    /// Records a successfully opened local file and moves an existing entry to
    /// the front. Invalid files are never added, and stale entries encountered
    /// during the update are removed at the same time.
    public func recordOpenedDocument(at url: URL) {
        let candidate = normalized(url)
        guard isAvailable(candidate) else {
            _ = availableDocumentURLs()
            return
        }

        let existing = normalizedAvailableURLs(from: store.recentDocumentURLs)
        let updated = Array(([candidate] + existing.filter { $0 != candidate })
            .prefix(maximumCount))
        replaceStoredURLs(with: updated)
    }

    /// Returns menu-ready entries and rewrites the system list when it contains
    /// duplicates, entries over the current system limit, or unavailable URLs.
    @discardableResult
    public func availableDocumentURLs() -> [URL] {
        let raw = store.recentDocumentURLs
        let available = normalizedAvailableURLs(from: raw)
        let normalizedRaw = raw.map(normalized)
        if available != normalizedRaw {
            replaceStoredURLs(with: available)
        }
        return available
    }

    public func containsAvailableDocument(at url: URL) -> Bool {
        availableDocumentURLs().contains(normalized(url))
    }

    public func removeDocument(at url: URL) {
        let removed = normalized(url)
        let remaining = availableDocumentURLs().filter { $0 != removed }
        replaceStoredURLs(with: remaining)
    }

    public func clear() {
        store.clearRecentDocuments()
    }

    nonisolated public static func defaultAvailabilityCheck(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private var maximumCount: Int {
        max(0, store.maximumRecentDocumentCount)
    }

    private func normalizedAvailableURLs(from urls: [URL]) -> [URL] {
        guard maximumCount > 0 else { return [] }
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls {
            let candidate = normalized(url)
            guard isAvailable(candidate), seen.insert(candidate).inserted else { continue }
            result.append(candidate)
            if result.count == maximumCount { break }
        }
        return result
    }

    private func replaceStoredURLs(with urls: [URL]) {
        store.clearRecentDocuments()
        // NSDocumentController inserts each noted URL at the front.
        for url in urls.reversed() {
            store.noteNewRecentDocumentURL(url)
        }
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL
    }
}
