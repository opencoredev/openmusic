using Medley.Core;
using Medley.Sync.Keys;
using static Medley.Sync.Tests.TestUtil;

namespace Medley.Sync.Tests;

/// <summary>
/// The race classes the Swift client's review rounds found (FourthReviewTests … NinthReviewTests), each run against the C#
/// port: stale lists, lost answers, operations interleaving, identity changes mid-call, late copies of a registration,
/// keys acknowledged before they were saved.
/// </summary>
public class ReviewTests : ServiceTests
{
    private static SyncService.PendingRegistration? SavedRegistration(MemorySecretStore store) =>
        new SyncCredentialStore(store).StateAs<SyncService.PendingRegistration>(SyncService.PendingRegistration.StateName);

    // MARK: Fourth review

    /// <summary>
    /// A's list from while the account used K1 arrives late; meanwhile A rotated to K2, B took K2, rotated to K3 (wrapped
    /// for A under K2) and left. The late list is older than what A applied: ignored, no release; A opens K3 with K2.
    /// </summary>
    [Fact]
    public async Task AStaleListNeverReleasesAKeyThatOpensTheWaitingRotation()
    {
        var server = new FakeKeyServer();
        var (mac, phone) = await TwoHolders(server);
        var k1 = (await On(mac, () => mac.LibraryKey))!;
        var stale = server.ListResultFor("Leo's Mac");
        Assert.Equal(k1.Id, stale.KeyId);
        Assert.Null(stale.Rekey);

        server.SetAway("Leo's iPhone", true);
        server.SetLibrary(k1.Id, true);
        Assert.True(await WaitUntil(mac, () => mac.LibraryKey != k1 && mac.LibraryKey?.Id == server.KeyId));
        var k2 = (await On(mac, () => mac.LibraryKey))!;

        server.SetAway("Leo's Mac", true);
        server.SetAway("Leo's iPhone", false);
        Assert.True(await WaitUntil(phone, () => phone.LibraryKey == k2));
        Assert.True(await Eventually(() => server.StateOf("Leo's iPhone") is FakeKeyServer.State.Holder { Rekey: null }));
        server.SetLibrary(k2.Id, true);
        Assert.True(await WaitUntil(phone, () => server.KeyId != k2.Id && phone.LibraryKey?.Id == server.KeyId));
        var k3 = server.KeyId!;
        var rekey = Assert.IsType<FakeKeyServer.State.Holder>(server.StateOf("Leo's Mac")).Rekey!;
        Assert.Equal(k3, rekey.KeyId);
        Assert.Equal(k2.Id, rekey.FromKeyId);
        await phone.StopAsync();
        server.Remove("Leo's iPhone");

        await mac.SetForegroundAsync(false);
        await Task.Delay(150);
        server.SetAway("Leo's Mac", false);
        await mac.Actor.Run(() => mac.Apply(stale));
        await Task.Delay(150);
        Assert.Equal(k2, await On(mac, () => mac.LibraryKey));
        Assert.Empty(server.CallsTo("keys:release", "Leo's Mac"));
        await mac.SetForegroundAsync(true);
        Assert.True(await WaitUntil(mac, () => mac.LibraryKey?.Id == server.KeyId && mac.KeyStatus is KeyStatus.Available));
        Assert.NotEqual(k2, await On(mac, () => mac.LibraryKey));
        Assert.IsType<FakeKeyServer.State.Holder>(server.StateOf("Leo's Mac"));
        Assert.Empty(server.CallsTo("keys:release", "Leo's Mac"));
    }

