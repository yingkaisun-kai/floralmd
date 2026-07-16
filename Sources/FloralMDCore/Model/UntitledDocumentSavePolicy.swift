import Darwin
import Foundation

/// Pure policy and state transitions for automatically giving a draft its
/// first file URL. Subsequent saves remain entirely owned by NSDocument.
public enum UntitledDocumentSavePolicy {
    public static func isEligible(
        enabled: Bool,
        hasFileURL: Bool,
        rawSource: String,
        hasMarkedText: Bool
    ) -> Bool {
        enabled
            && !hasFileURL
            && !hasMarkedText
            && !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func debounceDelay(requestedInterval: TimeInterval) -> TimeInterval {
        DocumentAutoSaveInterval.resolved(requestedInterval).rawValue
    }

    public static func fileName(
        at date: Date,
        timeZone: TimeZone = .current,
        sequence: Int = 1
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let suffix = sequence > 1 ? "-\(sequence)" : ""
        return "\(formatter.string(from: date))\(suffix).md"
    }
}

public struct UntitledDocumentSaveState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case scheduled
        case saving
        case failed
    }

    public enum Action: Equatable, Sendable {
        case none
        case cancel
        case schedule
        case beginSave
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    /// A committed edit or an explicit settings change is the only event that
    /// may leave `.failed`, preventing an unattended retry loop.
    public mutating func inputChanged(isEligible: Bool) -> Action {
        guard isEligible else {
            let action: Action = phase == .scheduled ? .cancel : .none
            phase = .idle
            return action
        }
        guard phase != .saving else { return .none }
        phase = .scheduled
        return .schedule
    }

    public mutating func timerFired(isEligible: Bool) -> Action {
        guard phase == .scheduled, isEligible else {
            if phase == .scheduled { phase = .idle }
            return .none
        }
        phase = .saving
        return .beginSave
    }

    public mutating func saveCompleted(success: Bool) {
        phase = success ? .idle : .failed
    }
}

public struct UntitledDocumentFileReservation: Equatable, Sendable {
    public let url: URL

    public static func reserve(
        in directory: URL,
        at date: Date = Date(),
        timeZone: TimeZone = .current,
        maximumAttempts: Int = 10_000
    ) throws -> Self {
        guard maximumAttempts > 0 else {
            throw CocoaError(.fileWriteFileExists)
        }

        for sequence in 1...maximumAttempts {
            let candidate = directory.appendingPathComponent(
                UntitledDocumentSavePolicy.fileName(
                    at: date,
                    timeZone: timeZone,
                    sequence: sequence
                ),
                isDirectory: false
            )
            let descriptor = candidate.path.withCString {
                open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            }
            if descriptor >= 0 {
                close(descriptor)
                return Self(url: candidate)
            }
            if errno == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        throw CocoaError(.fileWriteFileExists)
    }

    /// Remove only the untouched zero-byte placeholder. If a failed
    /// NSDocument save wrote any bytes, leave them in place rather than risk
    /// deleting recoverable content.
    public func removeIfEmpty(fileManager: FileManager = .default) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue == 0 else { return }
        try? fileManager.removeItem(at: url)
    }
}
