import Foundation
import Testing
@testable import FloralMDCore

@Suite("Memory diagnostics")
struct MemoryDiagnosticsTests {
    private let mb: UInt64 = 1_048_576

    @Test("Ring retains only its newest samples")
    func ringCapacity() {
        var ring = MemoryDiagnosticRing(capacity: 3)
        for value in 1...5 {
            ring.append(sample(UInt64(value) * mb))
        }
        #expect(ring.samples.map(\.footprintBytes) == [3 * mb, 4 * mb, 5 * mb])
    }

    @Test("Hard limit begins one incident and growth emits doubling milestones")
    func hardLimitAndMilestones() {
        let policy = policy(hard: 100, floor: 50, growth: 40, recovery: 30)
        var tracker = MemoryIncidentTracker(capacity: 6, policy: policy)

        #expect(tracker.ingest(sample(99)) == .none)
        #expect(tracker.ingest(sample(100)) == .began)
        #expect(tracker.ingest(sample(150)) == .none)
        #expect(tracker.ingest(sample(256)) == .milestone)
        #expect(tracker.ingest(sample(300)) == .none)
        #expect(tracker.ingest(sample(512)) == .milestone)
    }

    @Test("Rapid growth begins an incident below the hard limit")
    func rapidGrowth() {
        let policy = policy(hard: 1_000, floor: 200, growth: 150, recovery: 100)
        var tracker = MemoryIncidentTracker(capacity: 8, policy: policy)

        #expect(tracker.ingest(sample(100)) == .none)
        #expect(tracker.ingest(sample(130)) == .none)
        #expect(tracker.ingest(sample(180)) == .none)
        #expect(tracker.ingest(sample(260)) == .began)
    }

    @Test("Incident rearms only after sustained recovery")
    func recoveryRearms() {
        let policy = policy(hard: 100, floor: 50, growth: 40, recovery: 30,
                            recoverySamples: 2)
        var tracker = MemoryIncidentTracker(capacity: 6, policy: policy)

        #expect(tracker.ingest(sample(100)) == .began)
        #expect(tracker.ingest(sample(20)) == .none)
        #expect(tracker.ingest(sample(40)) == .none)
        #expect(tracker.ingest(sample(20)) == .none)
        #expect(tracker.ingest(sample(20)) == .recovered)
        #expect(tracker.ingest(sample(100)) == .began)
    }

    private func sample(_ bytes: UInt64) -> MemoryDiagnosticSample {
        MemoryDiagnosticSample(date: Date(timeIntervalSince1970: Double(bytes)),
                               footprintBytes: bytes,
                               residentBytes: bytes,
                               virtualBytes: bytes * 2)
    }

    private func policy(hard: UInt64,
                        floor: UInt64,
                        growth: UInt64,
                        recovery: UInt64,
                        recoverySamples: Int = 2) -> MemoryIncidentPolicy {
        MemoryIncidentPolicy(hardLimitBytes: hard,
                             rapidGrowthFloorBytes: floor,
                             rapidGrowthBytes: growth,
                             rapidGrowthWindow: 4,
                             recoveryBytes: recovery,
                             recoverySampleCount: recoverySamples)
    }
}
