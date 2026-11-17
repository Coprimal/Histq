// Security tests for the AI diff filter (task 1.1): a file matched by `.aiignore` never reaches an AI request, not
// its contents nor its header, whichever of its paths matches (a rename's old path, a C-quoted path, the header of
// a binary or mode-only entry, where any way to split an ambiguous header that matches drops it). Key core tests:
// folder and anchored patterns match as in gitignore, `**` spans folders, case is ignored only to over-exclude (a
// negated class matches when any case of the character is outside it), a symlinked or folder `.aiignore` throws and
// a missing one is nil, a diff whose every file is ignored is reported as nothing left, and a lock file is cut to its
// header unless it is the only change.
import Foundation
import HistqCore
import Testing

struct AIDiffFilterTests {
    let readme = """
        diff --git a/README.md b/README.md
        index 1111111..2222222 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -Old title
        +New title

        """

    // MARK: - .aiignore

    @Test("an ignored file is dropped whole, header included, with one closing note")
    func ignoredFileIsDroppedWhole() {
        let secret = """
            diff --git a/secrets/key.pem b/secrets/key.pem
            index 1111111..2222222 100644
            --- a/secrets/key.pem
            +++ b/secrets/key.pem
            @@ -1 +1 @@
            -OLD-KEY
            +NEW-KEY

            """
        let result = AIPrompts.filtered(secret + readme, ignore: AIIgnore(text: "secrets/\n"))

        #expect(result == readme + "[Histq: 1 files left out by .aiignore]\n")
    }

    @Test("a rename is dropped when only its old path is ignored")
    func renameMatchedByOldPath() {
        let rename = """
            diff --git a/secrets/key.pem b/public/key.pem
            similarity index 100%
            rename from secrets/key.pem
            rename to public/key.pem

            """
        let result = AIPrompts.filtered(rename + readme, ignore: AIIgnore(text: "/secrets\n"))

        #expect(result == readme + "[Histq: 1 files left out by .aiignore]\n")
    }

