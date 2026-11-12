using System.Text;
using Medley.Core;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.Sync;
using Xunit;

namespace Medley.Providers.YouTube.Tests;

public class CredentialTests
{
    [Fact]
    public void ParsesCookieHeader()
    {
        var creds = YouTubeMusicCredentials.FromCookieHeader("cookie: SID=sid1; HSID=h; SAPISID=SAPISIDVALUE; __Secure-3PAPISID=P3VALUE; PREF=\"f6=40000000\"")!;
        Assert.Equal("sid1", creds.Cookies["SID"]);
        Assert.Equal("f6=40000000", creds.Cookies["PREF"]);
        Assert.Equal("SAPISIDVALUE", creds.Sapisid);
        Assert.Contains("SAPISID=SAPISIDVALUE", creds.CookieHeader);
    }

    [Fact]
    public void RejectsHeaderWithoutSession()
    {
        Assert.Null(YouTubeMusicCredentials.FromCookieHeader("PREF=x; YSC=y"));
        Assert.Null(YouTubeMusicCredentials.FromCookieHeader("SAPISID=x"));
    }

    /// <summary>
    /// The same vector as the Swift test: sha1("1700000000 SAPISIDVALUE https://music.youtube.com"), computed independently
    /// (Python hashlib in the Swift suite, <c>sha1sum</c> here).
    /// </summary>
    [Fact]
    public void SapisidHashVector()
    {
        var creds = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SID"] = "s", ["SAPISID"] = "SAPISIDVALUE", ["__Secure-3PAPISID"] = "P3VALUE" });
        var auth = creds.Authorization(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000))!;
        Assert.Equal("SAPISIDHASH 1700000000_7ef7126262ab644136fc1ceef792ef2dac969ed5 SAPISID3PHASH 1700000000_af8f394de379e582818793b4e8a0649f3559ab9b", auth);

