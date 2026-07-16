import AppKit
import Darwin.Mach
import FloralMDCore

/// Low-overhead process memory watchdog.
///
/// A background timer samples memory every ten seconds. Normal samples live only
/// in a six-minute ring buffer. The buffer is written to disk only when memory
/// exceeds a conservative threshold or rises unusually fast; continued growth
/// appends one line whenever memory roughly doubles.
final class MemoryWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yingkaisun.floralmd.memory-watchdog",
                                      qos: .utility)
    private let contextLock = NSLock()
    private var cachedContext = "documents=0"
    private var cachedContextDate = Date.distantPast

    private var source: DispatchSourceTimer?
    private var contextTimer: Timer?
    private var tracker = MemoryIncidentTracker()
    private var incidentURL: URL?
    private let sampleInterval: TimeInterval = 10
    private let logsDirectory: URL

    @MainActor init(logsDirectory: URL = AppSettings.logDirectory) {
        self.logsDirectory = logsDirectory
    }

    @MainActor func start() {
        guard source == nil else { return }
        refreshContext()
        pruneOldIncidentReports()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + sampleInterval,
                       repeating: sampleInterval,
                       leeway: .seconds(1))
        // `start()` is main-actor isolated, so an unannotated closure created
        // here inherits MainActor isolation under Swift 6. Dispatch invokes the
        // handler on `queue`; make that boundary explicit or the first sample
        // traps in `_dispatch_assert_queue_fail`.
        let sampleHandler: @Sendable () -> Void = { [weak self] in
            self?.takeSample()
        }
        timer.setEventHandler(handler: sampleHandler)
        source = timer
        timer.resume()

        contextTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval,
                                            repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshContext() }
        }
    }

    @MainActor func stop() {
        contextTimer?.invalidate()
        contextTimer = nil
        source?.cancel()
        source = nil
    }

    @MainActor private func refreshContext() {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? Document }
        let entries = documents.map { document -> String in
            let name = sanitized(document.fileURL?.lastPathComponent ?? document.displayName)
            guard let editor = document.editor else { return "\(name){editor=not-ready}" }
            let snapshot = editor.memoryDiagnosticSnapshot
            return "\(name){utf16=\(snapshot.sourceUTF16Length),blocks=\(snapshot.blockCount)," +
                "tables=\(snapshot.tableBlockCount),undo=\(snapshot.undoSnapshotCount)," +
                "redo=\(snapshot.redoSnapshotCount),mode=\(snapshot.viewMode)}"
        }
        let context = "documents=\(documents.count) [\(entries.joined(separator: "; "))]"
        contextLock.withLock {
            cachedContext = context
            cachedContextDate = Date()
        }
    }

    private func takeSample() {
        guard let memory = Self.processMemory() else { return }
        let sample = MemoryDiagnosticSample(date: Date(),
                                            footprintBytes: memory.footprint,
                                            residentBytes: memory.resident,
                                            virtualBytes: memory.virtual)
        let event = tracker.ingest(sample)
        switch event {
        case .none:
            break
        case .began:
            beginIncident(at: sample)
        case .milestone:
            appendIncidentLine("growth milestone \(format(sample)) \(contextDescription())")
        case .recovered:
            appendIncidentLine("recovered \(format(sample))")
            incidentURL = nil
        }
    }

    private func beginIncident(at sample: MemoryDiagnosticSample) {
        do {
            try FileManager.default.createDirectory(at: logsDirectory,
                                                    withIntermediateDirectories: true)
            let stamp = Self.filenameFormatter.string(from: sample.date)
            let url = logsDirectory.appendingPathComponent("memory-incident-\(stamp).log")
            var lines = [
                "FloralMD memory incident",
                "started \(Self.timestampFormatter.string(from: sample.date))",
                "policy hard=1024MB rapid=+384MB/30s floor=512MB sample=10s ring=6m",
                "privacy document contents and full paths are not recorded",
                "context \(contextDescription())",
                "recent samples:"
            ]
            lines.append(contentsOf: tracker.ring.samples.map { "  \(format($0))" })
            lines.append("")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            incidentURL = url
        } catch {
            incidentURL = nil
        }
    }

    private func appendIncidentLine(_ line: String) {
        guard let url = incidentURL,
              let data = (Self.timestampFormatter.string(from: Date()) + " " + line + "\n")
                .data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }

    private func contextDescription() -> String {
        contextLock.withLock {
            let age = max(0, Date().timeIntervalSince(cachedContextDate))
            return "contextAge=\(String(format: "%.1f", age))s \(cachedContext)"
        }
    }

    @MainActor private func pruneOldIncidentReports() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let reports = urls.filter {
            $0.lastPathComponent.hasPrefix("memory-incident-") && $0.pathExtension == "log"
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for url in reports.dropFirst(10) { try? FileManager.default.removeItem(at: url) }
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: ";", with: "_")
    }

    private func format(_ sample: MemoryDiagnosticSample) -> String {
        let mb = 1_048_576.0
        return "\(Self.timestampFormatter.string(from: sample.date)) " +
            "footprint=\(String(format: "%.1f", Double(sample.footprintBytes) / mb))MB " +
            "resident=\(String(format: "%.1f", Double(sample.residentBytes) / mb))MB " +
            "virtual=\(String(format: "%.1f", Double(sample.virtualBytes) / mb))MB"
    }

    private static func processMemory() -> (footprint: UInt64, resident: UInt64, virtual: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(info.phys_footprint), UInt64(info.resident_size), UInt64(info.virtual_size))
    }

    private static let timestampFormatter: DateFormatter = makeFormatter("yyyy-MM-dd HH:mm:ss.SSS")
    private static let filenameFormatter: DateFormatter = makeFormatter("yyyy-MM-dd-HHmmss")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
