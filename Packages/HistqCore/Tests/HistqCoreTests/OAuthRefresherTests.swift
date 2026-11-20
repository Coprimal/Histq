// Tests of the single-flight OAuth refresher with an in-memory store and a fake token request: no test reaches the
// network or the Keychain. Rotating refresh tokens are single-use, so these guard that one refresh runs per account,
// that the new pair is saved before anyone gets its access token, and that a rejected or used-up pair is never sent
// again. Token checks are bound to a Bool first, so a failure never prints a token.
import Foundation
import HistqCore
import Synchronization
import Testing

struct OAuthRefresherTests {
    typealias Pair = OAuthRefresher.TokenPair

    static let key = "gitlab.profile.gitlab.com"
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    /// Made-up tokens. `expired` is still valid for 30 s, inside the refresh margin.
    static let expired = Pair(accessToken: "fake-access-old", refreshToken: "fake-refresh-old",
                              expiresAt: now.addingTimeInterval(30))
    static let fresh = Pair(accessToken: "fake-access-new", refreshToken: "fake-refresh-new",
                            expiresAt: now.addingTimeInterval(7200))

    /// The account store: suspends on every call (so concurrent callers really interleave) and logs saves.
    final class Store: OAuthRefresher.Store {
        let pairs = Mutex<[String: Pair]>([:])
        let log = Mutex<[String]>([])
        let failWrites = Mutex(false)

        init(_ pair: Pair?) { pairs.withLock { $0[OAuthRefresherTests.key] = pair } }

        var pair: Pair? { pairs.withLock { $0[OAuthRefresherTests.key] } }
        func set(_ pair: Pair) { pairs.withLock { $0[OAuthRefresherTests.key] = pair } }

        func read(_ key: String) async throws -> Pair? {
            await Task.yield()
            return pairs.withLock { $0[key] }
        }

        func write(_ pair: Pair, for key: String) async throws {
            await Task.yield()
            if failWrites.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
            pairs.withLock { $0[key] = pair }
            log.withLock { $0.append("save") }
        }
    }

    /// The token request: records the refresh tokens it was sent and answers with `answer`.
    final class Endpoint: Sendable {
        let sent = Mutex<[String]>([])
        let answer: @Sendable (_ refreshToken: String, _ call: Int) throws -> DeviceFlow.Token

        init(answer: @escaping @Sendable (_ refreshToken: String, _ call: Int) throws -> DeviceFlow.Token = { _, call in
            DeviceFlow.Token(accessToken: "fake-access-\(call)", refreshToken: "fake-refresh-\(call)", expiresIn: 7200)
        }) {
            self.answer = answer
        }

        var count: Int { sent.withLock { $0.count } }

        func refresh(_ refreshToken: String) async throws -> DeviceFlow.Token {
            let call = sent.withLock { sent in
                sent.append(refreshToken)
                return sent.count
            }
            for _ in 0..<5 { await Task.yield() }
            return try answer(refreshToken, call)
        }
    }

    static func refresher(_ store: Store, _ endpoint: Endpoint) -> OAuthRefresher {
        OAuthRefresher(store: store, refresh: { try await endpoint.refresh($1) }, now: { Self.now })
    }

    static func isReconnect(_ error: any Error) -> Bool {
        if case .reconnectNeeded = error as? OAuthRefresher.RefresherError { true } else { false }
    }

    /// The error `token(for:rejecting:)` throws, or nil when it hands out a token.
    static func failure(_ refresher: OAuthRefresher, rejecting: String? = nil) async -> (any Error)? {
        do {
            _ = try await refresher.token(for: key, rejecting: rejecting)
            return nil
        } catch {
            return error
        }
    }

    @Test("concurrent callers of an expired token share one refresh, saved before anyone gets the new token")
    func singleFlight() async throws {
        let store = Store(Self.expired)
        let endpoint = Endpoint()
        let refresher = Self.refresher(store, endpoint)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let token = try await refresher.token(for: Self.key)
                    store.log.withLock { $0.append("return") }
                    return token
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(endpoint.count == 1)
        let sentOld = endpoint.sent.withLock { $0 } == ["fake-refresh-old"]
        #expect(sentOld)
        let allNew = tokens.count == 20 && tokens.allSatisfy { $0 == "fake-access-1" }
        #expect(allNew)
        let storedRotated = store.pair?.refreshToken == "fake-refresh-1" && store.pair?.accessToken == "fake-access-1"
        #expect(storedRotated)
        #expect(store.pair?.expiresAt == Self.now.addingTimeInterval(7200))
        let log = store.log.withLock { $0 }
        #expect(log.first == "save")
        #expect(log.filter { $0 == "save" }.count == 1)

        // The new token is fresh: later calls get it without a request.
        let again = try await refresher.token(for: Self.key) == "fake-access-1"
        #expect(again)
        #expect(endpoint.count == 1)
    }

