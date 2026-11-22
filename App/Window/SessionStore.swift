// Session restore (Dblore `LaunchSession*`): the windows, their native tab groups and their app tabs, saved as JSON
// under `StatePaths.root` a second after each change and once more at quit, and read back off the main thread at the
// next launch. A repo folder that is gone (or no longer a git repository) comes back as a "Repo not found" tab. The
// same writer saves every open workspace file, each before `session.json`.
import AppKit
import Foundation
import HistqCore
import os

extension SavedWindow {
    var frame: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

/// Reads the saved session at launch and writes it, and every open workspace file, on changes. Capture is off until
/// the launch has opened its windows (restored or not), and stops for good once quit begins: the closing windows must
/// not save an empty session (or fewer workspace windows) over the one quit wrote.
@MainActor
enum SessionStore {
    /// A saved session read at launch, with the repo folders that are gone or no longer git repositories.
    struct Loaded: Sendable {
        let session: SavedSession
        let missing: Set<String>
    }

    /// What capture returns: the session, and each open workspace's file by its identity key
    /// (`WorkspaceFile.identityKey(for:)`) with whether it is read-only (never written).
    struct Snapshot {
        var session: SavedSession
        var workspaces: [String: (file: WorkspaceFile, isReadOnly: Bool)]
    }

    private static let debounce: Duration = .seconds(1)
    private static var loadTask: Task<Loaded?, Never>?
    /// Builds the current snapshot; set by `start`, which turns capture on.
    private static var capture: (() -> Snapshot)?
    private static var pending: Task<Void, Never>?
    private static var isQuitting = false
    /// Workspaces `finish` wrote for the last time: no later pass writes them, until `seed` or `writeNow` opens the
    /// key again.
    private static var finished = Set<String>()
    /// Writes in call order off the main thread; quit waits on it.
    private static let queue = DispatchQueue(label: "com.math2it.histq.session")
    /// The last model written (or seeded) per workspace identity key, so an unchanged file is not written again. Only
    /// touched on `queue`.
    private nonisolated(unsafe) static var written: [String: WorkspaceFile] = [:]
    /// The workspace keys whose last write failed, so a pass that finds the file back at its last written model (and
    /// skips it) still reports the success. Only touched on `queue`.
    private nonisolated(unsafe) static var failed = Set<String>()
    private nonisolated static let logger = Logger(subsystem: "com.math2it.histq", category: "session")

    /// Each workspace write's outcome by identity key (nil on success), on the main actor. Skipped files (unchanged,
    /// read-only, no window) report nothing, but an unchanged one whose last write failed reports success: the file
    /// holds that content.
    static var onWriteResult: ((String, Error?) -> Void)?

    /// `session.json` in the state folder: Application Support, or the DEBUG `-HistqStateDir` of a QA run.
    static var file: URL { StatePaths.root.appending(path: "session.json", directoryHint: .notDirectory) }

    /// Starts reading the saved session off the main thread; called once at the top of `main()`, so the read is
    /// usually done before the launch asks for it.
    static func startLoading() {
        let file = file
        loadTask = Task.detached(priority: .userInitiated) { load(from: file) }
    }

    /// The saved session, once read; nil when there is none, it cannot be decoded, or it has neither a window nor a
    /// workspace.
    static func loaded() async -> Loaded? {
        await loadTask?.value
    }

    /// Turns capture on with `capture` as the source; the launch calls it once its windows are open.
    static func start(_ capture: @escaping () -> Snapshot) {
        self.capture = capture
    }

    /// Saves the session and the open workspaces a second after the last change, so a crash or a kill still finds a
    /// recent one.
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
            let pass = writePass(capture())
            queue.async { write(pass) }
        }
    }

    /// Quit: stops the debounced writer and saves every changed file while the windows are still open, before the
    /// process exits (the writes are waited for).
    static func saveForQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        pending?.cancel()
        pending = nil
        guard let capture else { return }
        let pass = writePass(capture())
        queue.sync { write(pass) }
    }

    /// Close Workspace: writes the workspace `key` one last time (skipped when unchanged), with the other changed
    /// files, then forgets it. A second call, or one during quit, does nothing.
    static func finish(_ key: String) {
        guard !isQuitting, !finished.contains(key), let capture else { return }
        let pass = writePass(capture())
        finished.insert(key)
        queue.async {
            write(pass)
            written[key] = nil
        }
    }

    /// The model an open workspace's restored windows capture as, so its file is written only once it changes.
    static func seed(_ key: String, _ file: WorkspaceFile) {
        finished.remove(key)
        queue.async { written[key] = file }
    }

    /// Writes `file` to `url` now, on the writer's queue, throwing its error (Save As, New Workspace). On success the
    /// model is cached, so the first capture of the workspace does not write it again.
    static func writeNow(_ file: WorkspaceFile, to url: URL) throws {
        let key = WorkspaceFile.identityKey(for: url)
        try queue.sync {
            try file.write(to: url)
            written[key] = file
        }
        finished.remove(key)
    }

    /// One write pass: the writable workspace files by identity key, then the session.
    private struct Pass: Sendable {
        let workspaces: [(key: String, file: WorkspaceFile)]
        let session: SavedSession
        let file: URL
    }

    private static func writePass(_ snapshot: Snapshot) -> Pass {
        let workspaces = snapshot.workspaces
            .filter { !$0.value.isReadOnly && !finished.contains($0.key) }
            .map { (key: $0.key, file: $0.value.file) }
            .sorted { $0.key < $1.key }
        return Pass(workspaces: workspaces, session: snapshot.session, file: file)
    }

    // MARK: File

    private nonisolated static func load(from file: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let decoded = try? JSONDecoder().decode(SavedSession.self, from: data),
              decoded.version == SavedSession.currentVersion
        else {
            logger.error("session.json ignored: unreadable or another version")
            return nil
        }
        let session = decoded.normalized()
        // Closing the last window saves an empty session: a normal state, not a broken file.
        guard !session.windows.isEmpty || session.workspaces != nil else { return nil }
        let paths = Set(session.windows.flatMap { $0.tabs.compactMap(\.path) })
        return Loaded(session: session, missing: paths.filter { !SavedSession.isRepository($0) })
    }

    /// Writes every workspace file of `pass` whose model changed since its last write, each failure logged without
    /// stopping the others, then the session: a crash between the two never leaves windows that left `session.json`
    /// without their workspace file.
    private nonisolated static func write(_ pass: Pass) {
        for (key, file) in pass.workspaces {
            let result: Error?
            if written[key] == file {
                guard failed.remove(key) != nil else { continue }
                result = nil
            } else {
                do {
                    try file.write(to: URL(fileURLWithPath: key, isDirectory: false))
                    written[key] = file
                    failed.remove(key)
                    result = nil
                } catch WorkspaceFile.FileError.empty {
                    logger.notice("workspace file skipped: it has no window, or a window with no tab")
                    continue
                } catch {
                    logger.error("workspace file not saved: \(error.localizedDescription, privacy: .public)")
                    failed.insert(key)
                    result = error
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onWriteResult?(key, result) }
            }
        }
        write(pass.session, to: pass.file)
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
