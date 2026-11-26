// A profile is who Histq acts as in one tab: the commit identity, optional signing, the SSH key and the code host
// accounts. It is injected into each git process (see GitInvocation); .git/config is never edited. It holds no secrets:
// tokens live in the credential store, keys stay where they are on disk. Its JSON is the one profiles.json and the
// workspace files hold on the Mac, key for key (Profile.swift): `github` is still written (the first GitHub account)
// for builds without `accounts`, and read when `accounts` is missing; an account this build cannot read (a newer kind)
// is kept as raw JSON so a save never drops it.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Histq.Core;

/// <summary>The commit identity of a profile.</summary>
public sealed record ProfileIdentity(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("email")] string Email);

/// <summary>How a profile signs commits: <c>{"none":{}}</c>, <c>{"gpg":{"keyID":...}}</c> or <c>{"ssh":{"keyPath":...}}</c>.</summary>
[JsonConverter(typeof(SwiftEnumConverter<ProfileSigning>))]
public abstract record ProfileSigning
{
    private ProfileSigning()
    {
    }

    /// <summary>
    /// Whether this signs at all: GPG or SSH with a key that is not blank. A blank key would hand git an empty
    /// <c>user.signingKey</c>, which makes it fall back to whatever key gpg or ssh picks, so it counts as no signing.
    /// </summary>
    [JsonIgnore]
    public bool IsUsable => this switch
    {
        Gpg gpg => !string.IsNullOrWhiteSpace(gpg.KeyID),
        Ssh ssh => !string.IsNullOrWhiteSpace(ssh.KeyPath),
        _ => false,
    };

    [SwiftEnumCase("none")]
    public sealed record None : ProfileSigning;

    /// <summary>An OpenPGP key ID or fingerprint, used with the user's <c>gpg</c>.</summary>
    [SwiftEnumCase("gpg")]
    public sealed record Gpg([property: JsonPropertyName("keyID")] string KeyID) : ProfileSigning;

    /// <summary>A path to an SSH key (private, or public when the agent holds the private key).</summary>
    [SwiftEnumCase("ssh")]
    public sealed record Ssh([property: JsonPropertyName("keyPath")] string KeyPath) : ProfileSigning;
}

/// <summary>Which SSH key a profile uses: <c>{"agent":{}}</c> or <c>{"keyFile":{"path":...}}</c>.</summary>
[JsonConverter(typeof(SwiftEnumConverter<ProfileSshKey>))]
public abstract record ProfileSshKey
{
    private ProfileSshKey()
    {
    }

    /// <summary>Whatever keys the SSH agent (and <c>~/.ssh/config</c>) offer.</summary>
    [SwiftEnumCase("agent")]
    public sealed record Agent : ProfileSshKey;

    /// <summary>This private key only (<c>-i &lt;path&gt; -o IdentitiesOnly=yes</c>).</summary>
    [SwiftEnumCase("keyFile")]
    public sealed record KeyFile([property: JsonPropertyName("path")] string Path) : ProfileSshKey;
}

/// <summary>
/// Which code host a provider talks to. The raw value is saved in profiles.json: never change it. Only the cases here
/// for now; the hosting port (HostingProvider.swift) adds its members to this enum.
/// </summary>
[JsonConverter(typeof(SwiftRawEnumConverter<HostingKind>))]
public enum HostingKind
{
    [JsonStringEnumMemberName("github")]
    GitHub,

    [JsonStringEnumMemberName("gitlab")]
    GitLab,

    /// <summary>Bitbucket Cloud (<c>bitbucket.org</c>, API 2.0). Bitbucket Data Center is a kind of its own.</summary>
    [JsonStringEnumMemberName("bitbucketCloud")]
    BitbucketCloud,

    /// <summary>Bitbucket Data Center (a server of its own, REST API 1.0).</summary>
    [JsonStringEnumMemberName("bitbucketDataCenter")]
    BitbucketDataCenter,

    /// <summary>Azure DevOps Services (<c>dev.azure.com</c>).</summary>
    [JsonStringEnumMemberName("azureDevOps")]
    AzureDevOps,
}

/// <summary>
/// An account on a code host. <see cref="Host"/> is kept as entered (the credential item is keyed by it);
/// <see cref="BasePath"/> is the path the instance lives under on that host (null at the root);
/// <see cref="GitUsername"/> the username git sends with the token (null: the kind's own); <see cref="OAuthClientID"/>
/// the OAuth app the token came from (null: Histq's own). It holds no token.
/// </summary>
public sealed record HostingAccount(
    [property: JsonPropertyName("kind")] HostingKind Kind,
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("login")] string Login,
    [property: JsonPropertyName("basePath")] string? BasePath = null,
    [property: JsonPropertyName("gitUsername")] string? GitUsername = null,
    [property: JsonPropertyName("oauthClientID")] string? OAuthClientID = null);

