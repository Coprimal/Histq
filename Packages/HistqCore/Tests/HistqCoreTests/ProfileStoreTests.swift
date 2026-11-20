// Key-feature tests for ProfileStore (task 7.1), in a temp folder (never the app's Application Support): a
// remembered repo resolves to its profile after a save and reload, under another spelling of its path; an
// unknown repo gets the default; a repo whose profile was deleted falls back to the default. Importing a
// workspace's profiles (workspaces plan, phase 1) only adds unknown ids and never changes local settings.
// The file format of accounts (hosting task 4.1): a legacy `github` key reads as one account, both keys are
// written, an account of an unknown kind survives a save, a profile without accounts is saved as before, one account
// per host.
import Foundation
import HistqCore
import Testing

struct ProfileStoreTests {
    static let personal = Profile(name: "Personal", color: "#E5B13A", identity: .init(name: "Me", email: "me@histq.invalid"))
    static let work = Profile(name: "Work", color: "#3A8EE5", identity: .init(name: "Me", email: "me@work.invalid"))

    /// A temp folder with a store file path and two repo folders.
    struct Sandbox {
        let folder: URL
        var file: URL { folder.appending(path: "state/profiles.json") }

        init() throws {
            folder = try Fixtures.makeTempDirectory("HistqProfileStore")
            for name in ["repo-a", "repo-b"] {
                try FileManager.default.createDirectory(at: repo(name), withIntermediateDirectories: true)
            }
        }

        /// The repo as `Fixtures` spells it (`/var/...`, symlinks stripped), not its real path (`/private/var/...`).
        func repo(_ name: String) -> URL { folder.appending(path: name, directoryHint: .isDirectory) }

        func remove() { Fixtures.removeTempDirectory(folder) }
    }

    @Test("a remembered repo resolves to its profile after a reload, under another spelling of its path")
    func rememberedRepoResolvesToItsProfile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var store = ProfileStore(profiles: [Self.personal, Self.work], defaultProfileID: Self.personal.id)
        store.remember(Self.work.id, forRepo: sandbox.repo("repo-a"))
        try store.save(to: sandbox.file)

        let loaded = try ProfileStore.load(from: sandbox.file)
        #expect(loaded == store)
        let realPath = ProfileStore.repoKey(sandbox.repo("repo-a"))
        #expect(realPath != sandbox.repo("repo-a").path, "the lookup uses another spelling (/private/var, not /var)")
        #expect(loaded.profile(forRepo: URL(filePath: realPath + "/")) == Self.work)
        let mode = try FileManager.default.attributesOfItem(atPath: sandbox.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("an unknown repo gets the default profile; a missing file is an empty store")
    func unknownRepoGetsDefault() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        #expect(try ProfileStore.load(from: sandbox.file) == ProfileStore())
        var store = ProfileStore(profiles: [Self.personal, Self.work], defaultProfileID: Self.work.id)
        store.remember(Self.personal.id, forRepo: sandbox.repo("repo-a"))
        #expect(store.profile(forRepo: sandbox.repo("repo-b")) == Self.work)
    }

    @Test("a repo whose profile was deleted falls back to the default, also when the file still names it")
    func deletedProfileFallsBackToDefault() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var store = ProfileStore(profiles: [Self.personal, Self.work], defaultProfileID: Self.personal.id)
        store.remember(Self.work.id, forRepo: sandbox.repo("repo-a"))
        try store.save(to: sandbox.file)

        // A file edited elsewhere: the work profile is gone, but the repo still names it.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sandbox.file)) as? [String: Any])
        json["profiles"] = (json["profiles"] as? [[String: Any]])?.filter { $0["id"] as? String != Self.work.id.uuidString }
        try JSONSerialization.data(withJSONObject: json).write(to: sandbox.file)
        let edited = try ProfileStore.load(from: sandbox.file)
        #expect(edited.profiles == [Self.personal] && Array(edited.repoProfiles.values) == [Self.work.id])
        #expect(edited.profile(forRepo: sandbox.repo("repo-a")) == Self.personal)

