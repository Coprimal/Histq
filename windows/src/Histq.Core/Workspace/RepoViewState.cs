// The graph's per-worktree view: hidden branches and tags, soloed and pinned branches and the "hide stale branches"
// switch. The app saves it as JSON in `repo-view/<stateKey>.json` (never in `.git`); a workspace file embeds it per
// repo. A missing or null field reads as its default, so a file of an older build still loads; all four keys are
// always written. Ported from RepoViewState.swift at 6fa6d40.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Histq.Core;

[JsonConverter(typeof(RepoViewStateJsonConverter))]
public sealed record RepoViewState(
    IReadOnlyList<string>? Hidden = null, IReadOnlyList<string>? Solo = null, IReadOnlyList<string>? Pinned = null,
    bool HideStale = false)
{
    public static RepoViewState Empty { get; } = new();

    /// <summary>Full ref names (<c>refs/heads/x</c>, <c>refs/remotes/o/x</c>); also tags (<c>refs/tags/v1</c>).</summary>
    public IReadOnlyList<string> Hidden { get; init; } = Hidden ?? [];

    public IReadOnlyList<string> Solo { get; init; } = Solo ?? [];

    public IReadOnlyList<string> Pinned { get; init; } = Pinned ?? [];

    public bool Equals(RepoViewState? other) =>
        other is not null && Hidden.SequenceEqual(other.Hidden) && Solo.SequenceEqual(other.Solo)
        && Pinned.SequenceEqual(other.Pinned) && HideStale == other.HideStale;

    public override int GetHashCode() => HashCode.Combine(Hidden.Count, Solo.Count, Pinned.Count, HideStale);

    /// <summary>Reads each field leniently (missing or null is its default, other keys are ignored) and writes all four.</summary>
    private sealed class RepoViewStateJsonConverter : JsonConverter<RepoViewState>
    {
        public override RepoViewState Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            var json = JsonElement.ParseValue(ref reader);
            if (json.ValueKind != JsonValueKind.Object)
            {
                throw new JsonException("A repo view is an object.");
            }

            return new RepoViewState(
                Names(json, "hidden", options),
                Names(json, "solo", options),
                Names(json, "pinned", options),
                Optional<bool?>(json, "hideStale", options) ?? false);
        }

        public override void Write(Utf8JsonWriter writer, RepoViewState value, JsonSerializerOptions options)
        {
            writer.WriteStartObject();
            writer.WritePropertyName("hidden");
            JsonSerializer.Serialize(writer, value.Hidden, options);
            writer.WritePropertyName("solo");
            JsonSerializer.Serialize(writer, value.Solo, options);
            writer.WritePropertyName("pinned");
            JsonSerializer.Serialize(writer, value.Pinned, options);
            writer.WriteBoolean("hideStale", value.HideStale);
            writer.WriteEndObject();
        }

        /// <summary>A list of ref names; a null element is an error, as in Swift.</summary>
        private static List<string>? Names(JsonElement json, string key, JsonSerializerOptions options)
        {
            var names = Optional<List<string?>>(json, key, options);
            if (names is null)
            {
                return null;
            }

            return names.Contains(null)
                ? throw new JsonException($"A repo view's {key} holds a null.")
                : names.OfType<string>().ToList();
        }

        private static T? Optional<T>(JsonElement json, string key, JsonSerializerOptions options) =>
            json.TryGetProperty(key, out var value) && value.ValueKind != JsonValueKind.Null
                ? value.Deserialize<T>(options)
                : default;
    }
}
