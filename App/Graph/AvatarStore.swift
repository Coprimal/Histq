// Commit avatars for the graph's nodes, in the mode `PrefKey.avatarMode` names (DEBUG `-HistqAvatarMode` overrides it):
// "real" (Gravatar by the SHA-256 of the email, the GitHub avatar for `@users.noreply.github.com`), "generated" (a
// deterministic pattern and color from the email's hash) or "initials" (monochrome initials). In every mode, a provider's
// no-reply address (GitHub's web-flow committer, ...) shows the provider's bundled logo and GitHub's bots their real avatar.
// `avatar(email:name:pixels:)` never waits: in real mode it returns the generated avatar until the real one is loaded
// (memory, then the disk cache under `StatePaths`, then the network, off the main thread), then posts `didChange` so
// the graphs redraw the rows of that email. A 404 is remembered on disk for 7 days; an offline or failed load keeps
// the generated avatar for the session. Only the hash or the GitHub login leaves the Mac, over https only.
// `ownerAvatar(of:pixels:)` loads, in every mode, the logo of the account or organization owning a remote's
// repository on github.com, gitlab.com or bitbucket.org (the sidebar's remote rows and the graph's remote badges), the
// same way; only the owner's name leaves the Mac, to its own host. `gitHubAvatar(login:id:pixels:)` loads, in every
// mode too, the GitHub avatar of an account of github.com (the pull request and issue pages); only its id or login
// leaves the Mac, to GitHub.
import AppKit
import CryptoKit
import HistqCore
import ImageIO
import os

@MainActor
final class AvatarStore {
    static let shared = AvatarStore()

    enum Mode: String {
        case real, generated, initials
    }

    /// Posted on the main thread when avatars change: `userInfo[emailKey]` is the email whose real avatar arrived, or
    /// absent when the mode changed (every node redraws).
    static let didChange = Notification.Name("AvatarStore.didChange")
    static let emailKey = "email"

    private(set) var mode: Mode
    /// Loaded real avatars, by `cacheKey`.
    private let images = NSCache<NSString, NSImage>()
    /// Generated and initials avatars, by kind and identity: resolution-independent drawings.
    private let drawn = NSCache<NSString, NSImage>()
    /// Keys whose real load ended without an image (404, offline, error): they keep the generated avatar this session.
    private var missing: Set<String> = []
    /// Keys being loaded: one request per email and size.
    private var inFlight: Set<String> = []

