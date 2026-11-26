// The JSON shape of Profile matches the Mac's profiles.json key for key: the legacy file of ProfileStoreTests.swift
// (one `github` object per profile) reads, and writes back with `accounts` plus `github`, Swift's enum objects, an upper
// case id and raw slashes; an account of an unknown kind survives a load and a save.
using System.Text;
using System.Text.Json;

namespace Histq.Core.Tests;

public sealed class ProfileJsonTests
{
    // The profiles of `legacyFile` in ProfileStoreTests.swift at 6fa6d40, Work's id lower-cased (UUIDs read in either case).
    private const string LegacyProfiles = """
        [
          {
            "color" : "#E5B13A",
            "github" : { "host" : "GHE.example.com:8443", "login" : "octo" },
            "id" : "6F1C2B0E-3D4A-4E5F-8A9B-0C1D2E3F4A5B",
            "identity" : { "email" : "me@histq.invalid", "name" : "Me" },
            "name" : "Personal",
            "signByDefault" : true,
            "signing" : { "gpg" : { "keyID" : "ABCDEF" } },
            "ssh" : { "keyFile" : { "path" : "/Users/me/.ssh/id_ed25519" } }
          },
          {
            "color" : "#3A8EE5",
            "id" : "7a2d3c1f-4e5b-4f60-9bac-1d2e3f4a5b6c",
            "identity" : { "email" : "me@work.invalid", "name" : "Me" },
            "name" : "Work",
            "signByDefault" : false,
            "signing" : { "none" : {} },
            "ssh" : { "agent" : {} }
          }
        ]
        """;

    // A legacy file reads as before, the github object as one GitHub account, and writes back in the Mac's shapes.
    [Fact]
    public void LegacyProfilesReadAndWriteBackInSwiftShapes()
    {
        var profiles = SwiftJson.Deserialize<List<Profile>>(Encoding.UTF8.GetBytes(LegacyProfiles));

        var personal = profiles[0];
        Assert.Equal([new HostingAccount(HostingKind.GitHub, "GHE.example.com:8443", "octo")], personal.Accounts);
        Assert.Equal(new ProfileSigning.Gpg("ABCDEF"), personal.Signing);
        Assert.True(personal.SignByDefault);
        Assert.Equal(new ProfileSshKey.KeyFile("/Users/me/.ssh/id_ed25519"), personal.Ssh);
        Assert.Equal(new ProfileIdentity("Me", "me@histq.invalid"), personal.Identity);
        var work = profiles[1];
        Assert.Empty(work.Accounts);
        Assert.Equal(new ProfileSshKey.Agent(), work.Ssh);
        Assert.Equal(new ProfileSigning.None(), work.Signing);
        Assert.Equal(Guid.Parse("7A2D3C1F-4E5B-4F60-9BAC-1D2E3F4A5B6C"), work.Id);

        var text = Encoding.UTF8.GetString(SwiftJson.Serialize(profiles, SwiftJsonFormatting.PrettyPrinted | SwiftJsonFormatting.SortedKeys));
        Assert.Contains("\"path\": \"/Users/me/.ssh/id_ed25519\"", text, StringComparison.Ordinal);
        Assert.DoesNotContain("\r", text, StringComparison.Ordinal);
        using var saved = JsonDocument.Parse(text);
        var savedPersonal = saved.RootElement[0];
        Assert.Equal(
            ["accounts", "color", "github", "id", "identity", "name", "signByDefault", "signing", "ssh"],
            savedPersonal.EnumerateObject().Select(property => property.Name));
        Assert.Equal(
            """[{"host":"GHE.example.com:8443","kind":"github","login":"octo"}]""",
            Compact(savedPersonal.GetProperty("accounts")));
        Assert.Equal("""{"host":"GHE.example.com:8443","login":"octo"}""", Compact(savedPersonal.GetProperty("github")));
        Assert.Equal("""{"gpg":{"keyID":"ABCDEF"}}""", Compact(savedPersonal.GetProperty("signing")));
        var savedWork = saved.RootElement[1];
        Assert.False(savedWork.TryGetProperty("accounts", out _));
        Assert.False(savedWork.TryGetProperty("github", out _));
        Assert.Equal("7A2D3C1F-4E5B-4F60-9BAC-1D2E3F4A5B6C", savedWork.GetProperty("id").GetString());
        Assert.Equal("""{"none":{}}""", Compact(savedWork.GetProperty("signing")));
        Assert.Equal("""{"agent":{}}""", Compact(savedWork.GetProperty("ssh")));
        Assert.Equal(profiles, SwiftJson.Deserialize<List<Profile>>(Encoding.UTF8.GetBytes(text)));
    }

    // An account of an unknown kind is kept as it was through a load, a change and a save.
    [Fact]
    public void UnknownAccountKindRoundTrips()
    {
        const string unknown = """{"kind":"newhost","host":"code.example.com","login":"me","extra":{"n":[1,2.5,true,null,"x"]}}""";
        var json = $$$"""
            {"color":"#E5B13A","id":"6F1C2B0E-3D4A-4E5F-8A9B-0C1D2E3F4A5B","identity":{"email":"e","name":"n"},
             "name":"P","signByDefault":false,"signing":{"none":{}},"ssh":{"agent":{}},"accounts":[{{{unknown}}}]}
            """;
        var profile = SwiftJson.Deserialize<Profile>(Encoding.UTF8.GetBytes(json));
        Assert.Empty(profile.Accounts);

        var changed = profile.WithAccount(new HostingAccount(HostingKind.GitHub, "github.com", "octo"));
        using var saved = JsonDocument.Parse(SwiftJson.Serialize(changed, SwiftJsonFormatting.SortedKeys));
        var accounts = saved.RootElement.GetProperty("accounts");
        Assert.Equal(2, accounts.GetArrayLength());
        using var expected = JsonDocument.Parse(unknown);
        Assert.True(JsonElement.DeepEquals(expected.RootElement, accounts[1]));
        Assert.Equal("1", accounts[1].GetProperty("extra").GetProperty("n")[0].GetRawText());
    }

    // A null profile in the list makes the file unreadable, as Swift's [Profile] decode fails (bug regression).
    [Fact]
    public void NullProfileInListIsAnError() =>
        Assert.Throws<JsonException>(() => SwiftJson.Deserialize<List<Profile>>("[null]"u8));

    private static string Compact(JsonElement element) => Encoding.UTF8.GetString(SwiftJson.Write(element, SwiftJsonFormatting.SortedKeys));
}