        var with1P = creds.WithCookie("__Secure-1PAPISID", "P1VALUE").Authorization(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000))!;
        Assert.Equal("SAPISIDHASH 1700000000_7ef7126262ab644136fc1ceef792ef2dac969ed5 SAPISID1PHASH 1700000000_daae9fa8c61568ce95f7b73899934b346572004f " +
                     "SAPISID3PHASH 1700000000_af8f394de379e582818793b4e8a0649f3559ab9b", with1P);

        var headers = creds.Headers();
        Assert.Equal("https://music.youtube.com", headers["X-Origin"]);
        Assert.Equal("0", headers["X-Goog-AuthUser"]);
        Assert.Contains("SID=s", headers["Cookie"]);
        Assert.False(headers.ContainsKey("X-Goog-PageId"));
    }

    /// <summary>Only __Secure-3PAPISID: it signs as SAPISID too (the web client's fallback).</summary>
    [Fact]
    public void ThirdPartySapisidStandsInForSapisid()
    {
        var creds = new YouTubeMusicCredentials(new Dictionary<string, string> { ["__Secure-3PSID"] = "s", ["__Secure-3PAPISID"] = "P3VALUE" });
        Assert.True(creds.IsUsable);
        var auth = creds.Authorization(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000))!;
        Assert.StartsWith("SAPISIDHASH 1700000000_af8f394de379e582818793b4e8a0649f3559ab9b SAPISID3PHASH", auth);
    }

    [Fact]
    public void BrandChannelHeaders()
    {
        var brand = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SID"] = "s", ["SAPISID"] = "a" }, 2, "brand123||user456");
        Assert.Equal("brand123", brand.DelegatedSessionId);
        Assert.Equal("brand123", brand.Headers()["X-Goog-PageId"]);
        Assert.Equal("2", brand.Headers()["X-Goog-AuthUser"]);
        // A personal account's datasync id names no channel.
        Assert.Null(YouTubeMusicCredentials.DelegatedSessionIdOf("||user456"));
        Assert.Null(YouTubeMusicCredentials.DelegatedSessionIdOf("user456||"));
        Assert.Null(YouTubeMusicCredentials.DelegatedSessionIdOf("user456"));
    }

    [Fact]
    public void MergesRotatedCookies()
    {
        var creds = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SID"] = "s", ["SAPISID"] = "a", ["__Secure-1PSIDTS"] = "old", ["GONE"] = "x" });
        var url = new Uri("https://music.youtube.com/youtubei/v1/browse");
        var merged = creds.Merge(
        [
            "__Secure-1PSIDTS=new; Domain=.youtube.com; Path=/; Secure; HttpOnly",
            "GONE=; Domain=.youtube.com; Expires=Thu, 01 Jan 1970 00:00:01 GMT",
            "OTHER=1; Domain=.google.com; Path=/",
            "HOSTONLY=2; Path=/",
        ], url)!;
        Assert.Equal("new", merged.Cookies["__Secure-1PSIDTS"]);
        Assert.False(merged.Cookies.ContainsKey("GONE"));
        Assert.False(merged.Cookies.ContainsKey("OTHER"));
        Assert.Equal("2", merged.Cookies["HOSTONLY"]); // no Domain: the request's host, music.youtube.com
        Assert.Null(merged.Merge(["__Secure-1PSIDTS=new; Domain=.youtube.com"], url)); // nothing changed
        Assert.Equal("old", creds.Cookies["__Secure-1PSIDTS"]); // immutable
    }

    [Fact]
    public void MaxAgeZeroDeletes()
    {
        var creds = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SID"] = "s", ["SAPISID"] = "a", ["SIDCC"] = "c" });
        var merged = creds.Merge(["SIDCC=c2; Max-Age=0; Domain=.youtube.com"], new Uri("https://music.youtube.com/"))!;
        Assert.False(merged.Cookies.ContainsKey("SIDCC"));
    }

    /// <summary>The Swift Codable shape both ways; a missing authUser reads as 0.</summary>
    [Fact]
    public void JsonRoundTrip()
    {
        var creds = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SID"] = "s/1", ["SAPISID"] = "a" }, 1, "b||u");
        Assert.Equal("{\"authUser\":1,\"cookies\":{\"SAPISID\":\"a\",\"SID\":\"s\\/1\"},\"datasyncId\":\"b||u\"}", creds.ToJson());
        Assert.Equal(creds, YouTubeMusicCredentials.FromJson(creds.ToJson()));
        var old = YouTubeMusicCredentials.FromJson("{\"cookies\":{\"SID\":\"s\",\"SAPISID\":\"a\"}}");
        Assert.Equal(0, old.AuthUser);
        Assert.Null(old.DatasyncId);
        Assert.Throws<FormatException>(() => YouTubeMusicCredentials.FromJson("{\"authUser\":0}"));
    }

    [Fact]
    public void ToStringRedactsCookies()
    {
        var creds = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SID"] = "secret-sid", ["SAPISID"] = "secret-sapisid" });
        Assert.DoesNotContain("secret", creds.ToString());
        Assert.DoesNotContain("secret", new YouTubeMusicSignInPayload(creds, null).ToString());
    }

    [Fact]
    public void WebCookiesBecomeCredentials()
    {
        var jar = new List<WebCookie>
        {
            new("SAPISID", "a", ".youtube.com"), new("SID", "s", ".youtube.com"), new("HSID", "h", ".youtube.com"),
            new("NID", "n", ".google.com"), new("YSC", "y", "music.youtube.com"),
        };
        var creds = WebSignIn.CredentialsFromCookies(jar)!;
        Assert.Equal(["HSID", "SAPISID", "SID", "YSC"], creds.Cookies.Keys);
        Assert.Null(WebSignIn.CredentialsFromCookies([new WebCookie("YSC", "y", ".youtube.com")]));
        Assert.True(WebSignIn.IsLanding(new Uri("https://music.youtube.com/")));
        Assert.False(WebSignIn.IsLanding(new Uri("https://accounts.google.com/ServiceLogin")));
        // The Swift app's sign-in URL, encoded the way URLComponents does.
        Assert.Equal("https://accounts.google.com/AccountChooser?service=youtube&continue=https://www.youtube.com/signin?action_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps://music.youtube.com/&hl=en",
            WebSignIn.StartUrl.OriginalString);
    }

    [Fact]
    public void ProtectedFileStoreRoundTrips()
    {
        var dir = Directory.CreateTempSubdirectory("ytm-store-").FullName;
        try
        {
            var store = new ProtectedFileCredentialStore(dir, new XorProtector());
            var creds = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SID"] = "s", ["SAPISID"] = "a" }, 0, "b||u");
            store.SaveCredentials(creds);
            store.SaveAccount(new AccountInfo("Ada", new Uri("https://yt3.ggpht.com/x=s88"), "@ada", "datasync:b||u"));
            var again = new ProtectedFileCredentialStore(dir, new XorProtector());
            Assert.Equal(creds, again.LoadCredentials());
            Assert.Equal(new AccountInfo("Ada", new Uri("https://yt3.ggpht.com/x=s88"), "@ada", "datasync:b||u"), again.LoadAccount());
            // On disk it's the protector's output, not the cookies.
            Assert.DoesNotContain("SAPISID", Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(dir, ProtectedFileCredentialStore.CredentialsFile))));
            again.ClearCredentials();
            Assert.Null(store.LoadCredentials());
            Assert.Null(store.LoadAccount());
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    sealed class XorProtector : ISecretProtector
    {
        public byte[] Protect(byte[] plaintext) => plaintext.Select(b => (byte)(b ^ 0x5A)).ToArray();
        public byte[] Unprotect(byte[] ciphertext) => Protect(ciphertext);
    }
}