        store.delete(id: Self.work.id)
        #expect(store.profile(forRepo: sandbox.repo("repo-a")) == Self.personal)
        #expect(store.repoProfiles.isEmpty)
    }

    @Test("importing a workspace's profiles adds the unknown ones once, the first of a repeated id")
    func importAddsUnknownProfilesOnce() {
        let shared = Profile(name: "Shared", color: "#55AA55", identity: .init(name: "Team", email: "team@histq.invalid"))
        var repeated = shared
        repeated.name = "Shared (later copy)"
        var store = ProfileStore(profiles: [Self.personal])

        let added = store.importProfiles([shared, repeated])
        #expect(added == [shared])
        #expect(store.profiles == [Self.personal, shared])
    }

    @Test("importing never replaces a local profile of the same id, nor the default or the repos' profiles")
    func importKeepsLocalProfilesAndSettings() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var store = ProfileStore(profiles: [Self.personal, Self.work], defaultProfileID: Self.personal.id)
        store.remember(Self.work.id, forRepo: sandbox.repo("repo-a"))
        let before = store
        var foreignWork = Self.work
        foreignWork.name = "Work (from a workspace)"
        foreignWork.identity.email = "someone@else.invalid"

        let added = store.importProfiles([foreignWork])
        #expect(added.isEmpty)
        #expect(store == before)
        #expect(store.profile(id: Self.work.id) == Self.work)
        #expect(store.defaultProfileID == Self.personal.id)
        #expect(store.repoProfiles == before.repoProfiles && store.repoProfiles.count == 1)
    }

    /// `profiles.json` as builds before multi-account profiles wrote it: one `github` object per profile.
    static let legacyFile = """
        {
          "defaultProfileID" : "6F1C2B0E-3D4A-4E5F-8A9B-0C1D2E3F4A5B",
          "profiles" : [
            {
              "color" : "#E5B13A",
              "github" : { "host" : "GHE.example.com:8443", "login" : "octo" },
              "id" : "6F1C2B0E-3D4A-4E5F-8A9B-0C1D2E3F4A5B",
              "identity" : { "email" : "me@histq.invalid", "name" : "Me" },
              "name" : "Personal",
              "signByDefault" : true,
              "signing" : { "gpg" : { "keyID" : "ABCDEF" } },
              "ssh" : { "keyFile" : { "path" : "/Users/me/.ssh/id_ed25519" } }
            },
            {
              "color" : "#3A8EE5",
              "id" : "7A2D3C1F-4E5B-4F60-9BAC-1D2E3F4A5B6C",
              "identity" : { "email" : "me@work.invalid", "name" : "Me" },
              "name" : "Work",
              "signByDefault" : false,
              "signing" : { "none" : {} },
              "ssh" : { "agent" : {} }
            }
          ],
          "repoProfiles" : { "/private/tmp/repo" : "7A2D3C1F-4E5B-4F60-9BAC-1D2E3F4A5B6C" }
        }
        """

    @Test("a legacy profiles.json with one github object reads as one GitHub account, the rest as before")
    func legacyGitHubKeyDecodes() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try FileManager.default.createDirectory(at: sandbox.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.legacyFile.utf8).write(to: sandbox.file)

        let store = try ProfileStore.load(from: sandbox.file)
        let personal = try #require(store.profiles.first)
        #expect(personal.github == Profile.GitHubAccount(host: "GHE.example.com:8443", login: "octo"))
        #expect(personal.signing == .gpg(keyID: "ABCDEF") && personal.signByDefault)
        #expect(personal.ssh == .keyFile(path: "/Users/me/.ssh/id_ed25519"))
        #expect(personal.identity == .init(name: "Me", email: "me@histq.invalid"))
        let work = try #require(store.profiles.last)
        #expect(store.profiles.count == 2 && work.github == nil && work.ssh == .agent && work.signing == Profile.Signing.none)
        #expect(store.defaultProfileID == personal.id && store.repoProfiles == ["/private/tmp/repo": work.id])
    }

    /// The saved profiles of `file`, as JSON objects.
    static func savedProfiles(_ file: URL) throws -> [[String: Any]] {
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return try #require(json["profiles"] as? [[String: Any]])
    }

    @Test("a GitHub account is saved in accounts and, for older builds, in github")
    func encodingWritesAccountsAndLegacyGitHub() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var profile = Self.personal
        profile.github = .init(host: "github.com", login: "octo")
        profile.setAccount(HostingAccount(kind: .github, host: "GHE.example.com", login: "work-octo"))
        try ProfileStore(profiles: [profile]).save(to: sandbox.file)

        let saved = try #require(Self.savedProfiles(sandbox.file).first)
        let accounts = try #require(saved["accounts"] as? [[String: Any]])
        #expect(accounts.map { $0["host"] as? String } == ["github.com", "GHE.example.com"])
        #expect(accounts.map { $0["kind"] as? String } == ["github", "github"])
        #expect(saved["github"] as? [String: String] == ["host": "github.com", "login": "octo"])
        #expect(try ProfileStore.load(from: sandbox.file).profiles == [profile])
        #expect(profile.account(forHost: "ghe.EXAMPLE.com")?.login == "work-octo")
    }

    @Test("an account of an unknown kind is kept as it was through a load, a change and a save")
    func unknownKindRoundTrips() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let unknown = #"{"kind":"newhost","host":"code.example.com","login":"me","extra":{"n":[1,2.5,true,null,"x"]}}"#
        var json = try #require(JSONSerialization.jsonObject(with: Data(Self.legacyFile.utf8)) as? [String: Any])
        var profiles = try #require(json["profiles"] as? [[String: Any]])
        profiles[0]["accounts"] = [
            try JSONSerialization.jsonObject(with: Data(unknown.utf8)),
            ["kind": "github", "host": "github.com", "login": "octo"],
        ]
        json["profiles"] = profiles
        try FileManager.default.createDirectory(at: sandbox.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: sandbox.file)

        var store = try ProfileStore.load(from: sandbox.file)
        var profile = try #require(store.profiles.first)
        #expect(profile.accounts == [HostingAccount(kind: .github, host: "github.com", login: "octo")])
        profile.github = nil
        #expect(profile.accounts.isEmpty)
        store.upsert(profile)
        try store.save(to: sandbox.file)

        let saved = try #require(Self.savedProfiles(sandbox.file).first)
        let accounts = try #require(saved["accounts"] as? [Any])
        #expect(accounts.count == 1)
        // Compared as sorted JSON text, so `true` and `1`, or `1` and `1.0`, would differ.
        let element = try JSONSerialization.data(withJSONObject: try #require(accounts.first), options: .sortedKeys)
        let expected = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: Data(unknown.utf8)), options: .sortedKeys)
        #expect(String(decoding: element, as: UTF8.self) == String(decoding: expected, as: UTF8.self))
        #expect(saved["github"] == nil)
        #expect(try ProfileStore.load(from: sandbox.file) == store)
    }

    @Test("a profile without accounts is saved as before: no accounts and no github key")
    func profileWithoutAccountsSavesAsBefore() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try ProfileStore(profiles: [Self.personal]).save(to: sandbox.file)

        let saved = try #require(Self.savedProfiles(sandbox.file).first)
        #expect(Set(saved.keys) == ["color", "id", "identity", "name", "signByDefault", "signing", "ssh"])
        let loaded = try ProfileStore.load(from: sandbox.file)
        #expect(loaded.profiles == [Self.personal] && loaded.profiles[0].accounts.isEmpty)
    }

    @Test("setting an account on a host the profile has replaces it, in place")
    func oneAccountPerHost() {
        var profile = Self.personal
        profile.github = .init(host: "github.com", login: "octo")
        profile.setAccount(HostingAccount(kind: .github, host: "ghe.example.com", login: "a"))
        profile.setAccount(HostingAccount(kind: .github, host: "GitHub.com", login: "other"))
        #expect(profile.accounts.map(\.login) == ["other", "a"])
        profile.github = .init(host: "github.com", login: "third")
        #expect(profile.accounts.map(\.host) == ["github.com", "ghe.example.com"] && profile.github?.login == "third")
        profile.removeAccount(forHost: "GITHUB.COM")
        #expect(profile.github == .init(host: "ghe.example.com", login: "a"))

        // A second GitHub account stays put when the first moves to a new host, and the moved one keeps its place.
        profile.setAccount(HostingAccount(kind: .github, host: "github.com", login: "octo"))
        profile.github = .init(host: "third.example.com", login: "b")
        #expect(profile.accounts.map(\.host) == ["third.example.com", "github.com"])
        #expect(profile.github == .init(host: "third.example.com", login: "b"))
        // Moving onto the host of another account replaces that account.
        profile.github = .init(host: "github.com", login: "c")
        #expect(profile.accounts.map(\.login) == ["c"])
    }
}