    @Test("a 400 or 401 from the token endpoint needs a reconnect, makes no more requests, and clears with a new pair",
          arguments: [HostingError.http(status: 400, message: "invalid_grant"), .unauthorized])
    func rejected(_ rejection: HostingError) async throws {
        let store = Store(Self.expired)
        let endpoint = Endpoint { _, _ in throw rejection }
        let refresher = Self.refresher(store, endpoint)

        #expect(await Self.failure(refresher).map(Self.isReconnect) == true)
        #expect(endpoint.count == 1)
        #expect(await Self.failure(refresher).map(Self.isReconnect) == true)
        #expect(await Self.failure(refresher, rejecting: "fake-access-old").map(Self.isReconnect) == true)
        #expect(endpoint.count == 1)
        let kept = store.pair == Self.expired
        #expect(kept)

        // A reconnect saves a new pair: the mark clears.
        store.set(Self.fresh)
        let works = try await refresher.token(for: Self.key) == "fake-access-new"
        #expect(works)
        #expect(endpoint.count == 1)
    }

    @Test("a pair another process already rotated is used without a token request")
    func rotatedElsewhere() async throws {
        let store = Store(Self.fresh)
        let endpoint = Endpoint()
        let refresher = Self.refresher(store, endpoint)
        _ = try await refresher.token(for: Self.key)

        // The token just handed out got a 401, and another process saved a newer pair meanwhile.
        let newer = Pair(accessToken: "fake-access-other", refreshToken: "fake-refresh-other",
                         expiresAt: Self.now.addingTimeInterval(3600))
        store.set(newer)
        let usesNewer = try await refresher.token(for: Self.key, rejecting: "fake-access-new") == "fake-access-other"
        #expect(usesNewer)
        #expect(endpoint.count == 0)

        // Without a newer pair, the forced call refreshes with the stored refresh token.
        let refreshed = try await refresher.token(for: Self.key, rejecting: "fake-access-other") == "fake-access-1"
        #expect(refreshed)
        let sentOther = endpoint.sent.withLock { $0 } == ["fake-refresh-other"]
        #expect(sentOther)
    }

    @Test("a rejected refresh retries once with a newer refresh token found in the store")
    func retryWithNewerRefreshToken() async throws {
        let store = Store(Self.expired)
        let newer = Pair(accessToken: "fake-access-other", refreshToken: "fake-refresh-other",
                         expiresAt: Self.now.addingTimeInterval(-5))
        let endpoint = Endpoint { refreshToken, call in
            guard refreshToken == "fake-refresh-other" else {
                // Another process rotated the pair while this request was on its way.
                store.set(newer)
                throw HostingError.http(status: 400, message: "invalid_grant")
            }
            return DeviceFlow.Token(accessToken: "fake-access-\(call)", refreshToken: "fake-refresh-\(call)", expiresIn: 600)
        }
        let refresher = Self.refresher(store, endpoint)

        let token = try await refresher.token(for: Self.key) == "fake-access-2"
        #expect(token)
        let sent = endpoint.sent.withLock { $0 } == ["fake-refresh-old", "fake-refresh-other"]
        #expect(sent)
        let stored = store.pair?.refreshToken == "fake-refresh-2"
        #expect(stored)

        // When the newer pair's access token is still valid, it is used as is: no second rotation.
        let freshStore = Store(Self.expired)
        let freshEndpoint = Endpoint { _, _ in
            freshStore.set(Self.fresh)
            throw HostingError.http(status: 400, message: "invalid_grant")
        }
        let usesNewer = try await Self.refresher(freshStore, freshEndpoint).token(for: Self.key) == "fake-access-new"
        #expect(usesNewer)
        #expect(freshEndpoint.count == 1)
        let kept = freshStore.pair == Self.fresh
        #expect(kept)
    }

    @Test("forget during a refresh: nothing is saved or handed out, and a new sign-in is kept")
    func forgetDuringRefresh() async throws {
        let store = Store(Self.expired)
        let sent = Mutex(0)
        let (forgotten, signal) = AsyncStream.makeStream(of: Void.self)
        let refresher = OAuthRefresher(store: store, refresh: { _, _ in
            sent.withLock { $0 += 1 }
            for await _ in forgotten { break }
            return DeviceFlow.Token(accessToken: "fake-access-1", refreshToken: "fake-refresh-1", expiresIn: 7200)
        }, now: { Self.now })

        let caller = Task { await Self.failure(refresher) }
        while sent.withLock({ $0 }) == 0 { await Task.yield() }
        // A reconnect saves a new pair and forgets the account while the old grant's request is on its way.
        store.set(Self.fresh)
        await refresher.forget(Self.key)
        signal.yield()
        signal.finish()

        let cancelled = await caller.value is CancellationError
        #expect(cancelled)
        let kept = store.pair == Self.fresh
        #expect(kept)
        #expect(store.log.withLock { $0 }.isEmpty)
        let usesNewSignIn = try await refresher.token(for: Self.key) == "fake-access-new"
        #expect(usesNewSignIn)
        #expect(sent.withLock { $0 } == 1)
    }

