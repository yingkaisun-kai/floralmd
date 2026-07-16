import Foundation

/// One process-memory observation retained by the watchdog's in-memory ring.
public struct MemoryDiagnosticSample: Sendable, Equatable {
    public let date: Date
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let virtualBytes: UInt64

    public init(date: Date,
                footprintBytes: UInt64,
                residentBytes: UInt64,
                virtualBytes: UInt64) {
        self.date = date
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.virtualBytes = virtualBytes
    }
}

/// Fixed-capacity FIFO storage. Samples are kept only in memory until an
/// incident is detected, so routine monitoring does not grow a log file.
public struct MemoryDiagnosticRing: Sendable {
    private let capacity: Int
    private var storage: [MemoryDiagnosticSample] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var samples: [MemoryDiagnosticSample] { storage }

    public mutating func append(_ sample: MemoryDiagnosticSample) {
        storage.append(sample)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }
}

public struct MemoryIncidentPolicy: Sendable {
    public let hardLimitBytes: UInt64
    public let rapidGrowthFloorBytes: UInt64
    public let rapidGrowthBytes: UInt64
    public let rapidGrowthWindow: Int
    public let recoveryBytes: UInt64
    public let recoverySampleCount: Int

    public init(hardLimitBytes: UInt64,
                rapidGrowthFloorBytes: UInt64,
                rapidGrowthBytes: UInt64,
                rapidGrowthWindow: Int,
                recoveryBytes: UInt64,
                recoverySampleCount: Int) {
        self.hardLimitBytes = hardLimitBytes
        self.rapidGrowthFloorBytes = rapidGrowthFloorBytes
        self.rapidGrowthBytes = rapidGrowthBytes
        self.rapidGrowthWindow = max(2, rapidGrowthWindow)
        self.recoveryBytes = recoveryBytes
        self.recoverySampleCount = max(1, recoverySampleCount)
    }

    public static let petalMDDefault = MemoryIncidentPolicy(
        hardLimitBytes: 1_024 * 1_024 * 1_024,
        rapidGrowthFloorBytes: 512 * 1_024 * 1_024,
        rapidGrowthBytes: 384 * 1_024 * 1_024,
        rapidGrowthWindow: 4,
        recoveryBytes: 350 * 1_024 * 1_024,
        recoverySampleCount: 3
    )
}

public enum MemoryIncidentEvent: Sendable, Equatable {
    case none
    case began
    case milestone
    case recovered
}

/// Stateful anomaly detector. A first threshold crossing starts one incident;
/// continued growth only emits logarithmic (doubling) milestones, keeping the
/// eventual report bounded even if memory reaches tens of gigabytes.
public struct MemoryIncidentTracker: Sendable {
    public private(set) var ring: MemoryDiagnosticRing
    public let policy: MemoryIncidentPolicy

    private var incidentActive = false
    private var nextMilestoneBytes: UInt64 = 0
    private var consecutiveRecoverySamples = 0

    public init(capacity: Int = 36, policy: MemoryIncidentPolicy = .petalMDDefault) {
        ring = MemoryDiagnosticRing(capacity: capacity)
        self.policy = policy
    }

    public mutating func ingest(_ sample: MemoryDiagnosticSample) -> MemoryIncidentEvent {
        ring.append(sample)

        if incidentActive {
            if sample.footprintBytes < policy.recoveryBytes {
                consecutiveRecoverySamples += 1
                if consecutiveRecoverySamples >= policy.recoverySampleCount {
                    incidentActive = false
                    nextMilestoneBytes = 0
                    consecutiveRecoverySamples = 0
                    return .recovered
                }
            } else {
                consecutiveRecoverySamples = 0
            }

            if sample.footprintBytes >= nextMilestoneBytes {
                repeat {
                    nextMilestoneBytes = nextMilestoneBytes.multipliedReportingOverflow(by: 2).partialValue
                } while nextMilestoneBytes > 0 && sample.footprintBytes >= nextMilestoneBytes
                return .milestone
            }
            return .none
        }

        let recent = ring.samples.suffix(policy.rapidGrowthWindow)
        let rapidGrowth = recent.count == policy.rapidGrowthWindow
            && sample.footprintBytes >= policy.rapidGrowthFloorBytes
            && sample.footprintBytes >= recent.first!.footprintBytes
            && sample.footprintBytes - recent.first!.footprintBytes >= policy.rapidGrowthBytes

        guard sample.footprintBytes >= policy.hardLimitBytes || rapidGrowth else { return .none }
        incidentActive = true
        consecutiveRecoverySamples = 0
        nextMilestoneBytes = max(policy.hardLimitBytes * 2,
                                 nextPowerOfTwo(above: sample.footprintBytes))
        return .began
    }

    private func nextPowerOfTwo(above value: UInt64) -> UInt64 {
        guard value < UInt64.max / 2 else { return UInt64.max }
        var result: UInt64 = 1
        while result <= value && result <= UInt64.max / 2 { result *= 2 }
        return result
    }
}

/// Compact editor state included in incident reports. No document content or
/// full path is captured.
public struct EditorMemoryDiagnosticSnapshot: Sendable {
    public let sourceUTF16Length: Int
    public let blockCount: Int
    public let tableBlockCount: Int
    public let undoSnapshotCount: Int
    public let redoSnapshotCount: Int
    public let viewMode: String
}

extension EditorTextView {
    @MainActor public var memoryDiagnosticSnapshot: EditorMemoryDiagnosticSnapshot {
        let mode: String
        switch viewMode {
        case .edit: mode = "edit"
        case .reading: mode = "reading"
        case .source: mode = "source"
        }
        return EditorMemoryDiagnosticSnapshot(
            sourceUTF16Length: rawSource.utf16.count,
            blockCount: blocks.count,
            tableBlockCount: blocks.lazy.filter {
                if case .table = $0.kind { return true }
                return false
            }.count,
            undoSnapshotCount: undoStack.count,
            redoSnapshotCount: redoStack.count,
            viewMode: mode
        )
    }
}
