// Key-feature tests for workspace files (workspaces plan, phase 1 task 5), in a temp folder with fake repos (a folder
// with a `.git` folder) and a fake home inside it: the version-1 contract, `session.json` after the move, how stored
// `path` / `home` strings resolve and come back unchanged (an uploaded tab icon too), lossless reads, the writer's
// empty refusal, a write and paths through a symlink, Save As to another folder and the file's identity key.
import Foundation
import HistqCore
import Testing

struct WorkspaceFileTests {
    static let groupID = UUID(uuidString: "6A0B5C1E-2D3F-4A5B-8C7D-9E0F1A2B3C4D")!
    static let windowA = UUID(uuidString: "0D2A6B7C-1111-4222-8333-444455556666")!
    static let windowB = UUID(uuidString: "0D2A6B7C-7777-4888-9999-AAAABBBBCCCC")!
    // Not in id order, so a fallback sort by id would change the file's order.
    static let work = Profile(id: UUID(uuidString: "EEEEEEEE-0000-4000-8000-000000000001")!, name: "Work",
                              color: "#3A8EE5", identity: .init(name: "Me", email: "me@work.invalid"))
    static let personal = Profile(id: UUID(uuidString: "11111111-0000-4000-8000-000000000002")!, name: "Personal",
                                  color: "#E5B13A", identity: .init(name: "Me", email: "me@histq.invalid"),
                                  ssh: .keyFile(path: "~/.ssh/id_personal"))

    /// A temp folder with a fake home (`home/`) and helpers to place fake repos and workspace files.
    struct Sandbox {
        let root: URL
        var home: URL { url("home") }

        init() throws {
            root = try Fixtures.makeTempDirectory("HistqWorkspaceFile")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func url(_ relative: String) -> URL { root.appending(path: relative) }

        /// The standardized absolute path of `relative`, the form every resolved key has.
        func key(_ relative: String) -> String { WorkspaceFile.standardized(url(relative).path) }

        /// A fake repo: a folder with a `.git` folder.
        func makeRepo(_ relative: String) throws {
            try FileManager.default.createDirectory(at: url(relative).appending(path: ".git"),
                                                    withIntermediateDirectories: true)
        }

        /// Writes `json` at `relative`, creating its folder.
        @discardableResult
        func writeFile(_ relative: String, _ json: String) throws -> URL {
            let file = url(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(json.utf8).write(to: file)
            return file
        }

        /// A symlink at `relative` to `target`, creating its folder.
        func makeLink(_ relative: String, to target: URL) throws -> URL {
            let link = url(relative)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            return link
        }

        func remove() { Fixtures.removeTempDirectory(root) }
    }

    static func json(_ profile: Profile) throws -> String {
        String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
    }

    /// A version-1 file in the writer's form (no `null`, every repo with a full view): two windows, a named tab group,
    /// a Welcome tab, two repos (`lib` before `app`, not sorted by path) and two profiles (not sorted by id).
    static func teamFile() throws -> String {
        """
        {
          "version": 1,
          "windows": [
            { "id": "\(windowA.uuidString)",
              "tabGroups": [ { "id": "\(groupID.uuidString)", "name": "Release", "color": 3 } ],
              "tabs": [
                { "path": "../repos/app", "home": "~/git/repos/app", "profile": "\(work.id.uuidString)",
                  "alias": "App", "pinned": true, "iconColor": 2 },
                { "path": "../repos/lib", "home": "~/git/repos/lib", "profile": "none", "emoji": "📦",
                  "group": "\(groupID.uuidString)" },
                { "path": "../repos/app", "home": "~/git/repos/app", "group": "\(groupID.uuidString)" },
                {}
              ] },
            { "id": "\(windowB.uuidString)",
              "tabs": [ { "path": "../repos/lib", "home": "~/git/repos/lib", "profile": "\(personal.id.uuidString)",
                          "archived": true } ] }
          ],
          "repos": [
            { "path": "../repos/lib", "home": "~/git/repos/lib",
              "view": { "hidden": ["refs/heads/old"], "solo": [], "pinned": ["refs/heads/main"], "hideStale": true } },
            { "path": "../repos/app", "home": "~/git/repos/app",
              "view": { "hidden": [], "solo": ["refs/heads/dev"], "pinned": [], "hideStale": false } }
          ],
          "profiles": [ \(try json(work)), \(try json(personal)) ]
        }
        """
    }

    static func jsonObject(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: - Contract

    @Test("a literal version-1 workspace decodes; a version-2 one is refused")
    func versionOneDecodesVersionTwoIsRefused() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let file = try sandbox.writeFile("ws/team.histqws", try Self.teamFile())
        let read = try WorkspaceFile.read(file)
        #expect(read.isLossless)
        #expect(read.file.version == 1)
        #expect(read.file.windows.map(\.id) == [Self.windowA, Self.windowB])
        #expect(read.file.windows[0].tabGroups == [.init(id: Self.groupID, name: "Release", color: 3)])
        #expect(read.file.windows[1].tabGroups == nil)
        #expect(read.file.windows[0].tabs[0] == WorkspaceFile.Tab(
            path: "../repos/app", home: "~/git/repos/app", profile: .id(Self.work.id), alias: "App", pinned: true,
            iconColor: 2))
        #expect(read.file.windows[0].tabs[1].group == Self.groupID && read.file.windows[0].tabs[1].profile == SavedProfile.none)
        #expect(read.file.windows[0].tabs[3] == WorkspaceFile.Tab())
        #expect(read.file.repos.map(\.path) == ["../repos/lib", "../repos/app"])
        #expect(read.file.profiles == [Self.work, Self.personal])

