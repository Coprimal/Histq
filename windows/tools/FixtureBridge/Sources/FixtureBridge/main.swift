// fixture-bridge: HistqCore's side of the cross-OS fixtures (windows/README.md, "Cross-platform fixtures").
//
//   export <file>                         writes {workspace, session, profiles, repoView} as the Mac app encodes them
//   check <file>                          decodes the Windows port's file with HistqCore and re-encodes it: any decode
//                                         failure or any value the round trip changes exits non-zero
//   export-workspace <out>                writes the VM's tab workspace (/HistqQA/data/qa-tabs.histqws, repos in
//                                         /HistqQA/fx/tabs) with HistqCore's own writer
//   check-workspace <file> <expected>     compares each tab's stored `path`, group and pin with the expected file's
//
// Every id is fixed and the formats hold no dates, so each export writes the same bytes on every run.
import Foundation
import HistqCore

struct Fixtures: Codable {
    var workspace: WorkspaceFile
    var session: SavedSession
    var profiles: [Profile]
    var repoView: RepoViewState
}

struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func id(_ text: String) -> UUID { UUID(uuidString: text)! }

// MARK: - export

let workID = id("3F2A1B0C-0000-4000-8000-000000000001")
let personalID = id("3F2A1B0C-0000-4000-8000-000000000002")
let plainID = id("3F2A1B0C-0000-4000-8000-000000000003")
let coreGroup = id("7C1D2E3F-0000-4000-8000-000000000011")
let looseGroup = id("7C1D2E3F-0000-4000-8000-000000000012")
let oldGroup = id("7C1D2E3F-0000-4000-8000-000000000013")
let windowA = id("A1B2C3D4-0000-4000-8000-000000000021")
let windowB = id("A1B2C3D4-0000-4000-8000-000000000022")
let iconName = String(repeating: "0123456789abcdef", count: 4) + ".png"

func fixtureProfiles() -> [Profile] {
    var work = Profile(id: workID, name: "Work", color: "#3A8EE5",
                       identity: .init(name: "QA Work", email: "qa@work.invalid"),
                       signing: .gpg(keyID: "ABCDEF0123456789"), signByDefault: true, ssh: .agent)
    work.setAccount(HostingAccount(kind: .github, host: "github.com", login: "qa-work"))
    work.setAccount(HostingAccount(kind: .gitlab, host: "git.example.invalid", basePath: "/gitlab", login: "qa",
                                   gitUsername: "oauth2", oauthClientID: "client-1"))
    let personal = Profile(id: personalID, name: "Personal", color: "#E5B13A",
                           identity: .init(name: "QA", email: "qa@histq.invalid"),
                           signing: .ssh(keyPath: "~/.ssh/id_ed25519.pub"), ssh: .keyFile(path: "~/.ssh/id_ed25519"))
    let plain = Profile(id: plainID, name: "Plain \u{00E9}t\u{00E9}", color: "#66CBA0",
                        identity: .init(name: "Plain", email: "plain@histq.invalid"))
    return [work, personal, plain]
}

func fixtureRepoView() -> RepoViewState {
    RepoViewState(hidden: ["refs/heads/old", "refs/tags/v0.1"], solo: ["refs/heads/main"],
                  pinned: ["refs/remotes/origin/main"], hideStale: true)
}

func fixtureWorkspace(profiles: [Profile], view: RepoViewState) -> WorkspaceFile {
    let tabs: [WorkspaceFile.Tab] = [
        .init(path: "repos/alpha", home: "~/Work/repos/alpha", profile: .id(workID), alias: "Alpha", pinned: true),
        .init(path: "../src/beta", home: "~/src/beta", profile: SavedProfile.none, emoji: "\u{1F680}", iconColor: 3,
              group: coreGroup),
        .init(path: "../../../Volumes/Ext/gamma", home: "/Volumes/Ext/gamma", icon: iconName, group: looseGroup),
        .init(),
        .init(path: "repos/delta", home: "~/Work/repos/delta", archived: true),
    ]
    let closed = WorkspaceFile.ClosedTabGroup(id: oldGroup, name: "Old", color: 5,
                                              tabs: [.init(path: "repos/old", home: "~/Work/repos/old")])
    let first = WorkspaceFile.Window(id: windowA,
                                     tabGroups: [.init(id: coreGroup, name: "Core", color: 2),
                                                 .init(id: looseGroup, color: 0)],
                                     tabs: tabs, closedTabGroups: [closed])
    let second = WorkspaceFile.Window(id: windowB, tabs: [.init(path: ".", home: "~/Work")])
    let repos: [WorkspaceFile.Repo] = [
        .init(path: "repos/alpha", home: "~/Work/repos/alpha", view: view),
        .init(path: "../src/beta", home: "~/src/beta", view: .empty),
        .init(path: "repos/gone", home: "~/Work/repos/gone"),
    ]
    return WorkspaceFile(windows: [first, second], repos: repos, profiles: [profiles[0]])
}

