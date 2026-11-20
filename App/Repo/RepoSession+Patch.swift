// Patch files from a tab: Copy as Patch and Save as Patch for commits, the working tree's changes or one file, and the
// Apply Patch preview of a file or the clipboard. Exports and reads run off the main actor at the worktree's top level.
import AppKit
import HistqCore
import UniformTypeIdentifiers

/// What Copy as Patch and Save as Patch export.
enum PatchExport: Sendable, Hashable {
    /// Commits in graph order (newest first), as a mail series.
    case commits([String])
    /// The working tree's unstaged, staged or all changes.
    case workingTree(PatchFile.WorkingTreePart)
    /// One file's change (root-relative paths; `originalPath` is a rename's old path).
    case file(path: String, originalPath: String?, source: PatchFile.FileSource)

    /// The Save panel's proposed name; `subject` is the commit's subject for a single commit.
    func defaultFileName(subject: String? = nil) -> String {
        switch self {
        case .commits(let hashes):
            guard let newest = hashes.first?.prefix(7) else { return "changes.patch" }
            if hashes.count > 1 { return "\(newest)-\(hashes.count)-commits.patch" }
            let slug = (subject ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
                .prefix(52)
            return "\(newest)\(slug.isEmpty ? "" : "-" + slug).patch"
        case .workingTree(.unstaged): return "working-changes.patch"
        case .workingTree(.staged): return "staged-changes.patch"
        case .workingTree(.all): return "all-changes.patch"
        case .file(let path, _, _): return URL(filePath: path).lastPathComponent + ".patch"
        }
    }
}

extension RepoSession {
    /// Builds `target` off the main actor and puts it on the clipboard as text.
    func copyPatch(_ target: PatchExport) {
        let untracked = untrackedForPatch(target)
        let endOperation = beginOperation("Copy as Patch")
        Task { [weak self] in
            defer { endOperation() }
            guard let self else { return }
            do {
                let backend = try await backend()
                let patch = try await Self.buildPatch(target, untracked: untracked, backend: backend, cwd: url)
                // Strict: a non-UTF-8 file in the patch would come out altered as text.
                guard let text = String(data: patch, encoding: .utf8) else {
                    postToast(.warning(
                        "Copy as Patch", detail: "This patch is not UTF-8 text: save it to a file instead."))
                    return
                }
                RepoMenus.copy(text)
                postToast(.success("Copied patch"))
            } catch {
                postToast(.warning("Copy as Patch", detail: Self.message(for: error)))
            }
        }
    }

    /// Asks where to save `target` as a patch file, then builds and writes it off the main actor.
    func savePatch(_ target: PatchExport) {
        var subject: String?
        if case .commits(let hashes) = target, hashes.count == 1, let log = log.value,
           let index = log.commitIndex[hashes[0]] {
            subject = log.commits[index].subject
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = target.defaultFileName(subject: subject)
        panel.begin { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let endOperation = beginOperation("Save as Patch")
                defer { endOperation() }
                // Read now, as the tracked changes are: the status may have changed while the panel was open.
                let untracked = untrackedForPatch(target)
                do {
                    let backend = try await backend()
                    try await Self.writePatch(target, untracked: untracked, to: file, backend: backend, cwd: url)
                    postToast(.success("Saved patch", detail: file.lastPathComponent))
                } catch {
                    postToast(.warning("Save as Patch", detail: Self.message(for: error)))
                }
            }
        }
    }

    /// Asks for a patch file, then opens the Apply Patch preview on it. The file's size is checked against
    /// `PatchFile.maxBytes` before it is read, off the main actor; a file that cannot be read opens the preview with
    /// the reason.
    func chooseAndPreviewPatch() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "patch"), UTType(filenameExtension: "diff"), .plainText]
            .compactMap { $0 }
        panel.prompt = "Preview"
        panel.message = "A patch or diff file to apply"
        Task { [weak self] in
            guard await panel.begin() == .OK, let file = panel.url, let self else { return }
            // Loading at once (the click reacts first): a slow volume's read fills the same preview.
            openPatchPreview(source: file.lastPathComponent) { try await Self.readPatchFile(file) }
        }
    }

    /// Opens the Apply Patch preview on the clipboard's text.
    func previewClipboardPatch() {
        let source = "Clipboard"
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            patchPreview = PatchPreviewRequest(source: source, error: "The clipboard has no text.")
            return
        }
        guard text.utf8.count <= PatchFile.maxBytes else {
            patchPreview = PatchPreviewRequest(source: source, error: PatchFile.InputError.tooLarge.message)
            return
        }
        openPatchPreview(data: Data(text.utf8), source: source)
    }

    // MARK: Helpers

    /// The untracked files an unstaged or whole working tree export adds, without a nested repo's folder (`inner/`),
    /// which the export cannot read as a file.
    private func untrackedForPatch(_ target: PatchExport) -> [String] {
        guard case .workingTree(let part) = target, part != .staged else { return [] }
        return status.value?.untracked.map(\.path).filter { !$0.hasSuffix("/") } ?? []
    }

    /// `target` as patch data: the read environment of the tab's folder, git run at the worktree's top level.
    @concurrent
    private nonisolated static func buildPatch(
        _ target: PatchExport, untracked: [String], backend: Backend, cwd: URL
    ) async throws -> Data {
        let env = try await backend.readEnvironment(cwd: cwd)
        let top = backend.directories.worktree
        switch target {
        case .commits(let hashes):
            return try await PatchFile.commits(hashes, runner: backend.runner, cwd: top, env: env)
        case .workingTree(let part):
            return try await PatchFile.workingTree(
                part, untracked: untracked, runner: backend.runner, cwd: top, env: env)
        case .file(let path, let originalPath, let source):
            return try await PatchFile.file(
                path: path, originalPath: originalPath, source: source, runner: backend.runner, cwd: top, env: env)
        }
    }

    @concurrent
    private nonisolated static func writePatch(
        _ target: PatchExport, untracked: [String], to file: URL, backend: Backend, cwd: URL
    ) async throws {
        let patch = try await buildPatch(target, untracked: untracked, backend: backend, cwd: cwd)
        try patch.write(to: file, options: .atomic)
    }

    /// A chosen patch file's bytes, refused before reading when it is larger than `PatchFile.maxBytes`.
    @concurrent
    private nonisolated static func readPatchFile(_ file: URL) async throws -> Data {
        // The target's size, not a symbolic link's.
        let size = try file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= PatchFile.maxBytes else { throw PatchFile.InputError.tooLarge }
        return try Data(contentsOf: file)
    }
}