        // A profile written by hand, as in profiles.json.
        let signed = try sandbox.writeFile("ws/signed.histqws", """
        { "version": 1, "windows": [ { "id": "\(Self.windowA.uuidString)", "tabs": [ {} ] } ], "repos": [],
          "profiles": [ { "id": "\(Self.work.id.uuidString)", "name": "Work", "color": "#3A8EE5",
                          "identity": { "name": "Me", "email": "me@work.invalid" },
                          "signing": { "gpg": { "keyID": "ABCD1234" } }, "signByDefault": true,
                          "ssh": { "keyFile": { "path": "~/.ssh/id_work" } },
                          "github": { "host": "github.com", "login": "me" } } ] }
        """)
        var work = Profile(
            id: Self.work.id, name: "Work", color: "#3A8EE5", identity: .init(name: "Me", email: "me@work.invalid"),
            signing: .gpg(keyID: "ABCD1234"), signByDefault: true, ssh: .keyFile(path: "~/.ssh/id_work"))
        work.setAccount(HostingAccount(kind: .github, host: "github.com", login: "me"))
        #expect(try WorkspaceFile.read(signed).file.profiles == [work])

        let newer = try sandbox.writeFile("ws/newer.histqws", #"{ "version": 2, "windows": [], "tiles": [] }"#)
        #expect(throws: WorkspaceFile.FileError.unsupportedVersion(2)) { try WorkspaceFile.read(newer) }
    }