func fixtureSession() -> SavedSession {
    let tabs: [SavedTab] = [
        SavedTab(path: "/Users/qa/Work/repos/alpha", profile: .id(workID), alias: "Alpha", pinned: true),
        SavedTab(path: "/Users/qa/src/beta", profile: SavedProfile.none, emoji: "\u{1F680}", iconColor: 3,
                 tabGroup: coreGroup),
        SavedTab(path: "/Volumes/Ext/gamma", icon: iconName, tabGroup: looseGroup),
        SavedTab(),
        SavedTab(path: "/Users/qa/Work/repos/delta", archived: true),
    ]
    let first = SavedWindow(x: 120.5, y: 80, width: 1280, height: 800.25, group: 0, tabIndex: 0,
                            isSelectedInGroup: true, tabs: tabs, selectedTab: 1,
                            manualTabGroups: [SavedTabGroup(id: coreGroup, name: "Core", color: 2, collapsed: true),
                                              SavedTabGroup(id: looseGroup, color: 0)],
                            closedTabGroups: [SavedClosedTabGroup(id: oldGroup, name: "Old", color: 5,
                                                                  tabs: [SavedTab(path: "/Users/qa/Work/repos/old")])])
    let second = SavedWindow(x: -40, y: 0, width: 900, height: 600, group: 1, tabIndex: 0, isSelectedInGroup: false,
                             tabs: [SavedTab()])
    let layouts = [
        WorkspaceLayout(path: "/Users/qa/Work/team.histqws", open: true, windows: [
            .init(id: windowA, x: 10, y: 20.75, width: 1100, height: 700, group: 2, tabIndex: 0, isSelectedInGroup: true,
                  selectedPath: "/Users/qa/Work/repos/alpha", collapsedGroups: [coreGroup]),
            .init(id: windowB, x: 30, y: 40, width: 800, height: 500, group: 2, tabIndex: 1, isSelectedInGroup: false),
        ]),
        WorkspaceLayout(path: "/Users/qa/Old/old.histqws", open: false, windows: []),
    ]
    return SavedSession(windows: [first, second], workspaces: layouts)
}

/// The settings the app writes its state files with: the workspace file's (`WorkspaceFile.write(to:)`), which add
/// `.withoutEscapingSlashes` to the session's and profiles' `[.prettyPrinted, .sortedKeys]`; every file uses the
/// default date and data strategies.
func appEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}

func export(to path: String) throws {
    let profiles = fixtureProfiles()
    let view = fixtureRepoView()
    let fixtures = Fixtures(workspace: fixtureWorkspace(profiles: profiles, view: view), session: fixtureSession(),
                            profiles: profiles, repoView: view)
    var data = try appEncoder().encode(fixtures)
    data.append(0x0A)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

// MARK: - check

/// Decodes `json` as `T` with the app's decoder, encodes it again and requires the same JSON value back.
func roundTrip<T: Codable>(_ type: T.Type, _ json: Any, _ name: String) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
    let value: T
    do {
        value = try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw Failure("\(name): HistqCore cannot decode it: \(error)")
    }
    let again = try JSONSerialization.jsonObject(with: appEncoder().encode(value), options: [.fragmentsAllowed])
    guard (json as AnyObject).isEqual(again) else {
        throw Failure("\(name): re-encoding with HistqCore changes it")
    }
    return value
}

