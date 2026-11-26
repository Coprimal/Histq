// JSON that reads and writes what Swift's JSONEncoder and JSONDecoder do, so the state files (profiles.json,
// session.json, .histqws, repo view, AI chat, undo journal) mean the same on both systems. Swift's rules mirrored here:
// a nil optional is left out (not null); a missing or null non-optional property or parameter, or a null top-level
// value, is an error; an enum with associated values is `{"case":{"label":value}}` (unlabeled values `_0`, `_1`), one
// without is `{"case":{}}`; a String raw-value enum is its raw string, matched exactly; a UUID is upper case
// (`uuidString`) and read in either case; a Date is a double of seconds since 2001-01-01 by default, or ISO 8601 without
// fractions (`.iso8601`). Sorted keys follow Unicode scalar order, as Swift's `.sortedKeys` does. Null elements of a
// collection are rejected only for types whose converter handles null (SwiftEnumConverter, Profile's): elements of
// other types are not checked. Those converters also reject an explicit null for an optional property of their type,
// where Swift reads nil; an omitted key is still absent, and Swift never writes that null. Formatting differs from Swift's (`"key": value`, not `"key" : value`; empty
// containers on one line; `/` never escaped, as `.withoutEscapingSlashes`; DEL, U+2028/U+2029, U+FFFF and characters above
// it escaped as \uXXXX where Swift writes them raw), which JSON readers do not see. Porting a Codable type: a
// non-optional field is a constructor parameter without a default (or a `required` property), an optional one a
// nullable parameter with `= null` (or a nullable property): with these options a nullable parameter without a default
// is required, as no Swift optional is.
using System.Globalization;
using System.Reflection;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Histq.Core;

/// <summary>How <see cref="SwiftJson.Serialize{T}"/> lays the JSON out, as Swift's <c>JSONEncoder.OutputFormatting</c>.</summary>
[Flags]
public enum SwiftJsonFormatting
{
    /// <summary>Compact, keys in the order the type writes them (Swift's default encoder).</summary>
    None = 0,

    /// <summary>Indented by two spaces, LF line ends on every OS.</summary>
    PrettyPrinted = 1,

    /// <summary>Every object's keys in Unicode scalar order, dictionary keys too.</summary>
    SortedKeys = 2,
}

/// <summary>Serializer options and a writer that match Swift's JSONEncoder and JSONDecoder.</summary>
public static class SwiftJson
{
    /// <summary>Escapes only what JSON requires; most non-ASCII text and <c>/</c> are written as they are, as Swift does.
    /// Declared before the options, which read it in their static initializers.</summary>
    private static readonly JavaScriptEncoder Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping;

    /// <summary>Swift's default coding: dates as seconds since 2001-01-01.</summary>
    public static JsonSerializerOptions Options { get; } = CreateOptions(new SwiftReferenceDateConverter());

    /// <summary>Swift's coding with <c>dateEncodingStrategy = .iso8601</c> (the undo journal).</summary>
    public static JsonSerializerOptions Iso8601Options { get; } = CreateOptions(new SwiftIso8601DateConverter());

    /// <summary><paramref name="value"/> as UTF-8 JSON, laid out as <paramref name="formatting"/> says.</summary>
    public static byte[] Serialize<T>(T value, SwiftJsonFormatting formatting, JsonSerializerOptions? options = null)
    {
        var element = JsonSerializer.SerializeToElement(value, options ?? Options);
        return Write(element, formatting);
    }

    /// <summary>The value <paramref name="utf8"/> holds. Throws <see cref="JsonException"/> when it is not one, or null.</summary>
    public static T Deserialize<T>(ReadOnlySpan<byte> utf8, JsonSerializerOptions? options = null) =>
        JsonSerializer.Deserialize<T>(utf8, options ?? Options) ?? throw new JsonException($"Expected a {typeof(T).Name}, got null.");