/// <summary>
/// Who Histq acts as in one tab. A value: change it with <c>with</c>, <see cref="WithAccount"/> and
/// <see cref="WithoutAccount"/>. Equal when every field, accounts and unread accounts included, is equal.
/// </summary>
[JsonConverter(typeof(ProfileJsonConverter))]
public sealed record Profile
{
    public Profile(
        string name, string color, ProfileIdentity identity, ProfileSigning? signing = null, bool signByDefault = false,
        ProfileSshKey? ssh = null, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Name = name;
        Color = color;
        Identity = identity;
        Signing = signing ?? new ProfileSigning.None();
        SignByDefault = signByDefault;
        Ssh = ssh ?? new ProfileSshKey.Agent();
    }

    public Guid Id { get; init; }

    public string Name { get; init; }

    /// <summary>A <c>#RRGGBB</c> color for the profile's badge.</summary>
    public string Color { get; init; }

    public ProfileIdentity Identity { get; init; }

    public ProfileSigning Signing { get; init; }

    /// <summary>Sign new commits without being asked (only meaningful when <see cref="Signing"/> is not none).</summary>
    public bool SignByDefault { get; init; }

    public ProfileSshKey Ssh { get; init; }

    /// <summary>The code host accounts, at most one per host (<see cref="WithAccount"/>).</summary>
    public IReadOnlyList<HostingAccount> Accounts { get; private init; } = [];

    /// <summary>Saved accounts this build cannot read (a newer kind), kept as they were so a save never drops them.</summary>
    internal IReadOnlyList<JsonElement> UnknownAccounts { get; private init; } = [];

    /// <summary>
    /// The account on <paramref name="host"/> (hosts compare case-insensitively); null when the profile has none
    /// there or <paramref name="host"/> is not a valid host.
    /// </summary>
    public HostingAccount? AccountForHost(string host) =>
        ValidatedHost(host) is null ? null : Accounts.FirstOrDefault(account => SameHost(account.Host, host));

    /// <summary>This profile with <paramref name="account"/> added, or put in place of the account on its host: a
    /// profile has one account per host.</summary>
    public Profile WithAccount(HostingAccount account)
    {
        var accounts = Accounts.ToList();
        var index = accounts.FindIndex(existing => SameHost(existing.Host, account.Host));
        if (index < 0)
        {
            accounts.Add(account);
        }
        else
        {
            accounts.RemoveAll(existing => SameHost(existing.Host, account.Host));
            accounts.Insert(index, account);
        }

        return this with { Accounts = accounts };
    }

    /// <summary>This profile without its account on <paramref name="host"/>.</summary>
    public Profile WithoutAccount(string host) =>
        this with { Accounts = Accounts.Where(account => !SameHost(account.Host, host)).ToList() };

    public bool Equals(Profile? other) =>
        other is not null
        && Id == other.Id
        && string.Equals(Name, other.Name, StringComparison.Ordinal)
        && string.Equals(Color, other.Color, StringComparison.Ordinal)
        && Identity == other.Identity
        && Signing == other.Signing
        && SignByDefault == other.SignByDefault
        && Ssh == other.Ssh
        && Accounts.SequenceEqual(other.Accounts)
        && UnknownAccounts.Count == other.UnknownAccounts.Count
        && UnknownAccounts.Zip(other.UnknownAccounts).All(pair => JsonElement.DeepEquals(pair.First, pair.Second));

    public override int GetHashCode() => HashCode.Combine(Id, Name, Color, Identity, Signing, SignByDefault, Ssh, Accounts.Count);

    /// <summary>
    /// <paramref name="host"/> lower-cased when it is a valid <c>name[:port]</c>: ASCII letters, digits, <c>.</c>,
    /// <c>_</c> and <c>-</c>, 1 to 253 characters, not starting with <c>.</c> or <c>-</c>; a port of ASCII digits in
    /// 1...65535. Else null. The Swift HostingHTTP.validatedHost; the hosting port moves it there.
    /// </summary>
    internal static string? ValidatedHost(string host)
    {
        var colon = host.IndexOf(':', StringComparison.Ordinal);
        var name = colon < 0 ? host : host[..colon];
        var nameOK = name.Length is > 0 and <= 253 && name[0] != '.' && name[0] != '-'
            && name.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-');
        if (!nameOK)
        {
            return null;
        }

        if (colon >= 0)
        {
            var port = host[(colon + 1)..];
            if (port.Length == 0 || !port.All(char.IsAsciiDigit) || !int.TryParse(port, out var number) || number is < 1 or > 65535)
            {
                return null;
            }
        }

        return host.ToLowerInvariant();
    }

