import Foundation
import Testing
@testable import FloralMDCore

@Suite("External file monitor")
@MainActor
struct ExternalFileMonitorTests {
    @Test("Continues reporting after atomic file replacements")
    func reportsRepeatedAtomicReplacements() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floralmd-monitor-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("one".utf8).write(to: url)

        var eventCount = 0
        let monitor = ExternalFileMonitor(url: url, debounce: .milliseconds(20)) {
            eventCount += 1
        }
        monitor.start()
        defer { monitor.stop() }

        try Data("two".utf8).write(to: url, options: .atomic)
        try await waitUntil { eventCount >= 1 }
        #expect(eventCount >= 1)

        let firstCount = eventCount
        try Data("three".utf8).write(to: url, options: .atomic)
        try await waitUntil { eventCount > firstCount }
        #expect(eventCount > firstCount)
    }

    @Test("Stopping cancels a pending self-write notification and monitoring resumes")
    func suppressesWriteWhileStoppedThenResumes() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floralmd-monitor-suspend-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("one".utf8).write(to: url)

        var eventCount = 0
        let monitor = ExternalFileMonitor(url: url, debounce: .milliseconds(100)) {
            eventCount += 1
        }
        monitor.start()

        try Data("own-save".utf8).write(to: url, options: .atomic)
        monitor.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(eventCount == 0)

        monitor.start()
        try Data("external-save".utf8).write(to: url, options: .atomic)
        try await waitUntil { eventCount >= 1 }
        #expect(eventCount >= 1)
        monitor.stop()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        // The full AppKit-heavy suite can occupy MainActor for several seconds.
        // Isolated runs complete in ~50 ms, but allow the queued vnode handler
        // to run under that synthetic contention before declaring failure.
        let deadline = clock.now.advanced(by: .seconds(15))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            await drainMainDispatchQueue()
        }
    }

    private func drainMainDispatchQueue() async {
        // The monitor delivers vnode events on DispatchQueue.main, while this
        // test waits from MainActor. Under the full parallel suite, a resumed
        // MainActor task can repeatedly win before the queued dispatch-source
        // handler. A queue turn preserves the bounded timeout while ensuring
        // already-delivered file events are observed before it is evaluated.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
