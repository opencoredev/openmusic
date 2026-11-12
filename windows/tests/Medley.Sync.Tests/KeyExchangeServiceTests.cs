using Medley.Core;
using Medley.Sync.Keys;
using static Medley.Sync.Tests.TestUtil;

namespace Medley.Sync.Tests;

/// <summary>Ports of KeyExchangeServiceTests.swift: real SyncServices through the in-memory key server, honest and not.</summary>
public class KeyExchangeServiceTests : ServiceTests
{
    [Fact]
    public async Task BothDevicesShowOneCodeAndTheKeyMovesOnlyAfterAllowThereAndConfirmHere()
    {
        var server = new FakeKeyServer();
        var spotify = new FakeSignIn(ProviderId.Spotify, "the phone's own spotify sign-in");
        var (mac, phone) = await MacAndAskingPhone(server, spotify);
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        var request = await On(mac, () => mac.KeyRequests[0]);
        var code = (await On(phone, () => Comparison(phone)))!.Code;
        Assert.Equal(code, request.Code);
        Assert.Equal("Leo's iPhone", request.Device.Name);
        Assert.Equal("Leo's Mac", (await On(phone, () => Comparison(phone)))!.HolderName);
        // The holder answered once, after the commitment; the phone revealed once, after the answer.
        Assert.Single(server.CallsTo("keys:answer", "Leo's Mac"));
        Assert.Single(server.CallsTo("keys:reveal", "Leo's iPhone"));

        await mac.AllowKeyAsync(request);
        Assert.True(await WaitUntil(phone, () => Comparison(phone)?.Allowed == true));
        // Allowed there, not confirmed here: no key, nothing uploaded.
        Assert.Null(await On(phone, () => phone.LibraryKey));
        Assert.Empty(server.CallsTo("vault:put", "Leo's iPhone"));

        phone.ConfirmKeyCode();
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available));
        Assert.Equal(await On(mac, () => mac.LibraryKey), await On(phone, () => phone.LibraryKey));
        Assert.True(await Eventually(() => server.StateOf("Leo's iPhone") is FakeKeyServer.State.Holder { Rekey: null }));
        // Only now, with a verified key, does the phone's existing sign-in go up.
        Assert.True(await Eventually(() => server.CallsTo("vault:put", "Leo's iPhone").Count == 1));
    }

    [Fact]
    public async Task ConfirmingBeforeTheHolderAllowsWorksToo()
    {
        var server = new FakeKeyServer();
        var (mac, phone) = await MacAndAskingPhone(server);
        phone.ConfirmKeyCode();
        Assert.True(await WaitUntil(phone, () => Comparison(phone)?.Confirmed == true));
        Assert.Null(await On(phone, () => phone.LibraryKey));
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        await mac.AllowKeyAsync(await On(mac, () => mac.KeyRequests[0]));
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available));
        Assert.Equal(await On(mac, () => mac.LibraryKey), await On(phone, () => phone.LibraryKey));
    }

    [Fact]
    public async Task CodesThatDontMatchEndTheAttemptAndALaterGrantIsNeverUsed()
    {
        var server = new FakeKeyServer();
        var (mac, phone) = await MacAndAskingPhone(server);
        phone.RejectKeyCode();
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Failed));
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        await mac.AllowKeyAsync(await On(mac, () => mac.KeyRequests[0]));
        await Task.Delay(300);
        Assert.Null(await On(phone, () => phone.LibraryKey));
        Assert.IsType<KeyStatus.Failed>(await On(phone, () => phone.KeyStatus));
        // Ask Again starts a new exchange with a new commitment.
        var first = server.CallsTo("keys:request", "Leo's iPhone")[^1].Args["commitment"]!.StringValue;
        await phone.RequestKeyAgainAsync();
        var second = server.CallsTo("keys:request", "Leo's iPhone")[^1].Args["commitment"]!.StringValue;
        Assert.NotEqual(first, second);
        Assert.True(await WaitUntil(phone, () => Comparison(phone) is not null));
    }

    [Fact]
    public async Task AHolderRefusesAnExchangeThatWasChangedOnTheWay()
    {
        var server = new FakeKeyServer();
        var fakeNonce = Convert.ToBase64String(KeyExchange.Nonce());
        server.Rewrite((viewer, _, e) => viewer == "Leo's Mac" && e.Nonce is not null ? e with { Nonce = fakeNonce } : e);
        var (mac, phone) = await MacAndAskingPhone(server);
        Assert.True(await Eventually(() => server.CallsTo("keys:deny", "Leo's Mac").Count == 1));
        Assert.Empty(await On(mac, () => mac.KeyRequests));
        Assert.Contains("changed on its way", await On(mac, () => mac.KeyWarning));
        Assert.Null(await On(phone, () => phone.LibraryKey));
    }

    [Fact]
    public async Task AHolderRefusesAnExchangeWhoseAnswerWasChanged()
    {
        var server = new FakeKeyServer();
        var other = Convert.ToBase64String(KeyExchange.Nonce());
        server.Rewrite((viewer, _, e) => viewer == "Leo's Mac" && e.Nonce is not null ? e with { HolderNonce = other } : e);
        var (mac, _) = await MacAndAskingPhone(server);
        Assert.True(await Eventually(() => server.CallsTo("keys:deny", "Leo's Mac").Count == 1));
        Assert.Empty(await On(mac, () => mac.KeyRequests));
    }

    [Fact]
    public async Task TheAskingDeviceKeepsTheFirstAnswerItSaw()
    {
        var server = new FakeKeyServer();
        var (_, phone) = await MacAndAskingPhone(server);
        var code = (await On(phone, () => Comparison(phone)))!.Code;
        var impostor = DeviceKeyPair.Generate().PublicKey;
        server.Rewrite((viewer, _, e) => viewer == "Leo's iPhone" ? e with { HolderKey = impostor, HolderNonce = Convert.ToBase64String(KeyExchange.Nonce()) } : e);
        await Task.Delay(300);
        Assert.Equal(code, (await On(phone, () => Comparison(phone)))?.Code);
        Assert.Single(server.CallsTo("keys:reveal", "Leo's iPhone"));
    }

    [Fact]
    public async Task AGrantTheServerMadeUpNeverOpensAndNothingIsUploaded()
    {
        var server = new FakeKeyServer();
        var spotify = new FakeSignIn(ProviderId.Spotify, "the phone's spotify");
        var (_, phone) = await MacAndAskingPhone(server, spotify);
        phone.ConfirmKeyCode();
        var row = server.DeviceNamed("Leo's iPhone")!;
        var exchange = ((FakeKeyServer.State.Requested)row.State).Exchange!;
        // The server knows every public value; it wraps its own key as "the Mac" with a key pair of its own.
        var serverPair = DeviceKeyPair.Generate();
        var serverKey = LibraryKey.Generate();
        var transcript = new KeyExchange.Transcript(new LibraryId("lib"), new DeviceId(row.Id), row.PublicKey, Convert.FromBase64String(exchange.Nonce!),
                                                    new DeviceId(exchange.Holder!), serverPair.PublicKey, Convert.FromBase64String(exchange.HolderNonce!));
        var forged = KeyExchange.Wrap(serverKey, transcript, serverPair);
        server.SetLibrary(serverKey.Id, false);
        server.SetState("Leo's iPhone", new FakeKeyServer.State.Granted(serverKey.Id, forged, exchange.Holder!, exchange.Commitment));
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Failed));
        Assert.Null(await On(phone, () => phone.LibraryKey));
        await Task.Delay(200);
        Assert.Empty(server.CallsTo("vault:put", "Leo's iPhone"));
        Assert.Empty(server.CallsTo("keys:accept", "Leo's iPhone"));
    }

    [Fact]
    public async Task AHeldKeyIsPinned()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        var spotify = new FakeSignIn(ProviderId.Spotify, "mac spotify");
        await Register(mac, spotify);
        await SignIn(mac);
        var held = (await On(mac, () => mac.LibraryKey))!;
        Assert.True(await Eventually(() => server.CallsTo("vault:put", "Leo's Mac").Count == 1));

        // A grant of another key, wrapped to the Mac: ignored.
        var other = LibraryKey.Generate();
        var macRow = server.DeviceNamed("Leo's Mac")!;
        var pair = DeviceKeyPair.Generate();
        var t = new KeyExchange.Transcript(new LibraryId("lib"), new DeviceId(macRow.Id), macRow.PublicKey, KeyExchange.Nonce(), new DeviceId("x"), pair.PublicKey, KeyExchange.Nonce());
        server.SetState("Leo's Mac", new FakeKeyServer.State.Granted(other.Id, KeyExchange.Wrap(other, t, pair), "x", "c"));
        await Task.Delay(250);
        Assert.Equal(held, await On(mac, () => mac.LibraryKey));

        // A real rotation, made with the held key, is taken.
        var next = LibraryKey.Generate();
        server.SetLibrary(next.Id, false);
        var genuine = KeyRotation.Wrap(next, held, macRow.PublicKey, new LibraryId("lib"), new DeviceId(macRow.Id));
        server.SetState("Leo's Mac", new FakeKeyServer.State.Holder(new FakeKeyServer.Rekey(next.Id, held.Id, genuine, "x")));
        Assert.True(await WaitUntil(mac, () => mac.LibraryKey == next));
        Assert.True(await WaitUntil(mac, () => mac.KeyStatus is KeyStatus.Available));

        // A "rotation" to a server key, wrapped without the held key: refused; the Mac steps down and, alone, the account
        // is reset and it claims a fresh key of its own.
        server.SetLibrary(other.Id, false);
        var forged = KeyRotation.Wrap(other, LibraryKey.Generate(), macRow.PublicKey, new LibraryId("lib"), new DeviceId(macRow.Id));
        server.SetState("Leo's Mac", new FakeKeyServer.State.Holder(new FakeKeyServer.Rekey(other.Id, next.Id, forged, "x")));
        await mac.Actor.Run(() => spotify.LocalChange("mac spotify, rotated"));
        Assert.True(await Eventually(() => server.CallsTo("keys:release", "Leo's Mac").Count > 0));
        Assert.True(await WaitUntil(mac, () => mac.KeyStatus is KeyStatus.Available && mac.LibraryKey?.Id == server.KeyId));
        var fresh = (await On(mac, () => mac.LibraryKey))!;
        Assert.True(fresh != other && fresh != next && fresh != held);
        Assert.All(server.CallsTo("vault:put", "Leo's Mac"), c => Assert.NotEqual(other.Id, c.Args["keyId"]!.StringValue));
    }

    [Fact]
    public async Task RemovingAHolderRotatesTheKeyAcrossTheRemainingHolders()
    {
        var server = new FakeKeyServer();
        var spotify = new FakeSignIn(ProviderId.Spotify, "mac spotify");
        var mac = Device(server, "Leo's Mac");
        await Register(mac, spotify);
        await SignIn(mac);
        Assert.True(await Eventually(() => server.CallsTo("vault:put", "Leo's Mac").Count == 1));
        var phone = Device(server, "Leo's iPhone");
        var phoneSpotify = new FakeSignIn(ProviderId.Spotify);
        await Register(phone, phoneSpotify);
        await SignIn(phone);
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        Assert.True(await WaitUntil(phone, () => Comparison(phone) is not null));
        await mac.AllowKeyAsync(await On(mac, () => mac.KeyRequests[0]));
        phone.ConfirmKeyCode();
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available && phoneSpotify.Text == "mac spotify"));
        var old = (await On(mac, () => mac.LibraryKey))!;
        var revision = server.Vault[0].Revision;

        // A third holder, now lost, is removed.
        server.SetLibrary(old.Id, true);
        Assert.True(await Eventually(() => server.KeyId != old.Id && server.CallsTo("keys:rotate").Any(c => c.Args["keyId"]!.StringValue == server.KeyId)));
        Assert.True(await WaitUntil(mac, () => mac.LibraryKey?.Id == server.KeyId));
        Assert.True(await WaitUntil(phone, () => phone.LibraryKey?.Id == server.KeyId));
        var row = server.Vault[0];
        Assert.Equal(revision + 1, row.Revision);
        Assert.Equal(server.KeyId, row.KeyId);
        var key = (await On(mac, () => mac.LibraryKey))!;
        Assert.Equal("mac spotify"u8.ToArray(), SignInSealing.Open(row.Sealed!, ProviderId.Spotify, row.Revision, key));
        // Sign-ins keep syncing under the new key.
        await mac.Actor.Run(() => spotify.LocalChange("mac spotify 2"));
        Assert.True(await Eventually(() => phoneSpotify.Text == "mac spotify 2"));
    }

    [Fact]
    public async Task AHolderRateLimitsAnswersAndWarnsAboutFailures()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        var clock = new ClockBox(DateTimeOffset.FromUnixTimeSeconds(1_800_000_000));
        await mac.Actor.Run(() => mac.Now = () => clock.Value);
        await SignIn(mac);
        for (var i = 0; i < 8; i++)
        {
            var other = Device(server, $"Asker {i}");
            await SignIn(other);
            var name = $"Asker {i}";
            Assert.True(await Eventually(() => server.CallsTo("keys:request", name).Count > 0));
        }
        Assert.True(await Eventually(() => server.CallsTo("keys:answer", "Leo's Mac").Count == SyncService.AnswersPerHour));
        await Task.Delay(300);
        Assert.Equal(SyncService.AnswersPerHour, server.CallsTo("keys:answer", "Leo's Mac").Count);
        Assert.Contains("paused", await On(mac, () => mac.KeyWarning));
        // An hour later the next list change (or heartbeat) answers the rest.
        clock.Value = clock.Value.AddSeconds(3601);
        var late = Device(server, "Asker 8");
        await SignIn(late);
        Assert.True(await Eventually(() => server.CallsTo("keys:answer", "Leo's Mac").Count == 9, 10_000));
    }

    [Fact]
    public async Task AServerReplyingConflictGetsOneNoncePerCommitmentAndNoMoreAnswersThanTheLimit()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        var clock = new ClockBox(DateTimeOffset.FromUnixTimeSeconds(1_800_000_000));
        await mac.Actor.Run(() => mac.Now = () => clock.Value);
        await SignIn(mac);
        IReadOnlyList<FakeKeyServer.Call> Answers() => server.CallsTo("keys:answer", "Leo's Mac");
        HashSet<string?> Nonces(string commitment) => Answers().Where(a => a.Args["commitment"]!.StringValue == commitment).Select(a => a.Args["nonce"]!.StringValue).ToHashSet();
        var commitment = Convert.ToBase64String(KeyExchange.Nonce());
        server.SetAnswerMischief(FakeKeyServer.AnswerMischief.ConflictAndShowAgain);
        server.AddAskingDevice("Made-up iPad", commitment);
        Assert.True(await Eventually(() => Answers().Count > 0));
        await Task.Delay(200);
        await mac.Actor.Run(mac.ResumeKeyRequests);   // what the heartbeat does: answer what waits
        await Task.Delay(200);
        Assert.Single(Answers());
        Assert.Single(Nonces(commitment));

        // A new made-up commitment after every conflict: the hourly limit still holds.
        server.SetAnswerMischief(FakeKeyServer.AnswerMischief.ConflictAndNewCommitment);
        server.SetState("Made-up iPad", new FakeKeyServer.State.Requested(new FakeKeyServer.Exchange(Convert.ToBase64String(KeyExchange.Nonce()))));
        HashSet<string?> Answered() => Answers().Select(a => a.Args["commitment"]!.StringValue).ToHashSet();
        Assert.True(await Eventually(() => Answered().Count == SyncService.AnswersPerHour));
        await Task.Delay(400);
        Assert.Equal(SyncService.AnswersPerHour, Answered().Count);
        Assert.Contains("paused", await On(mac, () => mac.KeyWarning));

        // Two days on, with the record of the first answer gone, the first commitment shown again gets the same nonce.
        clock.Value = clock.Value.AddDays(2);
        await mac.Actor.Run(() => mac.Ledger.Answers.Clear());
        server.SetAnswerMischief(FakeKeyServer.AnswerMischief.ConflictAndShowAgain);
        server.SetState("Made-up iPad", new FakeKeyServer.State.Requested(new FakeKeyServer.Exchange(commitment)));
        Assert.True(await Eventually(() => Answers().Count(a => a.Args["commitment"]!.StringValue == commitment) == 2));
        Assert.Single(Nonces(commitment));
    }

    [Fact]
    public async Task AHolderThatMissedTwoRotationsKeepsItsKeyUntilTheListenerAsksAgain()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        var phoneStore = new MemorySecretStore();
        var phone = Device(server, "Leo's iPhone", phoneStore);
        await SignIn(phone);
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        Assert.True(await WaitUntil(phone, () => Comparison(phone) is not null));
        await mac.AllowKeyAsync(await On(mac, () => mac.KeyRequests[0]));
        phone.ConfirmKeyCode();
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available));
        var old = (await On(phone, () => phone.LibraryKey))!;
        server.SetAway("Leo's iPhone", true);
        await phone.StopAsync();

        server.SetLibrary(old.Id, true);
        Assert.True(await WaitUntil(mac, () => server.KeyId != old.Id && mac.LibraryKey?.Id == server.KeyId));
        var second = server.KeyId;
        server.SetLibrary(second, true);
        Assert.True(await WaitUntil(mac, () => server.KeyId != second && mac.LibraryKey?.Id == server.KeyId));
        Assert.Equal(new FakeKeyServer.State.Requested(), server.StateOf("Leo's iPhone"));

        server.SetAway("Leo's iPhone", false);
        phone = Device(server, "Leo's iPhone", phoneStore);
        await SignIn(phone);
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Outdated));
        var asked = server.CallsTo("keys:request", "Leo's iPhone").Count;
        await Task.Delay(300);
        Assert.Equal(old, await On(phone, () => phone.LibraryKey));
        Assert.Equal(asked, server.CallsTo("keys:request", "Leo's iPhone").Count);

        await phone.RequestKeyAgainAsync();
        Assert.Null(await On(phone, () => phone.LibraryKey));
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        Assert.True(await WaitUntil(phone, () => Comparison(phone) is not null));
        Assert.Equal((await On(mac, () => mac.KeyRequests[0])).Code, (await On(phone, () => Comparison(phone)))!.Code);
        await mac.AllowKeyAsync(await On(mac, () => mac.KeyRequests[0]));
        phone.ConfirmKeyCode();
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available));
        Assert.Equal(await On(mac, () => mac.LibraryKey), await On(phone, () => phone.LibraryKey));
    }

    [Fact]
    public async Task AskAgainNeverDropsTheAccountsKey()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        var held = await On(mac, () => mac.LibraryKey);
        Assert.True(await WaitUntil(mac, () => mac.KeyStatus is KeyStatus.Available));
        await mac.RequestKeyAgainAsync();
        Assert.Equal(held, await On(mac, () => mac.LibraryKey));
        Assert.Empty(server.CallsTo("keys:request", "Leo's Mac"));
    }

    [Fact]
    public async Task ALoneHolderThatCantReachTheAccountsKeyStartsOverWithAFreshKey()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        var held = (await On(mac, () => mac.LibraryKey))!;
        var named = LibraryKey.Generate();
        server.SetLibrary(named.Id, false);
        Assert.True(await Eventually(() => server.CallsTo("keys:release", "Leo's Mac").Count > 0));
        Assert.Equal(held.Id, server.CallsTo("keys:release", "Leo's Mac")[0].Args["keyId"]!.StringValue);
        Assert.True(await WaitUntil(mac, () => mac.KeyStatus is KeyStatus.Available && mac.LibraryKey?.Id == server.KeyId));
        var now = await On(mac, () => mac.LibraryKey);
        Assert.True(now != held && now != named);
        Assert.Empty(server.CallsTo("keys:request", "Leo's Mac"));
    }

    [Fact]
    public async Task AClaimWhoseAnswerWasLostKeepsItsKeyInTheSessionAndAfterARelaunch()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        await SignIn(mac);
        var old = await On(mac, () => mac.LibraryKey);
        MemorySecretStore? savedAtClaim = null;
        server.LoseClaimAnswer(true, _ => savedAtClaim = store.Copy());
        server.SetLibrary(null, false);
        Assert.True(await Eventually(() => server.KeyId is not null));
        var claimed = server.KeyId!;
        Assert.Equal(claimed, new SyncCredentialStore(savedAtClaim!).Load()?.ClaimingLibraryKey?.Id);
        Assert.True(await WaitUntil(mac, () => mac.LibraryKey?.Id == claimed && mac.KeyStatus is KeyStatus.Available));
        Assert.NotEqual(old, await On(mac, () => mac.LibraryKey));
        Assert.Null(new SyncCredentialStore(store).Load()?.ClaimingLibraryKey);
        await mac.StopAsync();

        // The app quit right after sending: launching from what was saved then adopts the key the server took.
        var relaunched = Device(server, "Leo's Mac", savedAtClaim);
        await SignIn(relaunched);
        Assert.True(await WaitUntil(relaunched, () => relaunched.LibraryKey?.Id == claimed && relaunched.KeyStatus is KeyStatus.Available));
    }

    [Fact]
    public async Task ARefusedClaimMakesANewKeyNextTime()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        await SignIn(mac);
        server.RefuseClaims(true);
        server.SetLibrary(null, false);
        Assert.True(await Eventually(() => server.CallsTo("keys:claim").Count >= 1));
        Assert.True(await Eventually(() => new SyncCredentialStore(store).Load()?.ClaimingLibraryKey is null));
        var refused = server.CallsTo("keys:claim")[0].Args["keyId"]!.StringValue;
        server.RefuseClaims(false);
        server.SetLibrary(null, false);
        Assert.True(await WaitUntil(mac, () => mac.LibraryKey?.Id == server.KeyId && server.KeyId is not null));
        Assert.NotEqual(refused, server.KeyId);
    }

    [Fact]
    public async Task ARegistrationWhoseAnswerWasLostKeepsItsKeyAndTokenAndIsAdoptedAfterARelaunch()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        server.LoseRegisterAnswer(true);
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(mac));
        var device = Assert.Single(server.Devices);
        Assert.IsType<FakeKeyServer.State.Holder>(device.State);   // the server took it: the account's first key
        var saved = new SyncCredentialStore(store).StateAs<SyncService.PendingRegistration>(SyncService.PendingRegistration.StateName)!;
        Assert.Equal(device.Token, saved.Token);
        await mac.StopAsync();

        // The next launch sends the same registration and adopts what the server says it did.
        server.LoseRegisterAnswer(false);
        var relaunched = Device(server, "Leo's Mac", store.Copy());
        await SignIn(relaunched);
        Assert.Single(server.Devices);
        Assert.Equal(device.Token, await On(relaunched, () => relaunched.Credentials!.Token));
        Assert.Equal(server.KeyId, (await On(relaunched, () => relaunched.LibraryKey))?.Id);
        Assert.True(await WaitUntil(relaunched, () => relaunched.KeyStatus is KeyStatus.Available));
    }

    [Fact]
    public async Task ARefusedRegistrationStartsFresh()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        server.RefuseRegistrations(true);
        await Assert.ThrowsAsync<SyncException>(() => SignIn(mac));
        var first = server.CallsTo("account:register")[0].Args["token"]!.StringValue;
        Assert.Null(new SyncCredentialStore(store).State(SyncService.PendingRegistration.StateName));
        server.RefuseRegistrations(false);
        await SignIn(mac);
        Assert.NotEqual(first, server.CallsTo("account:register")[^1].Args["token"]!.StringValue);
        Assert.True(await On(mac, () => mac.IsRegistered));
    }

    [Fact]
    public async Task ASavedRegistrationIsOnlyForItsUser()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        server.LoseRegisterAnswer(true);
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(mac, "a"));
        var tokenA = Assert.Single(server.Devices).Token;
        server.LoseRegisterAnswer(false);
        await SignIn(mac, "b");
        var tokenB = await On(mac, () => mac.Credentials!.Token);
        Assert.NotEqual(tokenA, tokenB);
        // A's device is owed a removal, made when A signs in here again.
        Assert.Contains(await On(mac, () => mac.PendingRemovals), r => r.Token == tokenA && r.UserId == "a");
        Assert.All(server.CallsTo("account:register").Where(c => c.Args["token"]!.StringValue == tokenA), c => Assert.Equal("a", c.User));
    }
}