    /// <summary><paramref name="element"/> as UTF-8 JSON, laid out as <paramref name="formatting"/> says.</summary>
    public static byte[] Write(JsonElement element, SwiftJsonFormatting formatting)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
               {
                   Indented = formatting.HasFlag(SwiftJsonFormatting.PrettyPrinted),
                   NewLine = "\n",
                   Encoder = Encoder,
               }))
        {
            WriteElement(writer, element, formatting.HasFlag(SwiftJsonFormatting.SortedKeys));
        }

        return stream.ToArray();
    }

    /// <summary>Orders strings by Unicode scalar values (UTF-8 byte order), as Swift sorts keys; UTF-16 order differs
    /// when a character above U+FFFF meets one in U+E000-U+FFFF.</summary>
    public static int CompareScalars(string a, string b)
    {
        var left = a.EnumerateRunes();
        var right = b.EnumerateRunes();
        while (true)
        {
            var hasLeft = left.MoveNext();
            var hasRight = right.MoveNext();
            if (!hasLeft || !hasRight)
            {
                return hasLeft.CompareTo(hasRight);
            }

            var order = left.Current.Value.CompareTo(right.Current.Value);
            if (order != 0)
            {
                return order;
            }
        }
    }

    private static JsonSerializerOptions CreateOptions(JsonConverter dates)
    {
        var options = new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            RespectNullableAnnotations = true,
            RespectRequiredConstructorParameters = true,
            Encoder = Encoder,
        };
        options.Converters.Add(new SwiftUuidConverter());
        options.Converters.Add(dates);
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }

    private static void WriteElement(Utf8JsonWriter writer, JsonElement element, bool sortedKeys)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                IEnumerable<JsonProperty> properties = element.EnumerateObject();
                if (sortedKeys)
                {
                    properties = properties.OrderBy(property => property.Name, Comparer<string>.Create(CompareScalars));
                }

                foreach (var property in properties)
                {
                    writer.WritePropertyName(property.Name);
                    WriteElement(writer, property.Value, sortedKeys);
                }

                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray())
                {
                    WriteElement(writer, item, sortedKeys);
                }

                writer.WriteEndArray();
                break;
            case JsonValueKind.Number:
                // As serialized (no reformatting), with Swift's lower-case exponent: 1e-07, not 1E-07.
                writer.WriteRawValue(element.GetRawText().Replace('E', 'e'), skipInputValidation: true);
                break;
            default:
                element.WriteTo(writer);
                break;
        }
    }
}

/// <summary>Names the case of a Swift enum with associated values that a nested record of the enum stands for.</summary>
[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class SwiftEnumCaseAttribute(string name) : Attribute
{
    public string Name { get; } = name;
}

/// <summary>
/// A Swift enum with associated values, as its synthesized Codable writes it: <c>{"gpg":{"keyID":"ABC"}}</c>, or
/// <c>{"none":{}}</c> for a case without values. <typeparamref name="T"/> is an abstract record whose nested sealed
/// records, each marked <see cref="SwiftEnumCaseAttribute"/>, are the cases; their properties are the labels
/// (<c>_0</c>, <c>_1</c> for unlabeled values). Reading needs an object with exactly one known case key.
/// </summary>
public sealed class SwiftEnumConverter<T> : JsonConverter<T>
    where T : class
{
    private static readonly (string Name, Type Type)[] Cases = typeof(T)
        .GetNestedTypes(BindingFlags.Public | BindingFlags.NonPublic)
        .Where(type => type.IsSubclassOf(typeof(T)))
        .Select(type => (type.GetCustomAttribute<SwiftEnumCaseAttribute>()?.Name
            ?? throw new InvalidOperationException($"{type.Name} has no SwiftEnumCase attribute."), type))
        .ToArray();

    /// <summary>Null reaches <see cref="Read"/>, which rejects it: a null element of <c>[T]</c> is an error, as in Swift.</summary>
    public override bool HandleNull => true;

    public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartObject || !reader.Read() || reader.TokenType != JsonTokenType.PropertyName)
        {
            throw new JsonException($"A {typeof(T).Name} is an object with one case key.");
        }

        var name = reader.GetString();
        var type = Cases.FirstOrDefault(entry => string.Equals(entry.Name, name, StringComparison.Ordinal)).Type
            ?? throw new JsonException($"\"{name}\" is not a case of {typeof(T).Name}.");
        reader.Read();
        var value = JsonSerializer.Deserialize(ref reader, type, options) as T
            ?? throw new JsonException($"The case \"{name}\" of {typeof(T).Name} needs an object.");
        if (!reader.Read() || reader.TokenType != JsonTokenType.EndObject)
        {
            throw new JsonException($"A {typeof(T).Name} has exactly one case key.");
        }

        return value;
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
    {
        var type = value.GetType();
        var name = Cases.FirstOrDefault(entry => entry.Type == type).Name
            ?? throw new JsonException($"{type.Name} is not a case of {typeof(T).Name}.");
        writer.WriteStartObject();
        writer.WritePropertyName(name);
        JsonSerializer.Serialize(writer, value, type, options);
        writer.WriteEndObject();
    }
}

