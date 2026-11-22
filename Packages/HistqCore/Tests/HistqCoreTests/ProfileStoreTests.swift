// Key-feature tests for ProfileStore (task 7.1), in a temp folder (never the app's Application Support): a
// remembered repo resolves to its profile after a save and reload, under another spelling of its path; an
// unknown repo gets the default; a repo whose profile was deleted falls back to the default. Importing a
// workspace's profiles (workspaces plan, phase 1) only adds unknown ids and never changes local settings.
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
}