    private static bool SameHost(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The custom coding of Profile.swift: the keys id, name, color, identity, signing, signByDefault, ssh; then
    /// <c>accounts</c> (known accounts, then unread ones) only when there are any, and <c>github</c> (host and login of
    /// the first GitHub account) when there is one. Reading takes <c>github</c> only when <c>accounts</c> is missing.
    /// </summary>
    private sealed class ProfileJsonConverter : JsonConverter<Profile>
    {
        /// <summary>Null reaches <see cref="Read"/>, which rejects it: a null element of <c>[Profile]</c> is an error, as in Swift.</summary>
        public override bool HandleNull => true;

        public override Profile Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            var json = JsonElement.ParseValue(ref reader);
            if (json.ValueKind != JsonValueKind.Object)
            {
                throw new JsonException("A profile is an object.");
            }

            var known = new List<HostingAccount>();
            var unknown = new List<JsonElement>();
            if (json.TryGetProperty("accounts", out var saved) && saved.ValueKind != JsonValueKind.Null)
            {
                if (saved.ValueKind != JsonValueKind.Array)
                {
                    throw new JsonException("A profile's accounts are an array.");
                }

                foreach (var entry in saved.EnumerateArray())
                {
                    if (TryReadAccount(entry, options) is { } account)
                    {
                        known.Add(account);
                    }
                    else
                    {
                        unknown.Add(entry.Clone());
                    }
                }
            }
            else if (json.TryGetProperty("github", out var legacy) && legacy.ValueKind != JsonValueKind.Null)
            {
                var github = Required<LegacyGitHubAccount>(legacy, options);
                known.Add(new HostingAccount(HostingKind.GitHub, github.Host, github.Login));
            }

            return new Profile(
                Required<string>(json, "name", options),
                Required<string>(json, "color", options),
                Required<ProfileIdentity>(json, "identity", options),
                Required<ProfileSigning>(json, "signing", options),
                Required<bool>(json, "signByDefault", options),
                Required<ProfileSshKey>(json, "ssh", options),
                Required<Guid>(json, "id", options))
            {
                Accounts = known,
                UnknownAccounts = unknown,
            };
        }

        public override void Write(Utf8JsonWriter writer, Profile value, JsonSerializerOptions options)
        {
            writer.WriteStartObject();
            Write(writer, "id", value.Id, options);
            Write(writer, "name", value.Name, options);
            Write(writer, "color", value.Color, options);
            Write(writer, "identity", value.Identity, options);
            Write(writer, "signing", value.Signing, options);
            Write(writer, "signByDefault", value.SignByDefault, options);
            Write(writer, "ssh", value.Ssh, options);
            // No `accounts` key without accounts: such a profile is saved as before.
            if (value.Accounts.Count > 0 || value.UnknownAccounts.Count > 0)
            {
                writer.WriteStartArray("accounts");
                foreach (var account in value.Accounts)
                {
                    JsonSerializer.Serialize(writer, account, options);
                }

                foreach (var raw in value.UnknownAccounts)
                {
                    raw.WriteTo(writer);
                }

                writer.WriteEndArray();
            }

            if (value.Accounts.FirstOrDefault(account => account.Kind == HostingKind.GitHub) is { } github)
            {
                Write(writer, "github", new LegacyGitHubAccount(github.Host, github.Login), options);
            }

            writer.WriteEndObject();
        }

        /// <summary>The account <paramref name="entry"/> holds, or null when this build cannot read it.</summary>
        private static HostingAccount? TryReadAccount(JsonElement entry, JsonSerializerOptions options)
        {
            try
            {
                return entry.Deserialize<HostingAccount>(options);
            }
            catch (JsonException)
            {
                return null;
            }
        }

        private static T Required<T>(JsonElement json, string key, JsonSerializerOptions options) =>
            json.TryGetProperty(key, out var value)
                ? Required<T>(value, options)
                : throw new JsonException($"A profile needs the key \"{key}\".");

        private static T Required<T>(JsonElement value, JsonSerializerOptions options) =>
            value.Deserialize<T>(options) ?? throw new JsonException($"A {typeof(T).Name} in a profile is null.");

        private static void Write<T>(Utf8JsonWriter writer, string key, T value, JsonSerializerOptions options)
        {
            writer.WritePropertyName(key);
            JsonSerializer.Serialize(writer, value, options);
        }
    }

    /// <summary>The legacy <c>github</c> key: one GitHub account, as builds without <c>accounts</c> saved it.</summary>
    private sealed record LegacyGitHubAccount(
        [property: JsonPropertyName("host")] string Host,
        [property: JsonPropertyName("login")] string Login);
}