    @Test("a network failure keeps the pair, and a later call refreshes again")
    func networkFailure() async throws {
        let store = Store(Self.expired)
        let endpoint = Endpoint { _, call in
            if call == 1 { throw HostingError.transport("URL error -1009") }
            return DeviceFlow.Token(accessToken: "fake-access-\(call)", refreshToken: "fake-refresh-\(call)", expiresIn: 600)
        }
        let refresher = Self.refresher(store, endpoint)

        let error = await Self.failure(refresher)
        let isRefreshFailed = if case .refreshFailed = error as? OAuthRefresher.RefresherError { true } else { false }
        #expect(isRefreshFailed)
        let kept = store.pair == Self.expired
        #expect(kept)

        let token = try await refresher.token(for: Self.key) == "fake-access-2"
        #expect(token)
        let sent = endpoint.sent.withLock { $0 } == ["fake-refresh-old", "fake-refresh-old"]
        #expect(sent)
    }

    @Test("without a refresh token: an expired or refused token needs a reconnect, a valid one is handed out")
    func noRefreshToken() async throws {
        let endpoint = Endpoint()
        let expired = Self.refresher(Store(Pair(accessToken: "fake-access-old", expiresAt: Self.now)), endpoint)
        #expect(await Self.failure(expired).map(Self.isReconnect) == true)

        let valid = Self.refresher(Store(Pair(accessToken: "fake-access-pat")), endpoint)
        let handedOut = try await valid.token(for: Self.key) == "fake-access-pat"
        #expect(handedOut)
        #expect(await Self.failure(valid, rejecting: "fake-access-pat").map(Self.isReconnect) == true)

        #expect(await Self.failure(Self.refresher(Store(nil), endpoint)).map(Self.isReconnect) == true)
        #expect(endpoint.count == 0)
    }

    @Test("a straggler refused an access token already replaced gets the current one without a token request")
    func stragglerRejection() async throws {
        let store = Store(Self.fresh)
        let endpoint = Endpoint()
        let refresher = Self.refresher(store, endpoint)
        _ = try await refresher.token(for: Self.key)

        // Two requests got a 401 for the same token: the first refreshes, the second gets the new token as it is.
        let first = try await refresher.token(for: Self.key, rejecting: "fake-access-new") == "fake-access-1"
        #expect(first)
        let second = try await refresher.token(for: Self.key, rejecting: "fake-access-new") == "fake-access-1"
        #expect(second)
        #expect(endpoint.count == 1)

        // So does another process's refresher, which never handed out that token: the store already has a newer one.
        let other = Self.refresher(store, endpoint)
        let fromStore = try await other.token(for: Self.key, rejecting: "fake-access-new") == "fake-access-1"
        #expect(fromStore)
        #expect(endpoint.count == 1)
    }

    @Test("a refresh answer without a refresh token keeps the old one")
    func keepsRefreshToken() async throws {
        let store = Store(Self.expired)
        let endpoint = Endpoint { _, call in DeviceFlow.Token(accessToken: "fake-access-\(call)", expiresIn: 600) }
        let refresher = Self.refresher(store, endpoint)

        let token = try await refresher.token(for: Self.key) == "fake-access-1"
        #expect(token)
        let stored = store.pair == Pair(accessToken: "fake-access-1", refreshToken: "fake-refresh-old",
                                        expiresAt: Self.now.addingTimeInterval(600))
        #expect(stored)
    }

    @Test("a failed save hands out no token, and the used-up refresh token is never sent again")
    func saveFailure() async throws {
        let store = Store(Self.expired)
        store.failWrites.withLock { $0 = true }
        let endpoint = Endpoint()
        let refresher = Self.refresher(store, endpoint)

        let error = await Self.failure(refresher)
        let isStoreFailed = if case .storeFailed = error as? OAuthRefresher.RefresherError { true } else { false }
        #expect(isStoreFailed)
        #expect(endpoint.count == 1)

        store.failWrites.withLock { $0 = false }
        #expect(await Self.failure(refresher).map(Self.isReconnect) == true)
        #expect(endpoint.count == 1)
    }

    @Test("a token pair's descriptions never show its tokens")
    func redacted() {
        let pair = Self.fresh
        for text in [String(describing: pair), String(reflecting: pair), { var out = ""; dump(pair, to: &out); return out }()] {
            let leaks = text.contains("fake-access") || text.contains("fake-refresh")
            #expect(!leaks)
        }
    }
}
