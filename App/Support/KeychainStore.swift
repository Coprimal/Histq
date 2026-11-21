// Secrets in the Keychain: generic-password items of one service (`AppState.keychainService`), in the file-based
// login keychain (`kSecUseDataProtectionKeychain = false`). Debug and Release are both Developer ID-signed with the
// same identity, so an item one build writes is read by the other without an "Always Allow" prompt (user checklist
// U10.1 checks it). Accounts: `<kind>.<profileID>.<host>` (code host tokens, `github.…` for GitHub) with, for an
// OAuth sign-in that can be renewed, its `<kind>.<profileID>.<host>.oauth` record (refresh token and expiry), later
// `ai.<provider>`.
//
// The SecItem calls block (and may wait on a Keychain prompt), so callers run them off the main thread:
// `HostingTokens` does. Values are never logged or put in an error: only OSStatus codes and account names.
// DEBUG `-HistqKeychain memory` swaps in the in-memory twin, so QA shots never touch a real keychain.
import Foundation
import HistqCore
import Security
import os

/// One Keychain lookup. A failure (a denied prompt, a locked keychain) is never a miss.
enum KeychainRead: Equatable, Sendable {
    case found(Data)
    case notFound
    case failed(OSStatus)
}

/// A failed Keychain write or delete; only the status, never the value.
struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Where items live: the login keychain, or the in-memory twin of QA runs and the DEBUG self-test.
protocol KeychainBackend: Sendable {
    func read(service: String, account: String) -> KeychainRead
    /// Whether the item exists, without reading its data: `errSecSuccess`, `errSecItemNotFound`, or the failure.
    func contains(service: String, account: String) -> OSStatus
    /// Replaces the item's data, or adds the item when it does not exist.
    func upsert(service: String, account: String, data: Data) -> OSStatus
    /// Replaces the item's data; `errSecItemNotFound` when it does not exist (it is never added).
    func update(service: String, account: String, data: Data) -> OSStatus
    /// `errSecSuccess` also when there was no such item.
    func delete(service: String, account: String) -> OSStatus
}