    @Test("a version-1 session.json of an older build decodes and re-encodes as it was, its tab group included")
    func olderSessionRoundTrips() throws {
        let group = "C3D4E5F6-0000-4000-8000-0000000000AA"
        let literal = """
        {
          "version": 1,
          "windows": [ {
            "x": 120, "y": 80.5, "width": 1280, "height": 800, "group": 0, "tabIndex": 0, "isSelectedInGroup": true,
            "selectedTab": 1,
            "manualTabGroups": [ { "id": "\(group)", "name": "Review", "color": 5, "collapsed": true } ],
            "tabs": [
              { "path": "/Users/someone/git/app", "profile": "none", "pinned": true },
              { "path": "/Users/someone/git/lib", "tabGroup": "\(group)", "alias": "Lib" },
              {}
            ]
          } ]
        }
        """
        let session = try JSONDecoder().decode(SavedSession.self, from: Data(literal.utf8))
        #expect(session.workspaces == nil)
        #expect(session.windows[0].manualTabGroups == [SavedTabGroup(id: UUID(uuidString: group)!, name: "Review",
                                                                     color: 5, collapsed: true)])
        #expect(session.windows[0].tabs[1].tabGroup == UUID(uuidString: group))

        let encoded = try Self.jsonObject(JSONEncoder().encode(session))
        #expect(encoded["workspaces"] == nil)
        #expect(encoded == (try Self.jsonObject(Data(literal.utf8))))
    }

    // MARK: - Resolving

    enum Move: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The repos moved together with the file: `path` resolves, `home` does not.
        case together
        /// The file moved alone: `path` does not resolve, `home` does.
        case fileAlone
        /// Neither resolves: every tab is missing and every `repos[]` entry is carried.
        case neither

        var testDescription: String { rawValue }
    }

    @Test("stored path / home resolve to standardized keys and come back unchanged on the next save",
          arguments: Move.allCases)
    func roundTripKeepsStoredStrings(move: Move) throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fileURL: URL
        let expected: [String: String]  // repo name → resolved (or missing) key
        switch move {
        case .together:
            fileURL = try sandbox.writeFile("moved/ws/team.histqws", try Self.teamFile())
            try sandbox.makeRepo("moved/repos/app")
            try sandbox.makeRepo("moved/repos/lib")
            expected = ["app": sandbox.key("moved/repos/app"), "lib": sandbox.key("moved/repos/lib")]
        case .fileAlone:
            fileURL = try sandbox.writeFile("elsewhere/ws/team.histqws", try Self.teamFile())
            try sandbox.makeRepo("home/git/repos/app")
            try sandbox.makeRepo("home/git/repos/lib")
            expected = ["app": sandbox.key("home/git/repos/app"), "lib": sandbox.key("home/git/repos/lib")]
        case .neither:
            fileURL = try sandbox.writeFile("lonely/ws/team.histqws", try Self.teamFile())
            expected = ["app": sandbox.key("home/git/repos/app"), "lib": sandbox.key("home/git/repos/lib")]
        }

        let read = try WorkspaceFile.read(fileURL)
        let resolved = read.file.resolved(fileURL: fileURL, homeURL: sandbox.home,
                                          isRepository: SavedSession.isRepository)

        let tabPaths = resolved.windows.flatMap(\.tabs).map(\.path)
        #expect(tabPaths == [expected["app"], expected["lib"], expected["app"], nil, expected["lib"]])
        #expect(resolved.repoOrder == [expected["lib"]!, expected["app"]!])
        #expect(resolved.profileOrder == [Self.work.id, Self.personal.id])
        if move == .neither {
            #expect(resolved.missing == Set(expected.values))
            #expect(resolved.views.isEmpty && Set(resolved.carried.keys) == Set(expected.values))
        } else {
            #expect(resolved.missing.isEmpty && resolved.carried.isEmpty)
            #expect(resolved.views[expected["lib"]!]?.hideStale == true)
        }
        let keys = tabPaths.compactMap { $0 } + Array(resolved.missing) + Array(resolved.originals.keys)
            + Array(resolved.views.keys) + Array(resolved.carried.keys) + resolved.repoOrder
        for key in keys {
            #expect(key == WorkspaceFile.standardized(key) && !key.contains(".."), "not standardized: \(key)")
        }

        let rebuilt = WorkspaceFile(windows: resolved.windows, views: resolved.views,
                                    profiles: [Self.personal, Self.work], carried: resolved.carried,
                                    originals: resolved.originals, repoOrder: resolved.repoOrder,
                                    profileOrder: resolved.profileOrder, fileURL: fileURL, homeURL: sandbox.home)
        #expect(rebuilt == read.file)
        let encoded = try Self.jsonObject(JSONEncoder().encode(rebuilt))
        #expect(encoded == (try Self.jsonObject(Data(try Self.teamFile().utf8))))

        // An uploaded image on the emoji tab: written as `icon` without `emoji`, read back as the same mark.
        let iconName = String(repeating: "0123456789abcdef", count: 4) + ".png"
        let ref = CustomIcon.ref(fileName: iconName)
        var windows = resolved.windows
        windows[0].tabs[1].mark = ref
        let withIcon = WorkspaceFile(windows: windows, views: resolved.views, profiles: [Self.personal, Self.work],
                                     carried: resolved.carried, originals: resolved.originals,
                                     repoOrder: resolved.repoOrder, profileOrder: resolved.profileOrder,
                                     fileURL: fileURL, homeURL: sandbox.home)
        try withIcon.write(to: fileURL)
        let tabs = try #require((Self.jsonObject(Data(contentsOf: fileURL))["windows"] as? [NSDictionary])?
            .first?["tabs"] as? [NSDictionary])
        #expect(tabs[1]["icon"] as? String == iconName && tabs[1]["emoji"] == nil)
        let reread = try WorkspaceFile.read(fileURL)
        #expect(reread.isLossless)
        let back = reread.file.resolved(fileURL: fileURL, homeURL: sandbox.home,
                                        isRepository: SavedSession.isRepository)
        #expect(back.windows[0].tabs[1].mark == ref)
    }

    @Test("a closed group's tabs resolve like open tabs and the file reads lossless and comes back unchanged")
    func closedGroupRoundTrips() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeRepo("ws/repos/app")
        let fileURL = try sandbox.writeFile("ws/team.histqws", """
            { "version": 1, "repos": [], "profiles": [],
              "windows": [ { "id": "\(Self.windowA.uuidString)", "tabs": [ {} ],
                "closedTabGroups": [ { "id": "\(Self.groupID.uuidString)", "name": "Later", "color": 2,
                  "tabs": [ { "path": "repos/app", "home": "~/git/app", "emoji": "🧪" },
                            { "path": "repos/gone", "home": "~/git/gone" } ] } ] } ] }
            """)

        let read = try WorkspaceFile.read(fileURL)
        #expect(read.isLossless)
        let resolved = read.file.resolved(fileURL: fileURL, homeURL: sandbox.home,
                                          isRepository: SavedSession.isRepository)
        let closed = try #require(resolved.windows.first?.closedTabGroups?.first)
        #expect(closed.id == Self.groupID && closed.name == "Later" && closed.color == 2)
        #expect(closed.tabs.map(\.path) == [sandbox.key("ws/repos/app"), sandbox.key("home/git/gone")])
        #expect(closed.tabs.first?.emoji == "🧪")

        let rebuilt = WorkspaceFile(windows: resolved.windows, views: resolved.views, profiles: [],
                                    carried: resolved.carried, originals: resolved.originals,
                                    repoOrder: resolved.repoOrder, profileOrder: resolved.profileOrder,
                                    fileURL: fileURL, homeURL: sandbox.home)
        #expect(rebuilt == read.file)
    }

    // MARK: - Reading and writing

    @Test("an unknown key makes a read lossy; a null-valued optional key does not")
    func unknownKeyIsLossyNullIsNot() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        // The README example: `null` values for optional keys.
        let withNulls = try sandbox.writeFile("ws/nulls.histqws", """
        { "version": 1,
          "windows": [ { "id": "\(Self.windowA.uuidString)",
            "tabs": [ { "path": "../repos/app", "home": "~/git/repos/app", "profile": "none", "alias": "App",
                        "emoji": null, "pinned": true, "iconColor": 2, "archived": null },
                      { "path": null } ] } ],
          "repos": [ { "path": "../repos/app", "home": "~/git/repos/app",
                       "view": { "hidden": [], "solo": [], "pinned": [], "hideStale": false } } ],
          "profiles": [] }
        """)
        #expect(try WorkspaceFile.read(withNulls).isLossless)

        // A later build's field on a tab.
        let withUnknown = try sandbox.writeFile("ws/unknown.histqws", """
        { "version": 1,
          "windows": [ { "id": "\(Self.windowA.uuidString)",
            "tabs": [ { "path": "../repos/app", "home": "~/git/repos/app", "badge": "beta" } ] } ],
          "repos": [], "profiles": [] }
        """)
        #expect(try WorkspaceFile.read(withUnknown).isLossless == false)
    }

    @Test("a workspace with no window, or with a window without tabs, is never written")
    func writeRefusesEmpty() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let target = sandbox.url("empty.histqws")
        #expect(throws: WorkspaceFile.FileError.empty) { try WorkspaceFile(windows: []).write(to: target) }
        let emptyWindow = WorkspaceFile(windows: [.init(id: Self.windowA, tabs: [.init()]), .init(id: Self.windowB, tabs: [])])
        #expect(throws: WorkspaceFile.FileError.empty) { try emptyWindow.write(to: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path) == ["home"])
    }

    @Test("writing through a symlink replaces its target: mode 600, pretty-printed with sorted keys, read back equal")
    func writeThroughSymlink() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let target = try sandbox.writeFile("team/ws/team.histqws", "{}")
        let link = try sandbox.makeLink("desk/team.histqws", to: target)
        let file = try JSONDecoder().decode(WorkspaceFile.self, from: Data(try Self.teamFile().utf8))

        try file.write(to: link)

        let manager = FileManager.default
        #expect(try manager.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600)
        #expect(try manager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
            == ["team.histqws"])
        let text = try String(contentsOf: target, encoding: .utf8)
        let keys = try ["\"profiles\"", "\"repos\"", "\"version\"", "\"windows\""]
            .map { try #require(text.range(of: $0)?.lowerBound) }
        #expect(text.contains("\n  ") && keys == keys.sorted())
        let read = try WorkspaceFile.read(link)
        #expect(read.isLossless && read.file == file)
    }

    @Test("a symlinked file resolves and builds its paths from its target's folder, not the link's")
    func symlinkUsesTargetFolder() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let target = try sandbox.writeFile("team/ws/team.histqws", """
        { "version": 1, "windows": [ { "id": "\(Self.windowA.uuidString)", "tabs": [ { "path": "../repos/app" } ] } ],
          "repos": [], "profiles": [] }
        """)
        try sandbox.makeRepo("team/repos/app")
        let link = try sandbox.makeLink("desk/team.histqws", to: target)

        let resolved = try WorkspaceFile.read(link).file.resolved(fileURL: link, homeURL: sandbox.home,
                                                                  isRepository: SavedSession.isRepository)
        #expect(resolved.windows[0].tabs.map(\.path) == [sandbox.key("team/repos/app")])
        #expect(resolved.missing.isEmpty)

        let live = WorkspaceFile.LiveWindow(id: Self.windowA, tabs: [SavedTab(path: sandbox.key("team/repos/app"))])
        let fresh = WorkspaceFile(windows: [live], views: [:], profiles: [], carried: [:], originals: [:],
                                  repoOrder: [], profileOrder: [], fileURL: link, homeURL: sandbox.home)
        #expect(fresh.windows[0].tabs[0].path == "../repos/app")
    }

    @Test("a workspace under a symlinked folder keeps its paths short and resolves them in the link's path space")
    func symlinkedAncestorKeepsLexicalPaths() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try FileManager.default.createDirectory(at: sandbox.url("real"), withIntermediateDirectories: true)
        _ = try sandbox.makeLink("linked", to: sandbox.url("real"))
        let fileURL = try sandbox.writeFile("linked/ws/team.histqws", "{}")
        try sandbox.makeRepo("linked/repos/app")

        func stored(_ absolute: String) -> String? {
            let live = WorkspaceFile.LiveWindow(id: Self.windowA, tabs: [SavedTab(path: absolute)])
            return WorkspaceFile(windows: [live], views: [:], profiles: [], carried: [:], originals: [:],
                                 repoOrder: [], profileOrder: [], fileURL: fileURL, homeURL: sandbox.home)
                .windows[0].tabs[0].path
        }
        #expect(stored(sandbox.key("linked/repos/app")) == "../repos/app", "the app's path, through the link")
        // The two forms share the temp folder, so the real one is kept as written, not compared by realpath(3).
        #expect(stored(sandbox.key("real/repos/app")) == "../../real/repos/app", "the same repo by its real path")

        let file = WorkspaceFile(windows: [.init(id: Self.windowA, tabs: [.init(path: "../repos/app")])])
        let resolved = file.resolved(fileURL: fileURL, homeURL: sandbox.home, isRepository: SavedSession.isRepository)
        #expect(resolved.windows[0].tabs.map(\.path) == [sandbox.key("linked/repos/app")])
        #expect(resolved.missing.isEmpty)
    }

    @Test("a repo folder that is a symlink to elsewhere keeps the path it has in the workspace's tree")
    func symlinkedRepoKeepsLexicalPath() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeFile("team/ws/team.histqws", "{}")
        try sandbox.makeRepo("elsewhere/app")
        _ = try sandbox.makeLink("team/repos/app", to: sandbox.url("elsewhere/app"))

        let live = WorkspaceFile.LiveWindow(id: Self.windowA, tabs: [SavedTab(path: sandbox.key("team/repos/app"))])
        let file = WorkspaceFile(windows: [live], views: [:], profiles: [], carried: [:], originals: [:],
                                 repoOrder: [], profileOrder: [], fileURL: fileURL, homeURL: sandbox.home)
        #expect(file.windows[0].tabs[0].path == "../repos/app")

        let resolved = file.resolved(fileURL: fileURL, homeURL: sandbox.home, isRepository: SavedSession.isRepository)
        #expect(resolved.windows[0].tabs.map(\.path) == [sandbox.key("team/repos/app")])
        #expect(resolved.missing.isEmpty)
    }

    // MARK: - Save As

    @Test("Save As elsewhere keeps the home of missing tabs and carried repos, with a path from the new folder")
    func saveAsRebasesUnresolvedEntries() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let oldURL = try sandbox.writeFile("home/old/ws/team.histqws", """
        { "version": 1,
          "windows": [ { "id": "\(Self.windowA.uuidString)",
            "tabs": [ { "path": "../repos/app", "home": "~/stale/app" },
                      { "path": "../gone", "home": "~/git/gone" } ] } ],
          "repos": [ { "path": "../repos/app", "home": "~/stale/app",
                       "view": { "hidden": [], "solo": [], "pinned": [], "hideStale": false } },
                     { "path": "../lost", "home": "~/git/lost",
                       "view": { "hidden": ["refs/heads/x"], "solo": [], "pinned": [], "hideStale": false } } ],
          "profiles": [] }
        """)
        try sandbox.makeRepo("home/old/repos/app")
        let resolved = try WorkspaceFile.read(oldURL).file.resolved(fileURL: oldURL, homeURL: sandbox.home,
                                                                    isRepository: SavedSession.isRepository)
        #expect(resolved.missing == [sandbox.key("home/git/gone")])
        #expect(Set(resolved.carried.keys) == [sandbox.key("home/git/lost")])

        // One level deeper than the old file, so every relative path changes.
        let newURL = sandbox.url("home/new/deep/team.histqws")
        let rebased = WorkspaceFile.rebased(originals: resolved.originals, missing: resolved.missing,
                                            carried: resolved.carried, fileURL: newURL, homeURL: sandbox.home)
        let saved = WorkspaceFile(windows: resolved.windows, views: resolved.views, profiles: [],
                                  carried: rebased.carried, originals: rebased.originals,
                                  repoOrder: resolved.repoOrder, profileOrder: resolved.profileOrder,
                                  fileURL: newURL, homeURL: sandbox.home)
        let file = try JSONDecoder().decode(WorkspaceFile.self, from: JSONEncoder().encode(saved))

        let tabs = file.windows[0].tabs
        #expect(tabs[0].path == "../../old/repos/app" && tabs[0].home == "~/old/repos/app", "resolved: fresh")
        #expect(tabs[1].path == "../../git/gone" && tabs[1].home == "~/git/gone", "missing: home kept")
        #expect(file.repos == [
            .init(path: "../../old/repos/app", home: "~/old/repos/app", view: .empty),
            .init(path: "../../git/lost", home: "~/git/lost", view: .init(hidden: ["refs/heads/x"])),
        ])
    }

    // MARK: - Identity

    @Test("a file and a symlink to it share one key, the same before and after the file exists")
    func identityKeyIsStable() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let file = sandbox.url("team.histqws")
        let before = WorkspaceFile.identityKey(for: file)
        try Data("{}".utf8).write(to: file)
        let after = WorkspaceFile.identityKey(for: file)
        let link = sandbox.url("link.histqws")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(before == after)
        #expect(WorkspaceFile.identityKey(for: link) == after)
    }
}