    @Test("a C-quoted path is unquoted before matching")
    func quotedPathIsUnquoted() {
        let quoted = #"""
            diff --git "a/caf\303\251/key.pem" "b/caf\303\251/key.pem"
            index 1111111..2222222 100644
            --- "a/caf\303\251/key.pem"
            +++ "b/caf\303\251/key.pem"
            @@ -1 +1 @@
            -OLD-KEY
            +NEW-KEY

            """#
        let result = AIPrompts.filtered(quoted + readme, ignore: AIIgnore(text: "/café/\n"))

        #expect(result == readme + "[Histq: 1 files left out by .aiignore]\n")
    }

    @Test("binary and mode-only entries with spaces and no ---/+++ lines are matched by their header")
    func headerOnlyEntriesFailClosed() {
        let diff = """
            diff --git a/secret keys/id rsa b/secret keys/id rsa
            index 1111111..2222222 100644
            Binary files a/secret keys/id rsa and b/secret keys/id rsa differ
            diff --git a/secret keys/run me.sh b/secret keys/run me.sh
            old mode 100644
            new mode 100755
            diff --git a/x b/secret keys/y b/x b/secret keys/y
            old mode 100644
            new mode 100755
            diff --git a/my notes.bin b/my notes.bin
            index 1111111..2222222 100644
            Binary files a/my notes.bin and b/my notes.bin differ

            """
        let result = AIPrompts.filtered(diff, ignore: AIIgnore(text: "/secret keys/\n"))

        #expect(result == """
            diff --git a/my notes.bin b/my notes.bin
            index 1111111..2222222 100644
            Binary files a/my notes.bin and b/my notes.bin differ
            [Histq: 3 files left out by .aiignore]

            """)
    }

    @Test("a folder pattern and an anchored one exclude every file under them, not look-alike names")
    func folderAndAnchoredPatterns() {
        let ignore = AIIgnore(text: "# keys\n\nsecrets/\n/config/keys\n!secrets/public.pem\n")

        #expect(ignore.matches("secrets/a/key.pem"))
        #expect(ignore.matches("lib/secrets/b.pem"))
        #expect(ignore.matches("secrets/public.pem"))
        #expect(ignore.matches("config/keys/x.json"))
        #expect(!ignore.matches("src/secrets.swift"))
        #expect(!ignore.matches("secrets"))
        #expect(!ignore.matches("app/config/keys/x.json"))
    }

    @Test("** spans any number of folders; * and ? never cross a slash; a leading / anchors to the root")
    func globPatterns() {
        let ignore = AIIgnore(text: "**/build/*.log\ndocs/**\na/**/b\n/root.txt\nnotes-?.md\n")

        #expect(ignore.matches("build/x.log"))
        #expect(ignore.matches("x/y/build/x.log"))
        #expect(!ignore.matches("build/sub/x.log"))
        #expect(ignore.matches("docs/a/b.md"))
        #expect(!ignore.matches("docs"))
        #expect(ignore.matches("a/b"))
        #expect(ignore.matches("a/x/y/b"))
        #expect(ignore.matches("root.txt"))
        #expect(!ignore.matches("sub/root.txt"))
        #expect(ignore.matches("deep/notes-1.md"))
        #expect(!ignore.matches("notes-12.md"))
    }

    @Test("bracket classes and backslash escapes match as in gitignore, ignoring case only to over-exclude")
    func classesEscapesAndCase() {
        let ignore = AIIgnore(text: [
            "*.[pk]em", "id_[!d]sa*", "v[0-9].txt", "w[!0-9].txt", ##"\#notes"##, #"\!important"#, #"trail\ "#,
            "Secret.TXT",
        ].joined(separator: "\n"))

        #expect(ignore.matches("keys/a.pem"))
        #expect(ignore.matches("a.kem"))
        #expect(!ignore.matches("a.xem"))
        #expect(ignore.matches("id_rsa.pub"))
        // `D` is outside `[!d]`: a negated class matches any letter that has another case.
        #expect(ignore.matches("id_dsa"))
        #expect(!ignore.matches("w7.txt"))
        #expect(ignore.matches("wx.txt"))
        #expect(ignore.matches("v7.txt"))
        #expect(!ignore.matches("vx.txt"))
        #expect(ignore.matches("#notes"))
        #expect(ignore.matches("!important"))
        #expect(!ignore.matches("important"))
        #expect(ignore.matches("trail "))
        #expect(!ignore.matches("trail"))
        #expect(ignore.matches("docs/secret.txt"))
        #expect(ignore.matches("KEY.PEM"))
    }

    @Test("a negated class matches a name whose other case it excludes")
    func negatedClassIgnoresCaseOnlyToExclude() {
        #expect(AIIgnore(text: "[!a]*").matches("Apple"))
        #expect(AIIgnore(text: "[!A-Z]*").matches("foo"))
        #expect(AIIgnore(text: "secret-[!a]*").matches("secret-Apple.txt"))
    }

    // MARK: - Loading .aiignore and nothing left

    /// A fresh temporary worktree folder; `body` gets it and it is removed afterwards.
    func withWorktree(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "histq-aiignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test("a missing .aiignore gives nil and a regular one is read")
    func missingAIIgnoreIsNil() throws {
        try withWorktree { dir in
            #expect(try AIIgnore.load(worktree: dir) == nil)
            try Data("secrets/\n".utf8).write(to: dir.appending(path: ".aiignore"))
            #expect(try AIIgnore.load(worktree: dir) == AIIgnore(text: "secrets/\n"))
        }
    }

    @Test("a symlinked .aiignore throws, even when it points at a valid file")
    func symlinkedAIIgnoreThrows() throws {
        try withWorktree { dir in
            let target = dir.appending(path: "patterns.txt")
            try Data("secrets/\n".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: dir.appending(path: ".aiignore"), withDestinationURL: target)
            #expect(throws: AIIgnore.LoadError.unreadable) { try AIIgnore.load(worktree: dir) }
        }
    }

    @Test("a folder named .aiignore throws")
    func folderAIIgnoreThrows() throws {
        try withWorktree { dir in
            try FileManager.default.createDirectory(at: dir.appending(path: ".aiignore"), withIntermediateDirectories: false)
            #expect(throws: AIIgnore.LoadError.unreadable) { try AIIgnore.load(worktree: dir) }
        }
    }

    @Test("a diff whose every file is ignored is reported as nothing left; others pass through")
    func everyFileIgnoredIsNothingLeft() {
        let ignore = AIIgnore(text: "README.md\n")

        #expect(AIPrompts.filteredUnlessAllIgnored(readme, ignore: ignore) == nil)
        #expect(AIPrompts.filteredUnlessAllIgnored(readme, ignore: nil) == readme)
        #expect(AIPrompts.filteredUnlessAllIgnored("", ignore: ignore) == "")
    }

    // MARK: - Skip list

    @Test("a lock file is cut to its header line unless it is the only change")
    func lockFileIsCutUnlessAlone() {
        let lock = """
            diff --git a/web/package-lock.json b/web/package-lock.json
            index 1111111..2222222 100644
            --- a/web/package-lock.json
            +++ b/web/package-lock.json
            @@ -1 +1 @@
            -"version": "1.0.0"
            +"version": "1.0.1"

            """

        #expect(AIPrompts.filtered(lock + readme, ignore: nil) == """
            diff --git a/web/package-lock.json b/web/package-lock.json
            [Histq: contents of this generated or lock file left out]

            """ + readme)
        #expect(AIPrompts.filtered(lock, ignore: nil) == lock)
    }
}