/// SecItem calls on generic-password items of the file-based login keychain.
struct LoginKeychainBackend: KeychainBackend {
    private func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit false: without it a query may also match (or land in) the data protection keychain.
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    func read(service: String, account: String) -> KeychainRead {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecInternalError) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    func contains(service: String, account: String) -> OSStatus {
        // No kSecReturnData: the secret is never decrypted or copied into the process for an existence check.
        var query = query(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    func upsert(service: String, account: String, data: Data) -> OSStatus {
        let query = query(service: service, account: account)
        let status = update(service: service, account: account, data: data)
        guard status == errSecItemNotFound else { return status }
        var item = query
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        let query = query(service: service, account: account)
        return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func delete(service: String, account: String) -> OSStatus {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// The in-memory twin: items live as long as the process.
final class InMemoryKeychainBackend: KeychainBackend {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let items = OSAllocatedUnfairLock<[Key: Data]>(initialState: [:])

    func read(service: String, account: String) -> KeychainRead {
        items.withLock { $0[Key(service: service, account: account)] }.map { .found($0) } ?? .notFound
    }

    func contains(service: String, account: String) -> OSStatus {
        items.withLock { $0[Key(service: service, account: account)] != nil } ? errSecSuccess : errSecItemNotFound
    }

    func upsert(service: String, account: String, data: Data) -> OSStatus {
        items.withLock { $0[Key(service: service, account: account)] = data }
        return errSecSuccess
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        items.withLock { items in
            let key = Key(service: service, account: account)
            guard items[key] != nil else { return errSecItemNotFound }
            items[key] = data
            return errSecSuccess
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        items.withLock { $0[Key(service: service, account: account)] = nil }
        return errSecSuccess
    }
}

/// The app's secrets: string values by account in one service. Every call blocks; never call it on the main thread.
struct KeychainStore: Sendable {
    let service: String
    let backend: any KeychainBackend

    /// The app's store: `AppState.keychainService` (the `.qa` service in state-dir mode) in the login keychain, or the
    /// in-memory twin with DEBUG `-HistqKeychain memory`.
    static let shared = KeychainStore(
        service: AppState.keychainService,
        backend: AppState.launchFlag("-HistqKeychain") == "memory" ? InMemoryKeychainBackend() : LoginKeychainBackend())

    /// Whether this is the in-memory twin (DEBUG seams that fake a connected account require it).
    var isInMemory: Bool { backend is InMemoryKeychainBackend }

    /// The account of a profile's code host token: `<kind>.<profileID>.<host>`, the id uppercase as `profiles.json` has
    /// it (so `security find-generic-password -a` finds it with the id copied from there). GitHub's raw value is
    /// `github`, so its items keep the `github.<profileID>.<host>` name they always had; the host is used as is.
    static func hostingAccount(_ kind: HostingKind, profileID: UUID, host: String) -> String {
        "\(kind.rawValue).\(profileID.uuidString).\(host)"
    }

    /// The OAuth record next to the access token item `account` (`hostingAccount(_:profileID:host:)`): the refresh
    /// token and the access token's expiry as JSON (`OAuthKeychainStore`). Only an account signed in with OAuth has
    /// one.
    static func oauthAccount(_ account: String) -> String {
        account + ".oauth"
    }

    /// The value, nil when there is no item. Throws `KeychainError` when the read failed, or the item is not UTF-8.
    func string(account: String) throws -> String? {
        assertOffMain()
        switch backend.read(service: service, account: account) {
        case .found(let data):
            guard let value = String(data: data, encoding: .utf8) else { throw KeychainError(status: errSecDecode) }
            return value
        case .notFound:
            return nil
        case .failed(let status):
            throw KeychainError(status: status)
        }
    }

    /// Whether there is an item, its value unread. Throws `KeychainError` when the lookup failed.
    func contains(account: String) throws -> Bool {
        assertOffMain()
        switch backend.contains(service: service, account: account) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        case let status: throw KeychainError(status: status)
        }
    }

    func setString(_ value: String, account: String) throws {
        assertOffMain()
        let status = backend.upsert(service: service, account: account, data: Data(value.utf8))
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Replaces an existing item's value; throws `KeychainError` (`errSecItemNotFound` when there is no item, which is
    /// never added).
    func updateString(_ value: String, account: String) throws {
        assertOffMain()
        let status = backend.update(service: service, account: account, data: Data(value.utf8))
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Deletes the item; no error when there was none.
    func delete(account: String) throws {
        assertOffMain()
        let status = backend.delete(service: service, account: account)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// A Keychain call can wait on a prompt: on the main thread it would freeze the UI.
    private func assertOffMain() {
        assert(!Thread.isMainThread, "Keychain access on the main thread")
    }
}

/// The refresher's token pairs in the Keychain: the access token item `<kind>.<profileID>.<host>` (what git and the
/// API clients use) and its `.oauth` record. Always read uncached, since another Histq build may have rotated the pair.
/// A write saves the record first, so a torn write leaves the new refresh token (the old one may be used up), then the
/// access token, and puts it in `HostingTokens`' cache. Both are updates only: an item that is gone (a Disconnect while
/// the refresh ran) is never written again. Blocking SecItem calls, off the main thread (`@concurrent`).
struct OAuthKeychainStore: OAuthRefresher.Store {
    /// The `.oauth` item's JSON.
    private struct Record: Codable {
        var refreshToken: String?
        var expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }
    }

    /// The `.oauth` item's text for `refreshToken` and `expiresAt`.
    static func record(refreshToken: String?, expiresAt: Date?) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(Record(refreshToken: refreshToken, expiresAt: expiresAt))
        return String(decoding: data, as: UTF8.self)
    }

    /// Nil when either item is missing; a failed read or a record that is not ours throws.
    @concurrent
    func read(_ key: String) async throws -> OAuthRefresher.TokenPair? {
        let keychain = KeychainStore.shared
        guard let accessToken = try keychain.string(account: key),
              let text = try keychain.string(account: KeychainStore.oauthAccount(key))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(Record.self, from: Data(text.utf8))
        return OAuthRefresher.TokenPair(
            accessToken: accessToken, refreshToken: record.refreshToken,
            expiresAt: Self.debugExpiry(key) ?? record.expiresAt)
    }

    #if DEBUG
    /// The keys DEBUG `-HistqExpireHostingTokens YES` has already reported as expired.
    private static let expiredOnce = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    #endif

    /// DEBUG `-HistqExpireHostingTokens YES` (state-dir launches only): the first read of each OAuth account's pair
    /// in this process says it expired, so the refresher renews it once (QA of a refresh shared by several tabs);
    /// later reads, and every other build, give the stored expiry (nil).
    private static func debugExpiry(_ key: String) -> Date? {
        #if DEBUG
        guard AppState.isStateDirMode, AppState.launchFlag("-HistqExpireHostingTokens") == "YES",
              expiredOnce.withLock({ $0.insert(key).inserted })
        else { return nil }
        return .distantPast
        #else
        return nil
        #endif
    }

    @concurrent
    func write(_ pair: OAuthRefresher.TokenPair, for key: String) async throws {
        let keychain = KeychainStore.shared
        let record = try Self.record(refreshToken: pair.refreshToken, expiresAt: pair.expiresAt)
        try keychain.updateString(record, account: KeychainStore.oauthAccount(key))
        try keychain.updateString(pair.accessToken, account: key)
        HostingTokens.cache.withLock { $0[key] = .some(pair.accessToken) }
    }
}

/// The profiles' code host tokens, read from `KeychainStore.shared` off the main thread and cached for the process by
/// account, so a write or fetch reads the Keychain once per profile, kind and host. Settings › Integrations saves and
/// deletes through here, which updates the cache, so the next git command sees the change. A failed read is never
/// cached (the next use tries again). An account with an `.oauth` record (an OAuth sign-in with a refresh token or an
/// expiry) gets its access token through the app's one `refresher`, which renews it before it expires and after a
/// 401; any other token is handed out as it is.
enum HostingTokens {
    private static let logger = Logger(subsystem: "com.math2it.histq", category: "keychain")
    /// Account to token; nil = known to have no item.
    fileprivate static let cache = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])
    /// Account to whether it has an `.oauth` record; a failed lookup is not kept.
    private static let oauthRecords = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
    /// The account behind each refresher key, for its token request (host, base path, client ID).
    private static let oauthAccounts = OSAllocatedUnfairLock<[String: HostingAccount]>(initialState: [:])

    /// The refresher of every OAuth account, keyed by the access token's Keychain account.
    static let refresher = OAuthRefresher(store: OAuthKeychainStore()) { key, refreshToken in
        try await renew(key, refreshToken)
    }

    /// Histq's GitLab OAuth application ID (`HistqGitLabClientID`, gitlab.com); nil when the build has none.
    private static let gitLabClientID: String? = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "HistqGitLabClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded `$(…)` would mean the build setting is missing, not a client ID.
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }()

    /// The token request of the refresher key `key`. The account's own OAuth application (`oauthClientID`, the one its
    /// token came from) comes first, else Histq's. Without a client ID, for an account this process never handed out
    /// or for GitHub (whose OAuth App tokens never expire), the grant cannot be renewed: a rejection, so the account
    /// shows "reconnect".
    @concurrent
    private static func renew(_ key: String, _ refreshToken: String) async throws -> DeviceFlow.Token {
        let ownID = { (id: String) in id.trimmingCharacters(in: .whitespaces).isEmpty ? nil : id }
        guard let account = oauthAccounts.withLock({ $0[key] }), account.kind == .gitlab,
              let clientID = account.oauthClientID.flatMap(ownID) ?? gitLabClientID
        else { throw HostingError.unauthorized }
        let flow = try DeviceFlow(kind: .gitlab, host: account.host, basePath: account.basePath, clientID: clientID)
        UITiming.hosting("refresh \(account.host) start")
        do {
            let token = try await flow.refresh(refreshToken)
            UITiming.hosting("refresh \(account.host) ok")
            return token
        } catch {
            UITiming.hosting("refresh \(account.host) failed \(logReason(error))")
            throw error
        }
    }

    /// Whether the access token item `key` has an `.oauth` record; throws `KeychainError` when the lookup failed.
    private static func hasOAuthRecord(_ key: String) throws -> Bool {
        if let known = oauthRecords.withLock({ $0[key] }) { return known }
        let found = try KeychainStore.shared.contains(account: KeychainStore.oauthAccount(key))
        oauthRecords.withLock { $0[key] = found }
        return found
    }

    /// The access token of `account` of `profileID` for an API client or git: through the refresher for an OAuth
    /// account, else the item as `read` gives it. `rejecting` is the token a 401 just refused (then a plain token is
    /// read again, uncached). Nil when a plain token is missing; throws `KeychainError` or
    /// `OAuthRefresher.RefresherError` (`reconnectNeeded`: the sign-in cannot be renewed).
    @concurrent
    static func accessToken(
        for account: HostingAccount, profileID: UUID, rejecting: String? = nil
    ) async throws -> String? {
        let key = KeychainStore.hostingAccount(account.kind, profileID: profileID, host: account.host)
        guard try hasOAuthRecord(key) else {
            return try await read(
                profileID: profileID, kind: account.kind, host: account.host, refresh: rejecting != nil)
        }
        oauthAccounts.withLock { $0[key] = account }
        return try await refresher.token(for: key, rejecting: rejecting)
    }

    /// Whether `account`'s OAuth sign-in can no longer be renewed (the refresher says reconnect). False for a plain
    /// token, and for any other failure (offline), which says nothing about the sign-in.
    @concurrent
    static func isSignInExpired(_ account: HostingAccount, profileID: UUID) async -> Bool {
        do {
            _ = try await accessToken(for: account, profileID: profileID)
            return false
        } catch OAuthRefresher.RefresherError.reconnectNeeded {
            return true
        } catch {
            return false
        }
    }

    /// The `kind` token of `profileID` for `host`, nil when there is none or the read failed (logged, status only).
    /// With `refresh`, reads the Keychain even when cached (the Integrations page, so an item deleted outside Histq
    /// shows).
    @concurrent
    static func token(
        profileID: UUID, kind: HostingKind = .github, host: String, refresh: Bool = false
    ) async -> String? {
        try? await read(profileID: profileID, kind: kind, host: host, refresh: refresh)
    }

    /// The token of `account` of `profileID`, for the API client. Git gets `credentials(for:)`.
    @concurrent
    static func token(for account: HostingAccount, profileID: UUID) async -> String? {
        await token(profileID: profileID, kind: account.kind, host: account.host)
    }

    /// What git gets for `profile` (`GitInvocation`, which trusts the set): one credential per account of the profile
    /// itself that has a token, for the account's host (an OAuth one renewed first when it is about to expire; one that
    /// cannot be had is left out, logged); empty without a profile. The username is the account's
    /// `gitUsername`, else `x-access-token` for GitHub and `oauth2` for GitLab (any name works with a personal access
    /// token; OAuth tokens need `oauth2`).
    @concurrent
    static func credentials(for profile: Profile?) async -> [GitCredential] {
        guard let profile else { return [] }
        var credentials: [GitCredential] = []
        for account in profile.accounts {
            let token: String?
            do {
                token = try await accessToken(for: account, profileID: profile.id)
            } catch {
                let reason = logReason(error)
                logger.error("no token of \(account.host, privacy: .public) for git: \(reason, privacy: .public)")
                token = nil
            }
            guard let token else { continue }
            let kindUsername = switch account.kind {
            case .github: "x-access-token"
            case .gitlab: "oauth2"
            case .bitbucketCloud: "x-token-auth"
            }
            let username = account.gitUsername ?? kindUsername
            credentials.append(GitCredential(kind: account.kind, host: account.host, username: username, token: token))
        }
        return credentials
    }

    /// What a log says of a failure to get a token: the error's case and an HTTP status, never a server's text.
    private static func logReason(_ error: any Error) -> String {
        switch error {
        case OAuthRefresher.RefresherError.reconnectNeeded: "reconnect needed"
        case OAuthRefresher.RefresherError.storeFailed: "Keychain read or save failed"
        case OAuthRefresher.RefresherError.refreshFailed(let cause): "refresh failed (\(logReason(cause)))"
        case HostingError.http(let status, _): "HTTP \(status)"
        case let error as KeychainError: error.description
        default: String(describing: type(of: error))
        }
    }

    /// As `token(profileID:kind:host:refresh:)`, but a failed read throws instead of reading as no token.
    @concurrent
    static func read(
        profileID: UUID, kind: HostingKind = .github, host: String, refresh: Bool = false
    ) async throws -> String? {
        let account = KeychainStore.hostingAccount(kind, profileID: profileID, host: host)
        if !refresh, let cached = cache.withLock({ $0[account] }) { return cached }
        do {
            let token = try KeychainStore.shared.string(account: account)
            cache.withLock { $0[account] = .some(token) }
            return token
        } catch {
            logger.error("read of \(account, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Saves a connection's token; with a `refreshToken` or an `expiresIn` (seconds, an OAuth sign-in) also its
    /// `.oauth` record, else deletes an earlier sign-in's record. The record goes first, so a failed save never leaves
    /// the new token next to the earlier sign-in's record. The refresher forgets the account before (a refresh in
    /// flight saves nothing over the new items) and after.
    @concurrent
    static func save(
        _ token: String, refreshToken: String? = nil, expiresIn: Int? = nil, profileID: UUID,
        kind: HostingKind = .github, host: String
    ) async throws {
        let account = KeychainStore.hostingAccount(kind, profileID: profileID, host: host)
        let oauth = KeychainStore.oauthAccount(account)
        let isOAuth = refreshToken != nil || expiresIn != nil
        oauthRecords.withLock { $0[account] = nil }
        await refresher.forget(account)
        if isOAuth {
            let expiresAt = expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0)) }
            try KeychainStore.shared.setString(
                try OAuthKeychainStore.record(refreshToken: refreshToken, expiresAt: expiresAt), account: oauth)
        } else {
            try KeychainStore.shared.delete(account: oauth)
        }
        try KeychainStore.shared.setString(token, account: account)
        cache.withLock { $0[account] = .some(token) }
        oauthRecords.withLock { $0[account] = isOAuth }
        await refresher.forget(account)
    }

    /// Deletes the account's token item and its `.oauth` record (both are tried), and the refresher forgets it.
    @concurrent
    static func delete(profileID: UUID, kind: HostingKind = .github, host: String) async throws {
        let account = KeychainStore.hostingAccount(kind, profileID: profileID, host: host)
        // Forgotten first: even if the delete fails, git stops getting the token the user asked to remove.
        cache.withLock { $0[account] = .some(nil) }
        oauthRecords.withLock { $0[account] = false }
        await refresher.forget(account)
        var failure: (any Error)?
        for item in [account, KeychainStore.oauthAccount(account)] {
            do {
                try KeychainStore.shared.delete(account: item)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }
}

#if DEBUG
/// DEBUG `-HistqKeychainSelfTest memory|login`: a save, read, exists, overwrite and delete round trip against the
/// in-memory twin and, with `login` in state-dir mode, the login keychain under the QA service with a throwaway
/// account that is deleted again. Off the main thread; the outcome (status lines only, never a value) goes to
/// `keychain-selftest.txt` in the state folder. The app has no test target: this checks the real signed app's access.
enum KeychainSelfTest {
    static func runIfAsked() {
        guard let mode = AppState.launchFlag("-HistqKeychainSelfTest") else { return }
        Task.detached(priority: .utility) {
            var lines = ["memory: \(roundTrip(KeychainStore(service: "com.math2it.histq.qa", backend: InMemoryKeychainBackend())))"]
            if mode == "login" {
                // Never the real service: only a state-dir launch has the QA one.
                lines.append(AppState.isStateDirMode
                    ? "login: \(roundTrip(KeychainStore(service: AppState.keychainService, backend: LoginKeychainBackend())))"
                    : "login: skipped (no state dir)")
            }
            if KeychainStore.shared.isInMemory { lines.append("disconnect: \(await disconnectCheck())") }
            let file = StatePaths.root.appending(path: "keychain-selftest.txt", directoryHint: .notDirectory)
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// With `-HistqKeychain memory` only: a fake OAuth sign-in of a throwaway GitLab account saved through
    /// `HostingTokens` has both items and is handed out by the refresher; the refresher's store writes a renewed pair
    /// that reads back (and git's token follows it); a pasted token saved over it drops the `.oauth` record;
    /// Disconnect (`HostingTokens.delete`) of a fake OAuth sign-in leaves neither item, and a renewed pair written
    /// after it does not bring them back. "ok", or the first step that failed (never a value).
    private static func disconnectCheck() async -> String {
        let profileID = UUID()
        let host = "gitlab.selftest.invalid"
        let account = HostingAccount(kind: .gitlab, host: host, login: "selftest")
        let token = KeychainStore.hostingAccount(.gitlab, profileID: profileID, host: host)
        let oauth = KeychainStore.oauthAccount(token)
        let keychain = KeychainStore.shared
        func saveOAuth() async throws {
            try await HostingTokens.save(
                "histq_qa_fake_token", refreshToken: "histq_qa_fake_refresh", expiresIn: 7200, profileID: profileID,
                kind: .gitlab, host: host)
        }
        do {
            try await saveOAuth()
            guard try keychain.contains(account: token), try keychain.contains(account: oauth) else {
                return "fail: an item is missing after an OAuth save"
            }
            let handedOut = try await HostingTokens.accessToken(for: account, profileID: profileID)
            guard handedOut == "histq_qa_fake_token" else { return "fail: the refresher handed out another token" }
            let store = OAuthKeychainStore()
            let renewed = OAuthRefresher.TokenPair(
                accessToken: "histq_qa_fake_renewed", refreshToken: "histq_qa_fake_refresh_2",
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
            try await store.write(renewed, for: token)
            guard try await store.read(token) == renewed else { return "fail: a renewed pair did not read back" }
            let forGit = try await HostingTokens.read(profileID: profileID, kind: .gitlab, host: host)
            guard forGit == "histq_qa_fake_renewed" else { return "fail: the cache kept the old token" }
            try await HostingTokens.save("histq_qa_fake_pat", profileID: profileID, kind: .gitlab, host: host)
            guard try !keychain.contains(account: oauth) else { return "fail: .oauth left after a pasted token" }
            try await saveOAuth()
            try await HostingTokens.delete(profileID: profileID, kind: .gitlab, host: host)
            let tokenLeft = try keychain.contains(account: token)
            let oauthLeft = try keychain.contains(account: oauth)
            guard !tokenLeft, !oauthLeft else {
                return "fail: after Disconnect the token item is \(tokenLeft ? "left" : "gone"), the .oauth item "
                    + (oauthLeft ? "left" : "gone")
            }
            let resurrected = (try? await store.write(renewed, for: token)) != nil
            guard !resurrected, try !keychain.contains(account: token), try !keychain.contains(account: oauth) else {
                return "fail: a renewed pair written after Disconnect brought the account back"
            }
            return "ok (renewed pair saved; after Disconnect neither the token item nor the .oauth item remains, and "
                + "a late renewal does not bring them back)"
        } catch {
            try? await HostingTokens.delete(profileID: profileID, kind: .gitlab, host: host)
            return "fail: \(error)"
        }
    }

    /// "ok", or the first step that failed.
    private static func roundTrip(_ store: KeychainStore) -> String {
        let account = "selftest.\(UUID().uuidString.lowercased())"
        let first = UUID().uuidString
        let second = UUID().uuidString
        do {
            guard try store.string(account: account) == nil else { return "fail: item existed before" }
            guard try !store.contains(account: account) else { return "fail: contains before save" }
            try store.setString(first, account: account)
            guard try store.contains(account: account) else { return "fail: contains after save" }
            guard try store.string(account: account) == first else { return "fail: read after save" }
            try store.setString(second, account: account)
            guard try store.string(account: account) == second else { return "fail: read after overwrite" }
            try store.delete(account: account)
            guard try store.string(account: account) == nil else { return "fail: item left after delete" }
            guard try !store.contains(account: account) else { return "fail: contains after delete" }
            try store.delete(account: account)
            return "ok (\(account))"
        } catch {
            try? store.delete(account: account)
            return "fail: \(error)"
        }
    }
}
#endif