    private init() {
        mode = Self.resolveMode()
        // Posted for every key, possibly off the main thread; only a change of the resolved mode redraws.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: Preferences.defaults, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AvatarStore.shared.preferencesChanged() }
        }
    }

    /// The launch flag, then the preference (registered default "generated"); anything unknown reads as generated.
    /// Real avatars send each author's email hash to gravatar.com, so they are an opt-in (the Phase 7 Appearance
    /// page), never a default.
    private static func resolveMode() -> Mode {
        let value = AppState.launchFlag("-HistqAvatarMode")
            ?? Preferences.defaults.string(forKey: PrefKey.avatarMode.rawValue)
        return value.flatMap(Mode.init(rawValue:)) ?? .generated
    }

    private func preferencesChanged() {
        let resolved = Self.resolveMode()
        guard resolved != mode else { return }
        mode = resolved
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The avatar to draw now for an author: `pixels` is the node's diameter in device pixels (the size real avatars
    /// are fetched at). Never blocks; in real mode a missing avatar starts its load and the generated one stands in.
    /// A hosting provider's own address (GitHub's web-flow committer, ...) shows its bundled logo, and GitHub's bots
    /// (`dependabot[bot]`, ...) their real avatar, in every mode.
    func avatar(email: String, name: String, pixels: Int) -> NSImage? {
        let identity = Self.identity(email: email, name: name)
        if let provider = Self.provider(of: identity) { return providerAvatar(provider) }
        let fallback = mode == .initials ? initialsAvatar(name: name) : generatedAvatar(identity: identity)
        // An author email can spell an owner identity (`owner:<host>/<x>`): never a remote owner's logo or load.
        if identity.hasPrefix("owner:") { return fallback }
        // A bot's avatar sends only the bot's login to GitHub.
        guard mode == .real || identity.hasSuffix("[bot]@users.noreply.github.com") else { return fallback }
        let key = "\(identity)|\(pixels)" as String
        if let image = images.object(forKey: key as NSString) { return image }
        if !missing.contains(key), !email.isEmpty { load(identity: identity, key: key, pixels: pixels) }
        return fallback
    }

    /// The trimmed, lowercased email (the name when there is none): what the hash, the caches and the files use.
    private static func identity(email: String, name: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "name:" + name : trimmed
    }

    // MARK: Real avatars

    private func load(identity: String, key: String, pixels: Int) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let image = await AvatarLoader.load(identity: identity, pixels: pixels)
            await MainActor.run {
                AvatarStore.shared.loaded(key: key, identity: identity, image: image)
            }
        }
    }

    private func loaded(key: String, identity: String, image: AvatarLoader.Decoded?) {
        inFlight.remove(key)
        guard let image else {
            // Resolved for the session: the generated avatar already on screen stays, nothing redraws.
            missing.insert(key)
            return
        }
        let size = NSSize(width: image.cgImage.width, height: image.cgImage.height)
        images.setObject(NSImage(cgImage: image.cgImage, size: size), forKey: key as NSString)
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.emailKey: identity])
    }

    // MARK: Remote owners

    /// The logo of the account or organization owning `repository` (`Coprimal` of `github.com/Coprimal/Histq`), at
    /// `pixels` on its longer side, whatever the commit avatars' mode. Never blocks: nil (the caller keeps its own
    /// icon) on another host, until it is loaded, or when it cannot be; its arrival posts `didChange` with
    /// `ownerIdentity(_:)`.
    func ownerAvatar(of repository: HostedRepository, pixels: Int) -> NSImage? {
        guard AvatarLoader.ownerHosts.contains(repository.host) else { return nil }
        let identity = Self.ownerIdentity(repository)
        let key = "\(identity)|\(pixels)"
        if let image = images.object(forKey: key as NSString) { return image }
        if !missing.contains(key) { load(identity: identity, key: key, pixels: pixels) }
        return nil
    }

    /// The identity `didChange` names when the owner logo of `repository` arrives.
    static func ownerIdentity(_ repository: HostedRepository) -> String {
        "owner:\(repository.host)/\(repository.owner.lowercased())"
    }

    /// Whether `email` is the identity `didChange` named (the graph compares its rows' emails with it).
    static func matches(email: String, name: String, changed: String) -> Bool {
        identity(email: email, name: name) == changed
    }

    // MARK: GitHub accounts

    /// The GitHub avatar of the account `login` of github.com (`id`: its user id, when known), at `pixels`, whatever
    /// the commit avatars' mode: the pull request and issue pages show GitHub's accounts as GitHub does. Never blocks:
    /// the mode's generated or initials avatar stands in until it is loaded, and stays when it cannot be; its arrival
    /// posts `didChange` with the identity of `gitHubEmail(login:id:)`. Only for github.com's accounts: the stub and
    /// Enterprise hosts use `avatar(email: "", name: login, ...)`, which sends nothing.
    func gitHubAvatar(login: String, id: Int?, pixels: Int) -> NSImage? {
        let identity = Self.identity(email: Self.gitHubEmail(login: login, id: id), name: login)
        let fallback = mode == .initials ? initialsAvatar(name: login) : generatedAvatar(identity: identity)
        let key = "\(identity)|\(pixels)"
        if let image = images.object(forKey: key as NSString) { return image }
        if !missing.contains(key) { load(identity: identity, key: key, pixels: pixels) }
        return fallback
    }

    /// GitHub's noreply address of the account (`<id>+<login>@`, `<login>@` without the id): `AvatarLoader` builds
    /// the avatar's URL from it, and `matches` compares it with what `didChange` named.
    static func gitHubEmail(login: String, id: Int?) -> String {
        (id.map { "\($0)+" } ?? "") + login + "@users.noreply.github.com"
    }

    // MARK: Provider logos

    /// A hosting provider whose own no-reply address commits (web merges and edits, pipelines): `rawValue` is its
    /// domain, its asset is `logo-<rawValue>` (simple-icons, CC0).
    enum Provider: String {
        case github = "github.com", gitlab = "gitlab.com", bitbucket = "bitbucket.org", codeberg = "codeberg.org"

        var asset: String { "logo-" + rawValue.prefix { $0 != "." } }
        /// The brand color, but white for GitHub's near-black.
        var color: NSColor {
            switch self {
            case .github: .white
            case .gitlab: NSColor(srgbRed: 0xFC / 255, green: 0x6D / 255, blue: 0x26 / 255, alpha: 1)
            case .bitbucket: NSColor(srgbRed: 0x00 / 255, green: 0x52 / 255, blue: 0xCC / 255, alpha: 1)
            case .codeberg: NSColor(srgbRed: 0x21 / 255, green: 0x85 / 255, blue: 0xD0 / 255, alpha: 1)
            }
        }
    }

    /// `noreply@`, `no-reply@` or `commits-noreply@` one of the providers' domains (the identity is lowercased).
    private static func provider(of identity: String) -> Provider? {
        guard let at = identity.lastIndex(of: "@"),
              ["noreply", "no-reply", "commits-noreply"].contains(identity[..<at])
        else { return nil }
        return Provider(rawValue: String(identity[identity.index(after: at)...]))
    }

    /// The provider's logo in its color on the generated avatar's dark disc.
    private func providerAvatar(_ provider: Provider) -> NSImage? {
        let cacheKey = "p|\(provider.rawValue)" as NSString
        if let image = drawn.object(forKey: cacheKey) { return image }
        guard let logo = NSImage(named: provider.asset) else { return nil }
        let background = Self.background
        let color = provider.color
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            background.setFill()
            rect.fill()
            let mark = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
            let tinted = NSImage(size: mark.size, flipped: false) { markRect in
                logo.draw(in: markRect)
                color.setFill()
                markRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: mark)
            return true
        }
        drawn.setObject(image, forKey: cacheKey)
        return image
    }

    // MARK: Generated and initials avatars

    /// A 5x5 mirrored pattern in one of the lane colors on a dark disc, from the identity's SHA-256. Opaque, so the
    /// node's lane fill does not show through.
    private func generatedAvatar(identity: String) -> NSImage {
        let cacheKey = "g|\(identity)" as NSString
        if let image = drawn.object(forKey: cacheKey) { return image }
        let hash = Array(SHA256.hash(data: Data(identity.utf8)))
        let lanes = Palette.graphLanes
        let color = lanes[Int(hash[0]) % lanes.count]
        // Bits 0..<15 of bytes 1...2 pick the cells of the 3 left columns; the right 2 mirror them.
        let bits = UInt32(hash[1]) | UInt32(hash[2]) << 8
        let background = Self.background
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
            background.setFill()
            rect.fill()
            color.setFill()
            let inset = rect.width * 0.18
            let cell = (rect.width - 2 * inset) / 5
            for column in 0..<3 {
                for row in 0..<5 where bits & (1 << UInt32(column * 5 + row)) != 0 {
                    for x in Set([column, 4 - column]) {
                        NSRect(x: rect.minX + inset + CGFloat(x) * cell, y: rect.minY + inset + CGFloat(row) * cell,
                               width: cell, height: cell).fill()
                    }
                }
            }
            return true
        }
        drawn.setObject(image, forKey: cacheKey)
        return image
    }

    /// The author's initials, light on a neutral disc: the same for every author and lane (the lane ring stays).
    private func initialsAvatar(name: String) -> NSImage {
        let initials = GraphRowDrawing.initials(of: name)
        let cacheKey = "i|\(initials)" as NSString
        if let image = drawn.object(forKey: cacheKey) { return image }
        let fill = Self.initialsFill
        let textColor = Self.initialsText
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
            fill.setFill()
            rect.fill()
            guard !initials.isEmpty else { return true }
            let font = NSFont.systemFont(ofSize: (rect.height * 0.46).rounded(), weight: .semibold)
            let text = NSAttributedString(
                string: initials, attributes: [.font: font, .foregroundColor: textColor])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        drawn.setObject(image, forKey: cacheKey)
        return image
    }

    /// The generated avatar's background: darker than the card so the pattern stands out. #1C1C1E
    private static let background = NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    /// The initials avatar's disc and letters. #48484A, white 0.92
    private static let initialsFill = NSColor(srgbRed: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255, alpha: 1)
    private static let initialsText = NSColor.white.withAlphaComponent(0.92)
}

