import Darwin
import Foundation

/// Watches one file for writes from tools that do not participate in
/// NSFileCoordinator. Atomic-save editors replace the watched inode, so rename
/// and delete events re-open the path and continue watching the replacement.
@MainActor
public final class ExternalFileMonitor {
    private let url: URL
    private let debounce: Duration
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retryTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var isRunning = false

    public init(url: URL,
                debounce: Duration = .milliseconds(150),
                onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        retryTask?.cancel()
        notificationTask?.cancel()
        source?.cancel()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        installSource()
    }

    public func stop() {
        isRunning = false
        retryTask?.cancel()
        retryTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        source?.cancel()
        source = nil
    }

    private func installSource() {
        guard isRunning, source == nil else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRetry()
            return
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: .main
        )
        newSource.setCancelHandler {
            close(descriptor)
        }
        newSource.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        source = newSource
        newSource.resume()
    }

    private func handleEvent() {
        guard let source else { return }
        let flags = source.data
        scheduleNotification()

        if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
            source.cancel()
            self.source = nil
            // Atomic writes have normally installed the replacement by the time
            // the old inode reports rename/delete. Re-arm immediately so a
            // second quick save cannot land inside the retry delay. If the path
            // is briefly absent, installSource() falls back to the retry loop.
            installSource()
        }
    }

    private func scheduleNotification() {
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, isRunning else { return }
            onChange()
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, isRunning else { return }
            retryTask = nil
            installSource()
        }
    }
}