/// <summary>
/// A Swift <c>String</c> raw-value enum: the raw string, from <see cref="JsonStringEnumMemberNameAttribute"/> (else
/// the member name), matched exactly. Numbers and other spellings are errors, as in Swift.
/// </summary>
public sealed class SwiftRawEnumConverter<TEnum> : JsonConverter<TEnum>
    where TEnum : struct, Enum
{
    private static readonly (string Raw, TEnum Value)[] Members = typeof(TEnum)
        .GetFields(BindingFlags.Public | BindingFlags.Static)
        .Select(field => (field.GetCustomAttribute<JsonStringEnumMemberNameAttribute>()?.Name ?? field.Name, (TEnum)field.GetValue(null)!))
        .ToArray();

    public override TEnum Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException($"A {typeof(TEnum).Name} is a string.");
        }

        var raw = reader.GetString();
        foreach (var member in Members)
        {
            if (string.Equals(member.Raw, raw, StringComparison.Ordinal))
            {
                return member.Value;
            }
        }

        throw new JsonException($"\"{raw}\" is not a {typeof(TEnum).Name}.");
    }

    public override void Write(Utf8JsonWriter writer, TEnum value, JsonSerializerOptions options)
    {
        foreach (var member in Members)
        {
            if (EqualityComparer<TEnum>.Default.Equals(member.Value, value))
            {
                writer.WriteStringValue(member.Raw);
                return;
            }
        }

        throw new JsonException($"{value} has no raw value in {typeof(TEnum).Name}.");
    }
}

/// <summary>A UUID as Swift's <c>uuidString</c>: upper case, hyphenated; read in either case.</summary>
public sealed class SwiftUuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String || !Guid.TryParseExact(reader.GetString(), "D", out var value))
        {
            throw new JsonException("A UUID is a hyphenated string of 36 characters.");
        }

        return value;
    }

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// <summary>A Date as Swift's default strategy: a double of seconds since 2001-01-01 00:00 UTC.</summary>
public sealed class SwiftReferenceDateConverter : JsonConverter<DateTimeOffset>
{
    /// <summary>Swift's reference date (<c>Date(timeIntervalSinceReferenceDate: 0)</c>).</summary>
    public static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.Number)
        {
            throw new JsonException("A date is a number of seconds since 2001-01-01.");
        }

        try
        {
            return ReferenceDate.AddTicks(checked((long)Math.Round(reader.GetDouble() * TimeSpan.TicksPerSecond)));
        }
        catch (Exception error) when (error is OverflowException or ArgumentOutOfRangeException)
        {
            throw new JsonException("The date is out of range.", error);
        }
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue((value - ReferenceDate).Ticks / (double)TimeSpan.TicksPerSecond);
}

/// <summary>
/// A Date as Swift's <c>.iso8601</c> strategy: <c>2001-01-01T00:00:03Z</c> in UTC, whole seconds (fractions dropped,
/// as Swift drops them); read with <c>Z</c> or an offset, never with fractions.
/// </summary>
public sealed class SwiftIso8601DateConverter : JsonConverter<DateTimeOffset>
{
    private static readonly string[] Formats = ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:sszzz"];

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String
            || !DateTimeOffset.TryParseExact(reader.GetString(), Formats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value))
        {
            throw new JsonException("A date is an ISO 8601 string such as 2001-01-01T00:00:00Z.");
        }

        return value;
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
}