/// The off-main half of real avatars: disk cache, network, decoding. Holds no state of its own beyond the session.
private enum AvatarLoader {
    /// A decoded avatar. CGImage is immutable, so crossing to the main actor is safe.
    struct Decoded: @unchecked Sendable {
        let cgImage: CGImage
    }

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "avatars")
    /// Larger downloads are ignored.
    private static let maxBytes = 1_000_000
    /// How long a 404 is believed.
    private static let notFoundTTL: TimeInterval = 7 * 24 * 3600

    /// Created on first use, off the main thread (`StatePaths.directory` creates the folder).
    private static let directory: URL = StatePaths.directory("Avatars")

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: HTTPSOnly(), delegateQueue: nil)
    }()

    /// The disk cache, then the network. nil: use the generated avatar.
    static func load(identity: String, pixels: Int) async -> Decoded? {
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appending(path: "\(hash)-\(pixels).img")
        let marker = directory.appending(path: "\(hash).404")
        let fileManager = FileManager.default

        if let data = try? Data(contentsOf: file), let image = decode(data, pixels: pixels) {
            return image
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: marker.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < notFoundTTL
        {
            return nil
        }
        guard !identity.hasPrefix("name:"), let url = await url(identity: identity, hash: hash, pixels: pixels) else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 {
                fileManager.createFile(atPath: marker.path, contents: nil)
                return nil
            }
            guard http.statusCode == 200, http.expectedContentLength <= maxBytes, data.count <= maxBytes,
                  let image = decode(data, pixels: pixels)
            else { return nil }
            try? data.write(to: file, options: .atomic)
            try? fileManager.removeItem(at: marker)
            return image
        } catch {
            logger.debug("avatar load failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Gravatar by hash, or the GitHub avatar for a noreply address (`<id>+<login>@` or `<login>@`), or a remote
    /// owner's logo (`owner:<host>/<owner>`). nil when a GitHub address has neither a valid id nor a valid login.
    static func url(identity: String, hash: String, pixels: Int) async -> URL? {
        if identity.hasPrefix("owner:") { return await ownerURL(identity.dropFirst("owner:".count), pixels: pixels) }
        let suffix = "@users.noreply.github.com"
        guard identity.hasSuffix(suffix) else {
            return URL(string: "https://gravatar.com/avatar/\(hash)?s=\(pixels)&d=404")
        }
        let local = identity.dropLast(suffix.count)
        var id: Substring?
        var login = local
        if let plus = local.firstIndex(of: "+") {
            id = local[..<plus]
            login = local[local.index(after: plus)...]
        }
        if let id, (1...20).contains(id.count), id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) {
            return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=\(pixels)")
        }
        // A bot without its id (`github-actions[bot]@`): the account of the same name has its picture.
        if login.hasSuffix("[bot]") { login = login.dropLast(5) }
        guard isValidLogin(login) else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(login)?s=\(pixels)")
    }

    /// The hosts whose owner logos load without an account.
    static let ownerHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]

    /// `<host>/<owner>`: GitHub's avatar of the login, Bitbucket's workspace avatar (a redirect to the image), or the
    /// `avatar_url` gitlab.com's API gives. The owner goes into the request URL, so it is checked again here as
    /// `GitHubClient.repository(fromRemoteURL:)` checks it (ASCII letters, digits, `-`, `_`): nil when it fails.
    private static func ownerURL(_ path: Substring, pixels: Int) async -> URL? {
        let parts = path.split(separator: "/")
        guard parts.count == 2, isSafeOwner(parts[1]) else { return nil }
        let owner = parts[1]
        switch parts[0] {
        case "github.com":
            guard isValidLogin(owner) else { return nil }
            return URL(string: "https://avatars.githubusercontent.com/\(owner)?s=\(pixels)")
        case "bitbucket.org":
            return URL(string: "https://bitbucket.org/workspaces/\(owner)/avatar/")
        case "gitlab.com":
            return await gitLabAvatarURL(owner)
        default:
            return nil
        }
    }

    /// The `avatar_url` of the gitlab.com group named `owner`, else of the user: an owner is one or the other. nil
    /// when neither answers, has none, or it is not https.
    private static func gitLabAvatarURL(_ owner: Substring) async -> URL? {
        struct Entity: Decodable {
            let avatarURL: String?
            enum CodingKeys: String, CodingKey { case avatarURL = "avatar_url" }
        }
        let endpoints = [("groups/\(owner)?with_projects=false", false), ("users?username=\(owner)", true)]
        for (endpoint, isList) in endpoints {
            guard let url = URL(string: "https://gitlab.com/api/v4/\(endpoint)"),
                  let result = try? await session.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200, result.0.count <= maxBytes
            else { continue }
            let decoder = JSONDecoder()
            let entity = isList
                ? (try? decoder.decode([Entity].self, from: result.0))?.first
                : try? decoder.decode(Entity.self, from: result.0)
            guard let entity else { continue }
            guard let string = entity.avatarURL, let avatar = URL(string: string), avatar.scheme == "https" else {
                return nil
            }
            return avatar
        }
        return nil
    }

    /// `[A-Za-z0-9_-]+`, the owner rule of `GitHubClient.repository(fromRemoteURL:)`.
    private static func isSafeOwner(_ owner: Substring) -> Bool {
        !owner.isEmpty && owner.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    /// `[A-Za-z0-9-]{1,39}`.
    private static func isValidLogin(_ login: Substring) -> Bool {
        (1...39).contains(login.count)
            && login.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// Decodes at most `pixels` on the longer side, fully decoded here so the main thread only draws it.
    private static func decode(_ data: Data, pixels: Int) -> Decoded? {
        guard data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, pixels),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Decoded(cgImage: image)
    }
}

/// Follows a redirect only to another https URL.
private final class HTTPSOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme == "https" ? request : nil
    }
}
