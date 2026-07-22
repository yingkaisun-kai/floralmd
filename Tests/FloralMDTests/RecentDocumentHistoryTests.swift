import Foundation
import Testing
@testable import FloralMDCore

@MainActor
private final class TestRecentDocumentStore: RecentDocumentStoring {
    var recentDocumentURLs: [URL]
    let maximumRecentDocumentCount: Int

    init(urls: [URL] = [], maximumCount: Int = 5) {
        recentDocumentURLs = urls
        maximumRecentDocumentCount = maximumCount
    }

    func noteNewRecentDocumentURL(_ url: URL) {
        recentDocumentURLs.removeAll { $0 == url }
        recentDocumentURLs.insert(url, at: 0)
        recentDocumentURLs = Array(recentDocumentURLs.prefix(maximumRecentDocumentCount))
    }

    func clearRecentDocuments() {
        recentDocumentURLs.removeAll()
    }
}

@Suite("Recent document history")
struct RecentDocumentHistoryTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/floralmd-recent-tests/\(name).md")
    }

    @Test("Successful opens register newest-first and obey the system limit")
    @MainActor func registrationAndLimit() {
        let store = TestRecentDocumentStore(maximumCount: 2)
        let history = RecentDocumentHistory(store: store, isAvailable: { _ in true })

        history.recordOpenedDocument(at: url("one"))
        history.recordOpenedDocument(at: url("two"))
        history.recordOpenedDocument(at: url("three"))

        #expect(store.recentDocumentURLs == [url("three"), url("two")])
    }

    @Test("Opening the same URL moves one normalized entry to the front")
    @MainActor func deduplication() {
        let store = TestRecentDocumentStore(urls: [
            url("one"),
            URL(fileURLWithPath: "/tmp/floralmd-recent-tests/folder/../two.md"),
            url("two"),
        ])
        let history = RecentDocumentHistory(store: store, isAvailable: { _ in true })

        history.recordOpenedDocument(at: url("two"))

        #expect(store.recentDocumentURLs == [url("two"), url("one")])
    }

    @Test("Clear removes every system recent-document entry")
    @MainActor func clearing() {
        let store = TestRecentDocumentStore(urls: [url("one"), url("two")])
        let history = RecentDocumentHistory(store: store, isAvailable: { _ in true })

        history.clear()

        #expect(store.recentDocumentURLs.isEmpty)
    }

    @Test("Missing moved and unreadable URLs are pruned before menu presentation")
    @MainActor func invalidURLs() {
        let valid = url("valid")
        let missing = url("missing")
        let moved = url("old-location")
        let unreadable = url("private")
        let store = TestRecentDocumentStore(urls: [missing, valid, moved, unreadable, valid])
        let history = RecentDocumentHistory(store: store) { $0 == valid }

        let menuURLs = history.availableDocumentURLs()

        #expect(menuURLs == [valid])
        #expect(store.recentDocumentURLs == [valid])
    }

    @Test("Default availability rejects missing moved directory remote and unreadable URLs")
    @MainActor func defaultAvailability() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("floralmd-recent-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let original = directory.appendingPathComponent("original.md")
        let moved = directory.appendingPathComponent("moved.md")
        let unreadable = directory.appendingPathComponent("unreadable.md")
        try Data("# Recent".utf8).write(to: original)
        try Data("# Private".utf8).write(to: unreadable)

        #expect(RecentDocumentHistory.defaultAvailabilityCheck(original))
        #expect(!RecentDocumentHistory.defaultAvailabilityCheck(
            directory.appendingPathComponent("missing.md")
        ))
        #expect(!RecentDocumentHistory.defaultAvailabilityCheck(directory))
        #expect(!RecentDocumentHistory.defaultAvailabilityCheck(
            URL(string: "https://example.com/note.md")!
        ))

        try fileManager.moveItem(at: original, to: moved)
        #expect(!RecentDocumentHistory.defaultAvailabilityCheck(original))
        #expect(RecentDocumentHistory.defaultAvailabilityCheck(moved))

        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: unreadable.path)
        }
        #expect(!RecentDocumentHistory.defaultAvailabilityCheck(unreadable))
    }

    @Test("A failed recent open can remove only its stale entry")
    @MainActor func removeOneInvalidEntry() {
        let store = TestRecentDocumentStore(urls: [url("one"), url("two")])
        let history = RecentDocumentHistory(store: store, isAvailable: { _ in true })

        history.removeDocument(at: url("one"))

        #expect(store.recentDocumentURLs == [url("two")])
    }
}
