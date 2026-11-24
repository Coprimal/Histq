// Commit avatars for the graph's nodes, in the mode `PrefKey.avatarMode` names (DEBUG `-HistqAvatarMode` overrides it):
// "real" (Gravatar by the SHA-256 of the email, the GitHub avatar for `@users.noreply.github.com`), "generated" (a
// deterministic pattern and color from the email's hash) or "initials" (monochrome initials). In every mode, a provider's
// no-reply address (GitHub's web-flow committer, ...) shows the provider's bundled logo and GitHub's bots their real avatar.
// An author's emoji (`setEmoji`, stored app-wide in `PrefKey.authorEmojis`, so the same in every repository on this Mac)
// wins over every mode; provider, bot, `owner:` and email-less identities never get one.
// `avatar(email:name:pixels:)` never waits: in real mode it returns the generated avatar until the real one is loaded
// (memory, then the disk cache under `StatePaths`, then the network, off the main thread), then posts `didChange` so
// the graphs redraw the rows of that email. A 404 is remembered on disk for 7 days; an offline or failed load keeps
// the generated avatar for the session. Only the hash or the GitHub login leaves the Mac, over https only.
// `ownerAvatar(ofRemoteURL:pixels:)` loads, in every mode, the logo of the account or organization owning a remote's
// repository on github.com, gitlab.com or bitbucket.org (the sidebar's remote rows and the graph's remote badges), the
// same way; only the owner's name leaves the Mac, to its own host. `gitHubAvatar(login:id:pixels:)` loads, in every
// mode too, the GitHub avatar of an account of github.com (the pull request and issue pages); only its id or login
// leaves the Mac, to GitHub. `hostedAvatar(url:host:name:pixels:)` loads, in every mode too, the avatar a GitLab API
// gives for an account (`avatar_url`), over https and only from the repository's own host (gitlab.com also from
// gravatar.com); a remote on a GitLab Self-Managed host the profiles have an account for shows GitLab's bundled logo.
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

    /// Posted on the main thread when avatars change: `userInfo[emailKey]` is the email whose real avatar arrived or
    /// whose emoji was set or removed, or absent when the mode or the emoji dictionary changed elsewhere (another
    /// window, a `defaults write`: every node redraws).
    static let didChange = Notification.Name("AvatarStore.didChange")
    static let emailKey = "email"

    private(set) var mode: Mode
    /// The authors' emojis by identity: a mirror of `PrefKey.authorEmojis`, read while drawing rows.
    private(set) var emojis: [String: String]
    /// Loaded real avatars, by `cacheKey`.
    private let images = AvatarImages()
    /// Generated and initials avatars, by kind and identity: resolution-independent drawings.
    private let drawn = AvatarImages()
    /// Keys whose real load ended without an image (404, offline, error): they keep the generated avatar this session.
    private var missing: Set<String> = []
    /// Keys being loaded: one request per email and size.
    private var inFlight: Set<String> = []

    private init() {
        mode = Self.resolveMode()
        emojis = Self.storedEmojis()
        // Posted for every key, possibly off the main thread; only a change of the resolved mode or the emojis redraws.
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

    private static func storedEmojis() -> [String: String] {
        Preferences.defaults.dictionary(forKey: PrefKey.authorEmojis.rawValue) as? [String: String] ?? [:]
    }

    private func preferencesChanged() {
        // `setEmoji` updates the mirror before writing, so its own write finds nothing new here.
        let stored = Self.storedEmojis()
        if stored != emojis {
            emojis = stored
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
        let resolved = Self.resolveMode()
        guard resolved != mode else { return }
        mode = resolved
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The avatar to draw now for an author: `pixels` is the node's diameter in device pixels (the size real avatars
    /// are fetched at). Never blocks; in real mode a missing avatar starts its load and the generated one stands in.
    /// A hosting provider's own address (GitHub's web-flow committer, ...) shows its bundled logo, and GitHub's bots
    /// (`dependabot[bot]`, ...) their real avatar, in every mode. An author's emoji wins over the mode.
    func avatar(email: String, name: String, pixels: Int) -> NSImage? {
        let identity = Self.identity(email: email, name: name)
        if let provider = Self.provider(of: identity) { return providerAvatar(provider) }
        if Self.allowsEmoji(identity), let emoji = emojis[identity] { return emojiAvatar(emoji) }
        let fallback = mode == .initials ? initialsAvatar(name: name) : generatedAvatar(identity: identity)
        // An author email can spell an owner or avatar URL identity (`owner:<host>/<x>`, `avatar:<url>`): never a
        // remote owner's logo or a load of that URL.
        if identity.hasPrefix("owner:") || identity.hasPrefix("avatar:") { return fallback }
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

    // MARK: Author emojis

    /// The emoji set for the author, nil when none is or the author cannot have one.
    func emoji(email: String, name: String) -> String? {
        let identity = Self.identity(email: email, name: name)
        return Self.allowsEmoji(identity) ? emojis[identity] : nil
    }

    /// Whether the author can get an emoji: not without an email, nor a provider's no-reply address, a GitHub bot or
    /// an owner identity (they keep their logo or avatar).
    func canSetEmoji(email: String, name: String) -> Bool {
        Self.allowsEmoji(Self.identity(email: email, name: name))
    }

    private static func allowsEmoji(_ identity: String) -> Bool {
        !identity.hasPrefix("name:") && !identity.hasPrefix("owner:") && provider(of: identity) == nil
            && !identity.hasSuffix("[bot]@users.noreply.github.com")
    }

    /// Sets the author's emoji (the last emoji of `emoji`, `TabEmoji.normalized`), or removes it for nil or text
    /// without one, in every repository on this Mac, and redraws that author. Does nothing when `canSetEmoji` fails.
    func setEmoji(_ emoji: String?, email: String, name: String) {
        let identity = Self.identity(email: email, name: name)
        guard Self.allowsEmoji(identity) else { return }
        emojis[identity] = emoji.flatMap(TabEmoji.normalized)
        storeEmojis(changed: identity)
    }

    /// Removes the emoji stored under `identity` whatever it is (Settings' list, which may hold a key a
    /// `defaults write` stored and `setEmoji` would refuse).
    func removeEmoji(identity: String) {
        emojis[identity] = nil
        storeEmojis(changed: identity)
    }

    /// Writes the mirror (already updated, so the defaults' notification finds nothing new) and redraws `identity`.
    private func storeEmojis(changed identity: String) {
        Preferences.defaults.set(emojis, forKey: PrefKey.authorEmojis.rawValue)
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.emailKey: identity])
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
        // An organization without its own avatar gets GitHub's default one (the `github` organization's white mark
        // on light gray): the readable bundled mark stands in for it.
        let shown = identity.hasPrefix("owner:github.com/") && Self.isGitHubDefaultAvatar(image.cgImage)
            ? gitHubOwnerLogo() : nil
        images.setObject(shown ?? NSImage(cgImage: image.cgImage, size: size), forKey: key as NSString)
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.emailKey: identity])
    }

    // MARK: Remote owners

    /// The logo of the account or organization owning the repository of the remote URL `url` (`Coprimal` of
    /// `github.com/Coprimal/Histq`), at `pixels` on its longer side, whatever the commit avatars' mode. Never blocks:
    /// nil (the caller keeps its own icon) on another host, for a URL `remoteOwner(_:)` refuses, until it is loaded, or
    /// when it cannot be; its arrival posts `didChange` with `ownerIdentity(ofRemoteURL:)`.
    func ownerAvatar(ofRemoteURL url: String, pixels: Int) -> NSImage? {
        guard let remote = Self.remoteOwner(url) else { return nil }
        guard AvatarLoader.ownerHosts.contains(remote.host) else {
            // A GitLab Self-Managed host: GitLab's bundled logo, no request.
            return Self.isGitLabHost(remote.host) ? providerAvatar(.gitlab) : nil
        }
        if remote.host == "github.com", remote.owner.lowercased() == "github" { return gitHubOwnerLogo() }
        let identity = Self.ownerIdentity(host: remote.host, owner: remote.owner)
        let key = "\(identity)|\(pixels)"
        if let image = images.object(forKey: key as NSString) { return image }
        if !missing.contains(key) { load(identity: identity, key: key, pixels: pixels) }
        return nil
    }

    /// Whether a profile has a GitLab account on `host`.
    private static func isGitLabHost(_ host: String) -> Bool {
        ProfileLibrary.shared.store?.profiles.contains { $0.account(forHost: host)?.kind == .gitlab } ?? false
    }

    /// The `github` organization's logo, and GitHub's default avatar: a white mark on light gray is hard to read at 16 pt, so
    /// the bundled mark is drawn black on white instead.
    private func gitHubOwnerLogo() -> NSImage? {
        let cacheKey = "o|github" as NSString
        if let image = drawn.object(forKey: cacheKey) { return image }
        guard let logo = NSImage(named: Provider.github.asset) else { return nil }
        let background = NSColor.white
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            background.setFill()
            rect.fill()
            let mark = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
            let tinted = NSImage(size: mark.size, flipped: false) { markRect in
                logo.draw(in: markRect)
                NSColor.black.setFill()
                markRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: mark)
            return true
        }
        drawn.setObject(image, forKey: cacheKey)
        return image
    }

    /// Whether `image` is GitHub's default avatar: only grays from its light gray background (#C9C9C9) to white, with
    /// both the gray and the white mark present.
    private static func isGitHubDefaultAvatar(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var gray = 0, white = 0
        for index in 0..<(width * height) {
            let r = pixels[index * 4], g = pixels[index * 4 + 1], b = pixels[index * 4 + 2], a = pixels[index * 4 + 3]
            let low = min(r, g, b), high = max(r, g, b)
            guard a >= 250, high - low <= 8, low >= 0xC0 else { return false }
            if low <= 0xD0 { gray += 1 } else if low >= 0xF0 { white += 1 }
        }
        let count = width * height
        return gray * 2 >= count && white * 20 >= count
    }

    /// The identity `didChange` names when the owner logo of the remote URL `url` arrives; nil when it has none.
    static func ownerIdentity(ofRemoteURL url: String) -> String? {
        remoteOwner(url).map { ownerIdentity(host: $0.host, owner: $0.owner) }
    }

    private static func ownerIdentity(host: String, owner: String) -> String {
        "owner:\(host)/\(owner.lowercased())"
    }

    /// The host and owner of a remote URL (`RemoteURL`): its first path segment, the top-level group of a GitLab
    /// subgroup's repository. nil for a URL `RemoteURL` refuses, a path without a repository name after the owner, or
    /// an owner `AvatarLoader.isSafeOwner(_:)` refuses (it goes into the logo's URL).
    private static func remoteOwner(_ url: String) -> (host: String, owner: String)? {
        guard let remote = RemoteURL(url), remote.segments.count >= 2,
              AvatarLoader.isSafeOwner(Substring(remote.segments[0]))
        else { return nil }
        return (remote.host, remote.segments[0])
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

    // MARK: Hosted accounts

    /// The avatar at `url`, the `avatar_url` a GitLab API gave for the account `name` of a repository on `host`, at
    /// `pixels`, whatever the commit avatars' mode (as `gitHubAvatar`), only when `hostedIdentity(url:host:)` accepts
    /// the URL. Never blocks: the
    /// mode's drawn avatar of `name` stands in until it is loaded, and stays when it cannot be; its arrival posts
    /// `didChange` with that identity. Only the request for the image leaves the Mac, to that host (or gravatar.com).
    func hostedAvatar(url: String?, host: String, name: String, pixels: Int) -> NSImage? {
        let fallback = avatar(email: "", name: name, pixels: pixels)
        guard let identity = Self.hostedIdentity(url: url, host: host) else { return fallback }
        let key = "\(identity)|\(pixels)"
        if let image = images.object(forKey: key as NSString) { return image }
        if !missing.contains(key) { load(identity: identity, key: key, pixels: pixels) }
        return fallback
    }

    /// `avatar:<url>` for an https `url` on `host` (with its port, if any; gitlab.com's and bitbucket.org's also on
    /// gravatar.com, bitbucket.org's on Atlassian's avatar service `*.atl-paas.net`), as given (paths are
    /// case-sensitive); nil for any other URL.
    static func hostedIdentity(url: String?, host: String) -> String? {
        guard let url, let parsed = URL(string: url), parsed.scheme?.lowercased() == "https",
              let avatarHost = parsed.host()?.lowercased(), !avatarHost.isEmpty
        else { return nil }
        let host = host.lowercased()
        let authority = parsed.port.map { "\(avatarHost):\($0)" } ?? avatarHost
        let isGravatar = avatarHost == "gravatar.com" || avatarHost.hasSuffix(".gravatar.com")
        let gravatar = (host == "gitlab.com" || host == "bitbucket.org") && isGravatar
        // Bitbucket Cloud's accounts: their avatars are on Atlassian's avatar service.
        let atlassian = host == "bitbucket.org" && parsed.port == nil && avatarHost.hasSuffix(".atl-paas.net")
        return authority == host || gravatar || atlassian ? "avatar:" + url : nil
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

    /// The local drawing for an author in `mode`, whatever the stored mode: the initials in `.initials`, else the
    /// generated pattern (in `.real` too, the stand-in while a picture loads). Never loads anything and never shows an
    /// emoji (the onboarding's preview of each mode).
    func localAvatar(mode: Mode, email: String, name: String) -> NSImage {
        mode == .initials
            ? initialsAvatar(name: name) : generatedAvatar(identity: Self.identity(email: email, name: name))
    }

    /// A 5x5 mirrored pattern in one of the lane colors on a dark disc, from the identity's SHA-256. Opaque, so the
    /// node's lane fill does not show through.
    private func generatedAvatar(identity: String) -> NSImage {
        let cacheKey = "g|\(identity)" as NSString
        if let image = drawn.object(forKey: cacheKey) { return image }
        let hash = Array(SHA256.hash(data: Data(identity.utf8)))
        let lanes = Palette.graphLanes
        let lane = Int(hash[0]) % lanes.count
        // Lane 0's blue is a touch lighter than the accent for the graph's thin lines; on an avatar it reads as a
        // second blue, so it takes the app's one blue (the accent, the selected tab's pill) (user, 2026-11-23).
        let color = lane == 0 ? Self.accent : lanes[lane]
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

    /// The emoji centered on the generated avatar's dark disc, its glyph `emojiFill` of the disc's diameter.
    private func emojiAvatar(_ emoji: String) -> NSImage {
        let cacheKey = "e|\(emoji)" as NSString
        if let image = drawn.object(forKey: cacheKey) { return image }
        let background = Self.background
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            background.setFill()
            rect.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            // Sized and centered by the glyph's own box (from the baseline, y up), not the line's, which adds leading
            // and descent around it.
            let side = rect.width * Self.emojiFill
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: side)]))
            let glyph = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            guard glyph.width > 0, glyph.height > 0 else { return true }
            let scale = side / max(glyph.width, glyph.height)
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: scale, y: scale)
            context.textPosition = CGPoint(x: -glyph.midX, y: -glyph.midY)
            CTLineDraw(line, context)
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

    /// An emoji avatar's glyph box, as a fraction of the disc's diameter: the emoji fills the disc inside the lane ring.
    private static let emojiFill: CGFloat = 0.9
    /// The accent (`AccentColor`) in sRGB: lane 0's color on a generated avatar. #2F86FB
    private static let accent = NSColor(srgbRed: 0x2F / 255, green: 0x86 / 255, blue: 0xFB / 255, alpha: 1)
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
    /// owner's logo (`owner:<host>/<owner>`), or an account's avatar URL (`avatar:<https URL>`). nil when a GitHub
    /// address has neither a valid id nor a valid login, or an avatar URL is not https.
    static func url(identity: String, hash: String, pixels: Int) async -> URL? {
        if identity.hasPrefix("owner:") { return await ownerURL(identity.dropFirst("owner:".count), pixels: pixels) }
        if identity.hasPrefix("avatar:") {
            let url = URL(string: String(identity.dropFirst("avatar:".count)))
            guard let url, url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
            return url
        }
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
    /// `AvatarStore.remoteOwner(_:)` checks it (ASCII letters, digits, `-`, `_`): nil when it fails.
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

    /// `[A-Za-z0-9_-]+`: an owner put into a logo's URL as it is.
    static func isSafeOwner(_ owner: Substring) -> Bool {
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

/// The avatars' in-memory cache. Not an `NSCache`: under memory pressure ("warn", common with VMs running) an
/// `NSCache` drops an image right after it is stored, so the redraw its arrival causes misses it, loads it again from
/// disk and redraws again, endlessly (thousands of loads a second, the generated avatar on screen, every click
/// late). Images stay until `limit` is reached, then the cache starts over: each avatar on screen loads once more,
/// with no loop as long as fewer than `limit` are drawn at once.
@MainActor
private final class AvatarImages {
    /// Avatars are small (tens of KB decoded at most): a few tens of MB at the limit.
    private static let limit = 1_000
    private var images: [NSString: NSImage] = [:]

    func object(forKey key: NSString) -> NSImage? { images[key] }

    func setObject(_ image: NSImage, forKey key: NSString) {
        if images.count >= Self.limit, images[key] == nil { images.removeAll(keepingCapacity: true) }
        images[key] = image
    }
}