    /// <summary>A sign-in stalled fetching its token is overtaken by a sign-out and another user's sign-in: it changes nothing.</summary>
    [Fact]
    public async Task AStalledSignInNeverRegistersUnderTheNextUser()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        var stalled = new FakeTokens(Jwt("a")) { Delay = TimeSpan.FromMilliseconds(400) };
        var signInA = mac.SignInAsync(stalled, "a");
        await Task.Delay(50);
        await mac.SignOutAsync();
        await SignIn(mac, "b");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => signInA);
        await Task.Delay(500);
        Assert.All(server.CallsTo("account:register"), c => Assert.Equal("b", c.User));
        Assert.Equal("b", await On(mac, () => mac.SignedInUserId));
        Assert.True(await WaitUntil(mac, () => mac.KeyStatus is KeyStatus.Available));
    }

    /// <summary>Review finding: Forget() ran on the caller's thread, beside the actor's operations. It is posted now.</summary>
    [Fact]
    public async Task ForgetFromAnotherThreadRunsOnTheActor()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        await Task.Run(mac.Forget);
        Assert.True(await WaitUntil(mac, () => !mac.IsRegistered && mac.Credentials is null && mac.KeyStatus is KeyStatus.None));
    }

    // MARK: Fifth review

    [Fact]
    public async Task ASignOutAfterALostFirstRegistrationRemovesThatDevice()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        server.LoseRegisterAnswer(true);
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(mac));
        server.LoseRegisterAnswer(false);
        Assert.Single(server.Devices);
        Assert.IsType<FakeKeyServer.State.Holder>(server.StateOf("Leo's Mac"));
        Assert.NotNull(SavedRegistration(store));
        Assert.False(await On(mac, () => mac.IsRegistered));

        await mac.SignOutAsync();
        Assert.Empty(server.Devices);   // the holder row of the lost registration isn't left behind
        Assert.Null(SavedRegistration(store));
        Assert.Null(new SyncCredentialStore(store).Load());
        Assert.Empty(await On(mac, () => mac.PendingRemovals));
    }

    [Fact]
    public async Task AnOfflineSignOutAfterALostFirstRegistrationRemovesItOnTheNextSignInOfThatUserOnly()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        server.LoseRegisterAnswer(true);
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(mac));
        server.LoseRegisterAnswer(false);
        var orphan = server.Devices[0];

        server.SetUnreachable(true);
        await mac.SignOutAsync();
        Assert.Equal([orphan.Id], server.Devices.Select(d => d.Id));
        Assert.Null(SavedRegistration(store));
        Assert.Equal([orphan.Token], (await On(mac, () => mac.PendingRemovals)).Select(r => r.Token));

        // Another user signing in here doesn't touch it.
        var triedOffline = server.CallsTo("account:unregister").Count;
        server.SetUnreachable(false);
        var other = Device(server, "Leo's Mac", store);
        await SignIn(other, "other");
        await Task.Delay(150);
        Assert.Contains(server.Devices, d => d.Id == orphan.Id);
        Assert.DoesNotContain(server.CallsTo("account:unregister").Skip(triedOffline), c => c.Args["token"]!.StringValue == orphan.Token);
        await other.SignOutAsync();

        // The same user again: the orphan goes, the account resets, and this device claims a fresh key.
        var again = Device(server, "Leo's Mac", store);
        await SignIn(again);
        Assert.True(await Eventually(() => server.Devices.All(d => d.Id != orphan.Id)));
        Assert.True(await WaitUntil(again, () => again.LibraryKey is not null && again.LibraryKey.Id == server.KeyId));
        Assert.Empty(await On(again, () => again.PendingRemovals));
    }

    // MARK: Sixth review

    [Fact]
    public async Task AListOlderThanTheRotationsAnswerIsIgnored()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        Assert.True(await WaitUntil(mac, () => mac.VaultEntries is not null && mac.KeyStatus is KeyStatus.Available));
        var stale = server.ListResultFor("Leo's Mac");
        await mac.RotateKeyAsync();
        var rotated = server.KeyId;
        Assert.NotEqual(stale.KeyId, rotated);
        Assert.Equal(rotated, await On(mac, () => mac.ServerKeyId));
        await mac.Actor.RunAsync(() => mac.Operations.Run(null, _ => { mac.ApplyNow(stale); return Task.CompletedTask; }));
        Assert.Equal(rotated, await On(mac, () => mac.ServerKeyId));
        Assert.IsType<KeyStatus.Available>(await On(mac, () => mac.KeyStatus));
    }

    [Fact]
    public async Task AListOlderThanTheClaimsAnswerIsIgnored()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        var lists = new PathBlocker(server, "devices:list");
        var phone = Device(server, "Leo's iPhone", http: lists);
        await SignIn(phone);
        server.SetAway("Leo's iPhone", true);
        await mac.SignOutAsync();   // keyless now
        var stale = server.ListResultFor("Leo's iPhone");
        Assert.Null(stale.KeyId);
        server.LoseClaimAnswer(false, _ => lists.Block());
        server.SetAway("Leo's iPhone", false);
        Assert.True(await WaitUntil(phone, () => phone.LibraryKey is not null && phone.LibraryKey.Id == server.KeyId));
        var claims = server.CallsTo("keys:claim").Count;
        await phone.Actor.RunAsync(() => phone.Operations.Run(null, _ => { phone.ApplyNow(stale); return Task.CompletedTask; }));
        await Task.Delay(150);
        Assert.Equal(server.KeyId, await On(phone, () => phone.ServerKeyId));   // an older list didn't undo the claim's answer
        Assert.Equal(claims, server.CallsTo("keys:claim").Count);                // nor make the device claim again
    }

    [Fact]
    public async Task ARemovalIsKeptUntilTheServerConfirmsTheTokenIsSettled()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        server.LoseRegisterAnswer(true);
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(mac));
        server.LoseRegisterAnswer(false);
        var token = SavedRegistration(store)!.Token;
        server.Remove("Leo's Mac");
        // An older server answers "nothing removed" without recording anything: that settles nothing.
        server.LegacyUnregister(true);
        await mac.SignOutAsync();
        Assert.Contains(await On(mac, () => mac.PendingRemovals), r => r.Token == token);
        server.LegacyUnregister(false);
        var again = Device(server, "Leo's Mac", store);
        await SignIn(again);
        Assert.True(await WaitUntil(again, () => again.PendingRemovals.Count == 0));
        Assert.NotNull(server.RefusalOf(token, "u"));
    }

    // MARK: Seventh review

    private async Task<string> RegisterWithADelayedCopy(FakeKeyServer server, SyncService service, MemorySecretStore store)
    {
        server.Delay("account:register");
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(service));
        var token = SavedRegistration(store)!.Token;
        Assert.Equal(1, server.Parked);
        Assert.All(server.Devices, d => Assert.NotEqual(token, d.Token));
        await SignIn(service);
        Assert.True(await On(service, () => service.IsRegistered));
        Assert.Equal(token, await On(service, () => service.Credentials!.Token));
        Assert.Null(SavedRegistration(store));
        Assert.Equal(token, new SyncCredentialStore(store).Load()!.Token);
        return token;
    }

    [Fact]
    public async Task ALateCopyOfARegistrationNeverRegistersAgainAfterANormalSignOut()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac", store);
        var token = await RegisterWithADelayedCopy(server, mac, store);
        await mac.SignOutAsync();
        Assert.Empty(server.Devices);
        Assert.Null(new SyncCredentialStore(store).Load());
        Assert.Empty(await On(mac, () => mac.PendingRemovals));
        server.CommitDelayed();
        Assert.Empty(server.Devices);   // the late copy registered nothing
        Assert.Equal(FakeKeyServer.Refusal.Retired, server.RefusalOf(token, "u"));
    }

    [Fact]
    public async Task ALateCopyOfARegistrationNeverBringsBackADeviceRemovedElsewhere()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        var store = new MemorySecretStore();
        var phone = Device(server, "Leo's iPhone", store);
        var token = await RegisterWithADelayedCopy(server, phone, store);
        var id = (await On(phone, () => phone.SelfId))!.Value;
        await mac.RemoveAsync(id);
        Assert.DoesNotContain(server.Devices, d => d.Token == token);
        server.CommitDelayed();
        Assert.DoesNotContain(server.Devices, d => d.Token == token);
    }

    // MARK: Eighth review

    [Fact]
    public async Task ARegistrationSavedAMonthAgoIsNeverResent()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        var store = new MemorySecretStore();
        var phone = Device(server, "Leo's iPhone", store);
        server.LoseRegisterAnswer(true);
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(phone));
        server.LoseRegisterAnswer(false);
        var token = SavedRegistration(store)!.Token;
        var landed = server.Devices.First(d => d.Token == token);
        await mac.RemoveAsync(new DeviceId(landed.Id));
        Assert.Equal(FakeKeyServer.Refusal.Retired, server.RefusalOf(token, "u"));
        await phone.StopAsync();

        var month = TimeSpan.FromDays(31);
        server.AdvanceTime(month.TotalMilliseconds);
        Assert.Null(server.RefusalOf(token, "u"));   // the server forgot the retirement
        var relaunched = Device(server, "Leo's iPhone", store);
        await relaunched.Actor.Run(() => relaunched.Now = () => DateTimeOffset.UtcNow + month);
        var sentBefore = server.CallsTo("account:register").Count;
        await SignIn(relaunched);
        Assert.DoesNotContain(server.CallsTo("account:register").Skip(sentBefore), c => c.Args["token"]!.StringValue == token);
        Assert.DoesNotContain(server.Devices, d => d.Token == token);
        Assert.NotEqual(token, await On(relaunched, () => relaunched.Credentials?.Token));
        Assert.Null(SavedRegistration(store));
        Assert.True(await WaitUntil(relaunched, () => relaunched.PendingRemovals.Count == 0));
        Assert.Contains(server.CallsTo("account:unregister"), c => c.Args["token"]!.StringValue == token);
        Assert.Equal(FakeKeyServer.Refusal.Withdrawn, server.RefusalOf(token, "u"));
        var attempts = server.CallsTo("account:register").Where(c => c.Args["token"]!.StringValue == token).ToList();
        Assert.Single(attempts.Select(a => a.Args["createdAt"]!.DoubleValue).Distinct());
    }

    [Fact]
    public async Task ARegistrationSavedRecentlyIsStillResent()
    {
        var server = new FakeKeyServer();
        var store = new MemorySecretStore();
        var phone = Device(server, "Leo's iPhone", store);
        server.LoseRegisterAnswer(true);
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(phone));
        server.LoseRegisterAnswer(false);
        var token = SavedRegistration(store)!.Token;
        await phone.StopAsync();
        var relaunched = Device(server, "Leo's iPhone", store);
        await relaunched.Actor.Run(() => relaunched.Now = () => DateTimeOffset.UtcNow.AddDays(6));
        await SignIn(relaunched);
        Assert.Equal(token, await On(relaunched, () => relaunched.Credentials?.Token));
        Assert.Equal([token], server.Devices.Select(d => d.Token));
        Assert.Empty(await On(relaunched, () => relaunched.PendingRemovals));
    }

    // MARK: Ninth review and review 10

    [Fact]
    public async Task ARefusedWithdrawalNeverBlocksTheRemovalOfALandedDevice()
    {
        var server = new FakeKeyServer();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        var phoneStore = new MemorySecretStore();
        var phone = Device(server, "Leo's iPhone", phoneStore);
        server.LoseRegisterAnswer(true);
        await Assert.ThrowsAnyAsync<Exception>(() => SignIn(phone));
        server.LoseRegisterAnswer(false);
        var landed = SavedRegistration(phoneStore)!.Token;
        Assert.Contains(server.Devices, d => d.Token == landed);
        await phone.StopAsync();

        // Another installation owes eleven withdrawals of tokens that never landed (one more than an hour allows), then the landed one.
        var store = new MemorySecretStore();
        var unknown = Enumerable.Range(0, 11).Select(i => $"never-landed-{i}-" + new string('x', 32)).ToList();
        var owed = unknown.Append(landed).Select(t => new SyncService.PendingRemoval(t, "u", Deployment.AbsoluteUri)).ToList();
        new SyncCredentialStore(store).SetState(SyncService.PendingRemoval.StateName, SyncCredentialStore.Encode(owed));
        var ipad = Device(server, "Leo's iPad", store);
        await SignIn(ipad);
        Assert.True(await Eventually(() => server.Devices.All(d => d.Token != landed)));
        Assert.Equal(FakeKeyServer.Refusal.Retired, server.RefusalOf(landed, "u"));
        Assert.True(await WaitUntil(ipad, () => ipad.PendingRemovals.Select(r => r.Token).SequenceEqual([unknown[10]])));
    }

    /// <summary>The app's Codes Match carries the comparison it showed: one for another code (a restarted exchange) or
    /// another holder confirms nothing, the one shown confirms as before.</summary>
    [Fact]
    public async Task CodesMatchConfirmsOnlyTheComparisonShown()
    {
        var server = new FakeKeyServer();
        var (mac, phone) = await MacAndAskingPhone(server);
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        await mac.AllowKeyAsync(await On(mac, () => mac.KeyRequests[0]));
        Assert.True(await WaitUntil(phone, () => Comparison(phone)?.Allowed == true));
        var shown = (await On(phone, () => Comparison(phone)))!;

        phone.ConfirmKeyCode(shown with { Code = shown.Code == "000000" ? "111111" : "000000" });
        phone.ConfirmKeyCode(shown with { HolderId = new DeviceId("another-holder") });
        await Task.Delay(600);
        Assert.IsNotType<KeyStatus.Available>(await On(phone, () => phone.KeyStatus));
        Assert.Empty(server.CallsTo("keys:accept", "Leo's iPhone"));

        phone.ConfirmKeyCode(shown);
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available));
    }

    [Fact]
    public async Task AGrantedKeyIsAcknowledgedOnlyAfterItIsSaved()
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
        Assert.True(await WaitUntil(phone, () => Comparison(phone)?.Allowed == true));

        phoneStore.RefusedNames.Add("sync.credentials");
        phone.ConfirmKeyCode();
        await Task.Delay(800);
        Assert.Empty(server.CallsTo("keys:accept", "Leo's iPhone"));
        Assert.IsNotType<FakeKeyServer.State.Holder>(server.StateOf("Leo's iPhone"));
        Assert.Null(new SyncCredentialStore(phoneStore).Load()!.LibraryKey);

        phoneStore.RefusedNames.Clear();
        await phone.SetForegroundAsync(true);
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available));
        Assert.True(await Eventually(() => server.StateOf("Leo's iPhone") is FakeKeyServer.State.Holder { Rekey: null }));
        Assert.Equal(await On(mac, () => mac.LibraryKey), new SyncCredentialStore(phoneStore).Load()!.LibraryKey);
    }

    [Fact]
    public async Task ARotatedKeyIsAcknowledgedOnlyAfterItIsSaved()
    {
        var server = new FakeKeyServer();
        var phoneStore = new MemorySecretStore();
        var mac = Device(server, "Leo's Mac");
        await SignIn(mac);
        var phone = Device(server, "Leo's iPhone", phoneStore);
        await SignIn(phone);
        Assert.True(await WaitUntil(mac, () => mac.KeyRequests.Count == 1));
        Assert.True(await WaitUntil(phone, () => Comparison(phone) is not null));
        await mac.AllowKeyAsync(await On(mac, () => mac.KeyRequests[0]));
        phone.ConfirmKeyCode();
        Assert.True(await WaitUntil(phone, () => phone.KeyStatus is KeyStatus.Available));
        Assert.True(await Eventually(() => server.StateOf("Leo's iPhone") is FakeKeyServer.State.Holder { Rekey: null }));
        var k1 = (await On(phone, () => phone.LibraryKey))!;

        phoneStore.RefusedNames.Add("sync.credentials");
        var acceptsBefore = server.CallsTo("keys:accept", "Leo's iPhone").Count;
        server.SetLibrary(k1.Id, true);
        Assert.True(await Eventually(() => server.KeyId != k1.Id));
        var k2 = server.KeyId;
        await Task.Delay(800);
        Assert.Equal(acceptsBefore, server.CallsTo("keys:accept", "Leo's iPhone").Count);
        Assert.Equal(k1.Id, new SyncCredentialStore(phoneStore).Load()!.LibraryKey!.Id);

        phoneStore.RefusedNames.Clear();
        await phone.SetForegroundAsync(true);
        Assert.True(await WaitUntil(phone, () => phone.LibraryKey?.Id == k2));
        Assert.True(await Eventually(() => server.StateOf("Leo's iPhone") is FakeKeyServer.State.Holder { Rekey: null }));
        Assert.Equal(k2, new SyncCredentialStore(phoneStore).Load()!.LibraryKey!.Id);
    }

    // MARK: Interleaving

    /// <summary>
    /// A small version of InterleavingTests.swift: seeds of random steps (two users signing in and out, relaunches, late
    /// lists, forced rotations, approvals), checking that the vault is never reset while a remaining device could reach the
    /// key, that every call carries a JWT of the user its token belongs to, and that a sign-in's identity is what ends.
    /// </summary>
    public static IEnumerable<object[]> Seeds => Enumerable.Range(1, 30).Select(i => new object[] { i });

    [Theory]
    [MemberData(nameof(Seeds))]
    public async Task RandomInterleavingsKeepTheInvariants(int seed)
    {
        var random = new Random(seed);
        var server = new FakeKeyServer();
        var stores = new[] { new MemorySecretStore(), new MemorySecretStore() };
        var devices = new SyncService?[2];
        var lastUser = new string?[2];
        var names = new[] { "Mac", "Phone" };
        var lateLists = new List<(int Device, DeviceListResult List)>();
        var running = new List<Task>();
        for (var step = 0; step < 24; step++)
        {
            var d = random.Next(2);
            var device = devices[d];
            switch (random.Next(8))
            {
                case 0 or 1:
                {
                    var user = random.Next(3) == 0 ? "v" : "u";
                    devices[d] ??= Device(server, names[d], stores[d]);
                    lastUser[d] = user;
                    running.Add(Swallow(SignIn(devices[d]!, user)));
                    break;
                }
                case 2 when device is not null:
                    lastUser[d] = null;
                    running.Add(Swallow(device.SignOutAsync()));
                    break;
                case 3 when device is not null:
                    // A relaunch: the old process stops at once; the store stays.
                    await device.StopAsync();
                    devices[d] = Device(server, names[d], stores[d]);
                    if (lastUser[d] is { } u) running.Add(Swallow(SignIn(devices[d]!, u)));
                    break;
                case 4 when device is not null && server.Devices.Any(x => x.Name == names[d]):
                    lateLists.Add((d, server.ListResultFor(names[d])));
                    break;
                case 5 when lateLists.Count > 0:
                {
                    var (target, list) = lateLists[random.Next(lateLists.Count)];
                    if (devices[target] is { } s) await s.Actor.Run(() => s.Apply(list));
                    break;
                }
                case 6:
                    server.RequireRotation(random.Next(2) == 0 ? "u" : "v");
                    break;
                case 7 when device is not null:
                {
                    var requests = await On(device, () => device.KeyRequests);
                    foreach (var r in requests) running.Add(Swallow(device.AllowKeyAsync(r)));
                    device.ConfirmKeyCode();
                    break;
                }
            }
            await Task.Delay(random.Next(5, 60));
        }
        await Task.WhenAll(running);
        await Task.Delay(500);
        Assert.Empty(server.Violations);
        // Every call with a device token went out with a JWT of that token's user.
        foreach (var call in server.Calls.Where(c => c.Args["token"]?.StringValue is not null))
        {
            var owner = server.Devices.FirstOrDefault(x => x.Token == call.Args["token"]!.StringValue)?.Owner;
            if (owner is not null && call.Path != "account:register") Assert.True(call.User == owner, $"seed {seed}: {call.Path} with {owner}'s device token went out as {call.User ?? "nobody"}");
        }
        // Each device ends with the sign-in it was last asked for.
        for (var d = 0; d < 2; d++)
        {
            if (devices[d] is not { } s) continue;
            var expected = lastUser[d];
            if (expected is null) Assert.True(await WaitUntil(s, () => s.SignedInUserId is null));
            else Assert.True(await WaitUntil(s, () => s.SignedInUserId == expected || !s.IsRegistered), $"seed {seed}: device {d} ended as {await On(s, () => s.SignedInUserId)} not {expected}");
        }
    }

    private static async Task Swallow(Task task) { try { await task; } catch (Exception) { } }
}