func check(_ path: String) throws {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    guard let object = root as? [String: Any] else { throw Failure("the file is not a JSON object") }
    let expected: Set = ["workspace", "session", "profiles", "repoView"]
    guard Set(object.keys) == expected else {
        throw Failure("keys are \(object.keys.sorted()), expected \(expected.sorted())")
    }
    let workspace = try roundTrip(WorkspaceFile.self, object["workspace"]!, "workspace")
    guard workspace.version == WorkspaceFile.currentVersion else {
        throw Failure("workspace: version \(workspace.version), HistqCore reads \(WorkspaceFile.currentVersion)")
    }
    let session = try roundTrip(SavedSession.self, object["session"]!, "session")
    guard session.version == SavedSession.currentVersion else {
        throw Failure("session: version \(session.version), HistqCore reads \(SavedSession.currentVersion)")
    }
    _ = try roundTrip([Profile].self, object["profiles"]!, "profiles")
    _ = try roundTrip(RepoViewState.self, object["repoView"]!, "repoView")
}

// MARK: - export-workspace

/// The QA tab repos of task 9.1 as the Windows VM has them under C:\HistqQA, with /HistqQA standing in for it.
let qaFile = "/HistqQA/data/qa-tabs.histqws"
let qaHome = "/Users/qa"
let qaWindow = id("5E1F0A2B-0000-4000-8000-000000000031")
let docsGroup = id("5E1F0A2B-0000-4000-8000-000000000032")
let qaNames = ["docs", "api", "api-w2", "t1", "t2"]

func exportWorkspace(to out: String) throws {
    func repo(_ name: String) -> String { "/HistqQA/fx/tabs/\(name)" }
    let tabs = [
        SavedTab(path: repo("docs"), pinned: true),
        SavedTab(path: repo("api"), tabGroup: docsGroup),
        SavedTab(path: repo("api-w2"), tabGroup: docsGroup),
        SavedTab(path: repo("t1")),
        SavedTab(path: repo("t2")),
    ]
    let window = WorkspaceFile.LiveWindow(id: qaWindow, tabGroups: [.init(id: docsGroup, name: "Docs", color: 2)],
                                          tabs: tabs)
    var views: [String: RepoViewState] = [:]
    for name in qaNames { views[repo(name)] = .empty }
    let file = WorkspaceFile(windows: [window], views: views, profiles: [], carried: [:], originals: [:],
                             repoOrder: qaNames.map(repo), profileOrder: [],
                             fileURL: URL(fileURLWithPath: qaFile), homeURL: URL(fileURLWithPath: qaHome))
    let stored = file.windows.flatMap(\.tabs).map(\.path)
    guard stored == qaNames.map({ "../fx/tabs/\($0)" }) else {
        throw Failure("stored paths are \(stored), expected ../fx/tabs/<name>")
    }
    let url = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try file.write(to: url)
}

// MARK: - check-workspace

func checkWorkspace(_ path: String, expected: String) throws {
    let actual = try WorkspaceFile.read(URL(fileURLWithPath: path)).file
    let wanted = try WorkspaceFile.read(URL(fileURLWithPath: expected)).file
    guard actual.windows.count == wanted.windows.count else {
        throw Failure("\(actual.windows.count) windows, expected \(wanted.windows.count)")
    }
    for (index, (got, want)) in zip(actual.windows, wanted.windows).enumerated() {
        guard got.tabGroups ?? [] == want.tabGroups ?? [] else {
            throw Failure("window \(index): tab groups \(got.tabGroups ?? []), expected \(want.tabGroups ?? [])")
        }
        guard got.tabs.count == want.tabs.count else {
            throw Failure("window \(index): \(got.tabs.count) tabs, expected \(want.tabs.count)")
        }
        for (position, (tab, other)) in zip(got.tabs, want.tabs).enumerated() {
            guard tab.path == other.path, tab.group == other.group, tab.pinned ?? false == other.pinned ?? false else {
                throw Failure("window \(index) tab \(position): path \(tab.path ?? "nil"), group "
                    + "\(tab.group?.uuidString ?? "nil"), pinned \(tab.pinned ?? false); expected path "
                    + "\(other.path ?? "nil"), group \(other.group?.uuidString ?? "nil"), pinned \(other.pinned ?? false)")
            }
        }
    }
}

// MARK: - main

let usage = """
    usage: fixture-bridge export <file>
           fixture-bridge check <file>
           fixture-bridge export-workspace <out>
           fixture-bridge check-workspace <file> <expected>
    """

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case ("export", 2): try export(to: arguments[1])
    case ("check", 2): try check(arguments[1])
    case ("export-workspace", 2): try exportWorkspace(to: arguments[1])
    case ("check-workspace", 3): try checkWorkspace(arguments[1], expected: arguments[2])
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("fixture-bridge: \(error)\n".utf8))
    exit(1)
}
