using System.Text.Json;
using OpenMusic.Sync.Convex;
using static OpenMusic.Sync.Tests.TestUtil;

namespace OpenMusic.Sync.Tests;

/// <summary>No exception message (or detail) ever carries what the server echoed back: tokens, keys, sealed text.</summary>
public class ServerTextTests
{
    private const string DeviceToken = "dtk_9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddccbbaa";
    private const string Jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1c2VyXzEyMyJ9.c2lnbmF0dXJlLXNpZ25hdHVyZQ";

    /// <summary>What Convex sends for a call whose arguments don't match the validator (the shape of a real one).</summary>
    private static readonly string ValidationError =
        "[Request ID: 3c1f0a9e2b7d4c55] Server Error\n" +
        "ArgumentValidationError: Object contains extra field `extra` that is not in the validator.\n\n" +
        $"Object: {{deviceToken: \"{DeviceToken}\", extra: 1, publicKey: \"QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo0NTY3ODk=\"}}\n" +
        "Validator: v.object({deviceToken: v.string(), publicKey: v.string()})";

    [Fact]
    public void CleanKeepsTheErrorAndDropsTheEcho()
    {
        var cleaned = ServerText.Clean(ValidationError);
        Assert.Contains("ArgumentValidationError: Object contains extra field `extra`", cleaned);
        Assert.DoesNotContain(DeviceToken, cleaned);
        Assert.DoesNotContain("Validator:", cleaned);
        Assert.DoesNotContain("QUJDREVG", cleaned);
    }

    [Theory]
    [InlineData("deviceToken: \"" + DeviceToken + "\" is not valid", "deviceToken: <redacted> is not valid")]
    [InlineData("Bad token " + Jwt + " here", "Bad token <redacted> here")]
    [InlineData("{\"sealed\":\"v1.abc\",\"keyId\":\"k1\"}", "{\"sealed\":<redacted>,\"keyId\":\"k1\"}")]
    [InlineData("No such device in this library.", "No such device in this library.")]
    public void CleanRedactsValuesInsideTheMessage(string text, string expected) => Assert.Equal(expected, ServerText.Clean(text));

    [Fact]
    public async Task AFailedMutationNeverCarriesTheEchoedToken()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        var socket = transport.Sockets[0];
        socket.Open();
        var failing = client.MutationAsync("devices:heartbeat", ConvexValue.Object(("deviceToken", ConvexValue.String(DeviceToken))));
        Assert.True(await Eventually(() => socket.MessagesOfType("Mutation").Count == 1));
        socket.Receive($"{{\"type\":\"MutationResponse\",\"requestId\":0,\"success\":false,\"result\":{JsonSerializer.Serialize(ValidationError)},\"logLines\":[]}}");
        var error = await Assert.ThrowsAsync<ConvexClientException>(() => failing);
        Assert.DoesNotContain(DeviceToken, error.Message);
        Assert.DoesNotContain(DeviceToken, error.Detail);
        Assert.DoesNotContain(DeviceToken, error.ToString());
        Assert.StartsWith("[Request ID", error.Message);
        var shown = SyncException.From(error);
        Assert.DoesNotContain(DeviceToken, shown.Message);
        Assert.DoesNotContain(DeviceToken, shown.Detail ?? "");
        client.Stop();
    }

    [Fact]
    public void SyncExceptionDetailsAreCleanedToo()
    {
        var e = SyncException.Server(ValidationError);
        Assert.DoesNotContain(DeviceToken, e.Message);
        Assert.DoesNotContain(DeviceToken, e.Detail!);
        Assert.Equal(SyncException.CommandFailed("Leo's Mac couldn't take over."), SyncException.CommandFailed("Leo's Mac couldn't take over."));
        Assert.Equal("Leo's Mac couldn't take over.", SyncException.CommandFailed("Leo's Mac couldn't take over.").Detail);
    }
}
