// A profile is who Histq acts as in one tab: the commit identity, optional signing, the SSH key and the
// code host accounts. It is injected into each git process (see `GitInvocation`); `.git/config` is never
// edited. It holds no secrets: tokens live in the Keychain, keys stay where they are on disk.
import Foundation

public struct Profile: Codable, Sendable, Equatable, Identifiable {
    public struct Identity: Codable, Sendable, Equatable {
        public var name: String
        public var email: String

        public init(name: String, email: String) {
            self.name = name
            self.email = email
        }
    }

    public enum Signing: Codable, Sendable, Equatable {
        case none
        /// An OpenPGP key ID or fingerprint, used with the user's `gpg`.
        case gpg(keyID: String)
        /// A path to an SSH key (private, or public when the agent holds the private key).
        case ssh(keyPath: String)

        /// Whether this signs at all: GPG or SSH with a key that is not blank. A blank key would hand git an empty
        /// `user.signingKey`, which makes it fall back to whatever key gpg or ssh picks, so it counts as no signing.
        public var isUsable: Bool {
            switch self {
            case .none: false
            case .gpg(let key), .ssh(let key): !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    public enum SSHKey: Codable, Sendable, Equatable {
        /// Whatever keys the SSH agent (and `~/.ssh/config`) offer.
        case agent
        /// This private key only (`-i <path> -o IdentitiesOnly=yes`).
        case keyFile(path: String)
    }

    /// The legacy `github` key: one GitHub account, as builds without `accounts` saved it.
    private struct GitHubAccount: Codable, Sendable, Equatable {
        var host: String
        var login: String
    }

    public var id: UUID
    public var name: String
    /// A `#RRGGBB` color for the profile's badge.
    public var color: String
    public var identity: Identity
    public var signing: Signing
    /// Sign new commits without being asked (only meaningful when `signing` is not `.none`).
    public var signByDefault: Bool
    public var ssh: SSHKey
    /// The code host accounts, at most one per host (`setAccount(_:)`).
    public private(set) var accounts: [HostingAccount]
    /// Saved accounts this build cannot read (a newer kind), kept as they were so a save never drops them.
    var unknownAccounts: [JSONValue] = []

    public init(
        id: UUID = UUID(), name: String, color: String, identity: Identity, signing: Signing = .none,
        signByDefault: Bool = false, ssh: SSHKey = .agent
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.identity = identity
        self.signing = signing
        self.signByDefault = signByDefault
        self.ssh = ssh
        self.accounts = []
    }

    // MARK: - Accounts

    /// The account on `host` (hosts compare lowercase, as `HostingHTTP.validatedHost` gives them); nil when the
    /// profile has none there or `host` is not a valid host.
    public func account(forHost host: String) -> HostingAccount? {
        guard HostingHTTP.validatedHost(host) != nil else { return nil }
        return accounts.first { Self.sameHost($0.host, host) }
    }

    /// Adds `account`, or puts it in place of the account on its host: a profile has one account per host.
    public mutating func setAccount(_ account: HostingAccount) {
        guard let index = accounts.firstIndex(where: { Self.sameHost($0.host, account.host) }) else {
            accounts.append(account)
            return
        }
        accounts.removeAll { Self.sameHost($0.host, account.host) }
        accounts.insert(account, at: index)
    }

    public mutating func removeAccount(forHost host: String) {
        accounts.removeAll { Self.sameHost($0.host, host) }
    }

    /// The first GitHub account as the legacy `github` key saves it.
    private var legacyGitHub: GitHubAccount? {
        accounts.first { $0.kind == .github }.map { GitHubAccount(host: $0.host, login: $0.login) }
    }

    private static func sameHost(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    // MARK: - Codable

    // The keys of the synthesized coding this replaces, plus `accounts`. `github` is the first GitHub account, still
    // written so a build without `accounts` reads it, and read when `accounts` is missing (a file such a build wrote).
    private enum CodingKeys: String, CodingKey {
        case id, name, color, identity, signing, signByDefault, ssh, accounts, github
    }

    /// One element of the saved `accounts`: an account this build reads, or anything else, kept as raw JSON.
    private enum SavedAccount: Decodable {
        case known(HostingAccount)
        case unknown(JSONValue)

        init(from decoder: any Decoder) throws {
            if let account = try? HostingAccount(from: decoder) {
                self = .known(account)
            } else {
                self = .unknown(try JSONValue(from: decoder))
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(String.self, forKey: .color)
        identity = try container.decode(Identity.self, forKey: .identity)
        signing = try container.decode(Signing.self, forKey: .signing)
        signByDefault = try container.decode(Bool.self, forKey: .signByDefault)
        ssh = try container.decode(SSHKey.self, forKey: .ssh)
        accounts = []
        if let saved = try container.decodeIfPresent([SavedAccount].self, forKey: .accounts) {
            for entry in saved {
                switch entry {
                case .known(let account): accounts.append(account)
                case .unknown(let raw): unknownAccounts.append(raw)
                }
            }
        } else if let legacy = try container.decodeIfPresent(GitHubAccount.self, forKey: .github) {
            accounts = [HostingAccount(kind: .github, host: legacy.host, login: legacy.login)]
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(identity, forKey: .identity)
        try container.encode(signing, forKey: .signing)
        try container.encode(signByDefault, forKey: .signByDefault)
        try container.encode(ssh, forKey: .ssh)
        // No `accounts` key without accounts: such a profile is saved as before.
        if !accounts.isEmpty || !unknownAccounts.isEmpty {
            var list = container.nestedUnkeyedContainer(forKey: .accounts)
            try list.encode(contentsOf: accounts)
            try list.encode(contentsOf: unknownAccounts)
        }
        try container.encodeIfPresent(legacyGitHub, forKey: .github)
    }
}

/// An account on a code host. `host` is kept as entered (the Keychain item is keyed by it); `basePath` is the path
/// the instance lives under on that host (nil at the root); `gitUsername` the username git sends with the token (nil:
/// the kind's own); `oauthClientID` the OAuth app the token came from (nil: Histq's own). It holds no token.
public struct HostingAccount: Codable, Sendable, Hashable {
    public var kind: HostingKind
    public var host: String
    public var basePath: String?
    public var login: String
    public var gitUsername: String?
    public var oauthClientID: String?

    public init(
        kind: HostingKind, host: String, basePath: String? = nil, login: String, gitUsername: String? = nil,
        oauthClientID: String? = nil
    ) {
        self.kind = kind
        self.host = host
        self.basePath = basePath
        self.login = login
        self.gitUsername = gitUsername
        self.oauthClientID = oauthClientID
    }
}

/// Any JSON value, read and written back as it is (integers stay integers).
enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
