// Hands out OAuth access tokens and refreshes them, one refresh at a time per account. Rotating refresh tokens
// (GitLab, Bitbucket, Microsoft Entra) are single-use: two refreshes with the same refresh token, or a rotated pair
// that never got saved, lose the account. So:
// - concurrent callers of one account await the same refresh (exactly one token request);
// - the new pair is written through the store before any caller gets the new access token, and a failed write hands
//   out nothing;
// - right before a token request the stored pair is read again (uncached, it may be shared with other processes), and
//   a pair another process already rotated is used as is;
// - a rejected refresh reads the store once more: a usable pair saved meanwhile is used as is, else it retries once with
//   a newer refresh token, else marks the account "reconnect needed": no request is made for that pair again, and the
//   mark clears when the store holds another pair;
// - `forget` (Disconnect, a new sign-in) stops a renewal in flight: it sends no request, saves nothing and hands out
//   nothing after that, so the old grant never brings back or overwrites the account.
// No error or description holds a token.
import Foundation

public actor OAuthRefresher {
    /// An account's tokens as the store keeps them. Its descriptions never show the tokens.
    public struct TokenPair: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable
    {
        public var accessToken: String
        public var refreshToken: String?
        /// When the access token expires; nil when the host did not say.
        public var expiresAt: Date?

        public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }

        public var description: String {
            let expiry = expiresAt.map { "\($0)" } ?? "none"
            return "OAuthRefresher.TokenPair(refresh: \(refreshToken == nil ? "none" : "set"), expiresAt: \(expiry))"
        }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt as Any]) }
    }

    /// Where the pairs live (the app's Keychain). `read` must not answer from a per-process cache: another process
    /// may have rotated the pair.
    public protocol Store: Sendable {
        func read(_ key: String) async throws -> TokenPair?
        func write(_ pair: TokenPair, for key: String) async throws
    }

    /// The host's token request of the account `key` with a refresh token. It throws `HostingError.unauthorized`
    /// (401) or `HostingError.http(status: 400, _)` when the token endpoint rejects the grant (`invalid_grant`), which
    /// is what `HostingHTTP.error(for:data:)` makes of those answers; any other error counts as transient.
    public typealias Refresh = @Sendable (_ key: String, _ refreshToken: String) async throws -> DeviceFlow.Token

    public enum RefresherError: LocalizedError, Sendable, CustomStringConvertible {
        /// The account must be connected again: no pair, no refresh token for an expired or refused access token, or
        /// the host rejected the refresh token.
        case reconnectNeeded
        /// The token request failed without a rejection (offline, timeout, 5xx); the stored pair is kept.
        case refreshFailed(any Error)
        /// The store could not be read, or the refreshed pair could not be saved (then no token was handed out, and a
        /// rotated refresh token is treated as used up).
        case storeFailed

        public var description: String {
            switch self {
            case .reconnectNeeded: "The account's sign-in expired. Connect the account again."
            case .refreshFailed(let error): "The sign-in could not be renewed: \(error)"
            case .storeFailed: "The account's sign-in could not be read or saved in the Keychain."
            }
        }

        public var errorDescription: String? { description }
    }

    /// An access token expiring sooner than this is refreshed first.
    public static let expiryMargin: TimeInterval = 60

    private let store: any Store
    private let refresh: Refresh
    private let now: @Sendable () -> Date
    /// The pair each account last handed out.
    private var last: [String: TokenPair] = [:]
    /// The refresh running for each account.
    private var inFlight: [String: Task<String, any Error>] = [:]
    /// The stored pair of each account that needs a reconnect.
    private var marked: [String: TokenPair] = [:]
    /// Bumped by `forget`: a renewal that began before it stops at its next step.
    private var generations: [String: Int] = [:]

    public init(store: any Store, refresh: @escaping Refresh, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.refresh = refresh
        self.now = now
    }

    /// The access token of the account `key`. `rejecting` is the caller's one retry after a 401: the access token the
    /// host refused, which is never handed out again. A refresh runs only while that token is still the current one:
    /// when another caller or process already replaced it, the current token comes back without a request. Throws
    /// `RefresherError`, or `CancellationError` when `forget(_:)` ran during the renewal.
    public func token(for key: String, rejecting: String? = nil) async throws -> String {
        // A refresh that hands back the refused token itself (it read that token as fresh) is not this caller's: it
        // starts its own, once, which later callers with the same refused token join.
        var joined: Task<String, any Error>?
        while let task = inFlight[key], task != joined {
            joined = task
            let token = try await task.value
            if token != rejecting { return token }
        }
        if marked[key] == nil, let pair = last[key], isFresh(pair), pair.accessToken != rejecting {
            return pair.accessToken
        }
        // Unstructured, so a cancelled caller never stops a refresh between the token request and the save.
        let task = Task { try await self.renew(key, rejecting: rejecting) }
        inFlight[key] = task
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        return try await task.value
    }

    /// Drops what the refresher keeps of the account `key` (its last pair and a reconnect mark) and stops its renewal
    /// in flight: on Disconnect, and around saving a new sign-in.
    public func forget(_ key: String) {
        last[key] = nil
        marked[key] = nil
        inFlight[key] = nil
        generations[key, default: 0] += 1
    }

    private func renew(_ key: String, rejecting: String?) async throws -> String {
        let generation = generations[key, default: 0]
        let stored = try await read(key, generation)
        if let mark = marked[key] {
            guard stored != mark else { throw RefresherError.reconnectNeeded }
            marked[key] = nil
        }
        if isFresh(stored), stored.accessToken != rejecting {
            last[key] = stored
            return stored.accessToken
        }
        guard let refreshToken = stored.refreshToken else { throw RefresherError.reconnectNeeded }
        do {
            return try await refreshAndSave(key, generation, from: stored, with: refreshToken)
        } catch let error where Self.isRejection(error) {
            let again = try await read(key, generation)
            // Another process rotated the pair: its access token is used, not spent on one more rotation.
            if isFresh(again), again.accessToken != rejecting {
                last[key] = again
                return again.accessToken
            }
            if let newer = again.refreshToken, newer != refreshToken {
                do {
                    return try await refreshAndSave(key, generation, from: again, with: newer)
                } catch let error where Self.isRejection(error) {
                    try reject(key, try await read(key, generation), sent: newer)
                }
            }
            try reject(key, again, sent: refreshToken)
        }
    }

    /// Requests a new pair with `refreshToken` (the one of the stored pair `stored`) and saves it before returning its
    /// access token. Nothing is sent, saved or handed out once `forget` ran since `generation`.
    private func refreshAndSave(
        _ key: String, _ generation: Int, from stored: TokenPair, with refreshToken: String
    ) async throws -> String {
        try check(key, generation)
        let token: DeviceFlow.Token
        do {
            token = try await refresh(key, refreshToken)
        } catch let error where Self.isRejection(error) {
            throw error
        } catch {
            throw RefresherError.refreshFailed(error)
        }
        // A Disconnect or a new sign-in while the request ran: the old grant's pair is dropped.
        try check(key, generation)
        // RFC 6749 section 6: without a new refresh token the old one stays valid.
        let pair = TokenPair(
            accessToken: token.accessToken, refreshToken: token.refreshToken ?? refreshToken,
            expiresAt: token.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) })
        do {
            try await store.write(pair, for: key)
        } catch {
            try check(key, generation)
            last[key] = nil
            // A rotated refresh token is used up and its successor is lost: never send the stored one again.
            if token.refreshToken.map({ $0 != refreshToken }) == true { marked[key] = stored }
            throw RefresherError.storeFailed
        }
        try check(key, generation)
        last[key] = pair
        return pair.accessToken
    }

    /// Marks `stored` when it still holds the refused `refreshToken` (a pair saved since, by a reconnect, is not).
    private func reject(_ key: String, _ stored: TokenPair, sent refreshToken: String) throws -> Never {
        if stored.refreshToken == refreshToken { marked[key] = stored }
        last[key] = nil
        throw RefresherError.reconnectNeeded
    }

    /// The stored pair, read while no `forget` ran since `generation`.
    private func read(_ key: String, _ generation: Int) async throws -> TokenPair {
        let pair: TokenPair?
        do {
            pair = try await store.read(key)
        } catch {
            throw RefresherError.storeFailed
        }
        try check(key, generation)
        guard let pair else { throw RefresherError.reconnectNeeded }
        return pair
    }

    /// Throws `CancellationError` when `forget` ran since `generation` was taken.
    private func check(_ key: String, _ generation: Int) throws {
        guard generations[key, default: 0] == generation else { throw CancellationError() }
    }

    private func isFresh(_ pair: TokenPair) -> Bool {
        pair.expiresAt.map { $0.timeIntervalSince(now()) > Self.expiryMargin } ?? true
    }

    private static func isRejection(_ error: any Error) -> Bool {
        switch error as? HostingError {
        case .unauthorized, .http(status: 400, _): true
        default: false
        }
    }
}
