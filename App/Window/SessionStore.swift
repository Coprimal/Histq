// Session restore (Dblore `LaunchSession*`): the windows, their native tab groups and their app tabs, saved as JSON
// under `StatePaths.root` a second after each change and once more at quit, and read back off the main thread at the
// next launch that opens no folder. A repo folder that is gone (or no longer a git repository) comes back as a
// "Repo not found" tab.
import AppKit
import Foundation
import HistqCore
import os

extension SavedWindow {
    var frame: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

/// Reads the saved session at launch and writes it on changes. Capture is off until the launch has opened its
/// windows (restored or not), and stops for good once quit begins: the closing windows must not save an empty
/// session over the one quit wrote.
@MainActor
enum SessionStore {
    /// A saved session read at launch, with the repo folders that are gone or no longer git repositories.
    struct Loaded: Sendable {
        let session: SavedSession
        let missing: Set<String>
    }

    private static let debounce: Duration = .seconds(1)
    private static var loadTask: Task<Loaded?, Never>?
    /// Builds the current session; set by `start`, which turns capture on.
    private static var capture: (() -> SavedSession)?
    private static var pending: Task<Void, Never>?
    private static var isQuitting = false
    /// Writes in call order off the main thread; quit waits on it.
    private static let queue = DispatchQueue(label: "com.math2it.histq.session")
    private nonisolated static let logger = Logger(subsystem: "com.math2it.histq", category: "session")

    /// `session.json` in the state folder: Application Support, or the DEBUG `-HistqStateDir` of a QA run.
    static var file: URL { StatePaths.root.appending(path: "session.json", directoryHint: .notDirectory) }

    /// Starts reading the saved session off the main thread; called once at the top of `main()`, so the read is
    /// usually done before the launch asks for it.
    static func startLoading() {
        let file = file
        loadTask = Task.detached(priority: .userInitiated) { load(from: file) }
    }

    /// The saved session, once read; nil when there is none, it cannot be decoded, or it has no window.
    static func loaded() async -> Loaded? {
        await loadTask?.value
    }

    /// Turns capture on with `capture` as the source; the launch calls it once its windows are open.
    static func start(_ capture: @escaping () -> SavedSession) {
        self.capture = capture
    }

    /// Saves the session a second after the last change, so a crash or a kill still finds a recent one.
    static func schedule() {
        guard capture != nil, !isQuitting else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard !isQuitting, let capture else { return }
            let session = capture()
            let file = file
            queue.async { write(session, to: file) }
        }
    }

    /// Quit: stops the debounced writer and saves the session while the windows are still open, before the process
    /// exits (the write is waited for).
    static func saveForQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        pending?.cancel()
        pending = nil
        guard let capture else { return }
        let session = capture()
        let file = file
        queue.sync { write(session, to: file) }
    }

    // MARK: File

    private nonisolated static func load(from file: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              session.version == SavedSession.currentVersion
        else {
            logger.error("session.json ignored: unreadable or another version")
            return nil
        }
        // Closing the last window saves an empty session: a normal state, not a broken file.
        guard !session.windows.isEmpty else { return nil }
        let paths = Set(session.windows.flatMap { $0.tabs.compactMap(\.path) })
        return Loaded(session: session, missing: paths.filter { !SavedSession.isRepository($0) })
    }

    /// Writes `session` atomically (a temp file in the same folder, then `rename(2)`), with mode 600: it lists the
    /// user's repo paths. As `ProfileStore.save`.
    private nonisolated static func write(_ session: SavedSession, to file: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(session)
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path]) }
            do {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: data)
                try handle.close()
                guard rename(temp.path, file.path) == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
                }
            } catch {
                unlink(temp.path)
                throw error
            }
        } catch {
            logger.error("session.json not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