/// <summary>The sign-in payload against the Swift encoder's own output (macOS 27, tools/swift-transfer-encoder.swift).</summary>
public class TransferFormatTests
{
    [Theory]
    [InlineData("transfer_swift_full.json")]
    [InlineData("transfer_swift_minimal.json")]
    [InlineData("transfer_swift_datasync.json")]
    public void DecodesAndReencodesTheSwiftBytesExactly(string fixture)
    {
        var swift = Fixture.Bytes(fixture);
        var payload = YouTubeMusicSignInPayload.Decode(swift);
        Assert.Equal(1, payload.Version);
        Assert.Equal(swift, payload.Encode());
    }

    [Fact]
    public void FullPayloadFields()
    {
        var p = YouTubeMusicSignInPayload.Decode(Fixture.Bytes("transfer_swift_full.json"));
        Assert.Equal(1, p.Credentials.AuthUser);
        Assert.Equal("brandABC||userXYZ", p.Credentials.DatasyncId);
        Assert.Equal("brandABC", p.Credentials.DelegatedSessionId);
        Assert.Equal("AbCdEfGh/IjKlMn-OpQ", p.Credentials.Cookies["SAPISID"]);
        Assert.Equal("f6=40000000&tz=Europe.Paris", p.Credentials.Cookies["PREF"]);
        Assert.Equal("he said \"hi\" \\ back\tslash\n\u0001\u007fé🎵\u2028<>&'", p.Credentials.Cookies["quote"]);
        Assert.Equal(new AccountInfo("Zoë \"DJ\" Ünïcode 🎧", new Uri("https://yt3.ggpht.com/abc/def=s88-c-k-c0x00ffffff-no-rj"), "@zoe_dj"), p.Account);

        var minimal = YouTubeMusicSignInPayload.Decode(Fixture.Bytes("transfer_swift_minimal.json"));
        Assert.Null(minimal.Account);
        Assert.Null(minimal.Credentials.DatasyncId);
        Assert.Equal("datasync:||user", YouTubeMusicSignInPayload.Decode(Fixture.Bytes("transfer_swift_datasync.json")).Account?.Id);
    }

    /// <summary>Built here from the same values, the bytes equal what a Mac sends.</summary>
    [Fact]
    public void EncodesWhatTheMacEncodes()
    {
        var full = YouTubeMusicSignInPayload.Decode(Fixture.Bytes("transfer_swift_full.json"));
        var rebuilt = new YouTubeMusicSignInPayload(
            new YouTubeMusicCredentials(full.Credentials.Cookies.Reverse(), full.Credentials.AuthUser, full.Credentials.DatasyncId), full.Account);
        Assert.Equal(Fixture.Bytes("transfer_swift_full.json"), rebuilt.Encode());
        var minimal = new YouTubeMusicSignInPayload(new YouTubeMusicCredentials(new Dictionary<string, string> { ["SID"] = "i", ["SAPISID"] = "s" }), null);
        Assert.Equal(Fixture.Bytes("transfer_swift_minimal.json"), minimal.Encode());
        var datasync = new YouTubeMusicSignInPayload(new YouTubeMusicCredentials(new Dictionary<string, string> { ["SAPISID"] = "s", ["SID"] = "i" }, 0, "||user"),
            new AccountInfo("Ada", id: "datasync:||user"));
        Assert.Equal(Fixture.Bytes("transfer_swift_datasync.json"), datasync.Encode());
    }

    [Fact]
    public void EscapesControlCharactersLikeSwift()
    {
        var node = new System.Text.Json.Nodes.JsonObject { ["a"] = "b\bf\fx\u001fy\u001b" };
        Assert.Equal(Fixture.Text("swift_escapes.json"), Medley.Providers.YouTube.Json.SwiftJson.Serialize(node));
    }

    [Fact]
    public void RejectsOtherVersionsAndGarbage()
    {
        Assert.Throws<FormatException>(() => YouTubeMusicSignInPayload.Decode("refresh-1"u8));
        Assert.Throws<FormatException>(() => YouTubeMusicSignInPayload.Decode("{\"version\":2,\"credentials\":{\"authUser\":0,\"cookies\":{}}}"u8));
        Assert.Throws<FormatException>(() => YouTubeMusicSignInPayload.Decode("{\"credentials\":{\"authUser\":0,\"cookies\":{}}}"u8));
    }
}
