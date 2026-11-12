using System.Text;
using OpenMusic.Core;
using OpenMusic.Core.Sync;
using OpenMusic.Sync.Keys;
using static OpenMusic.Sync.Tests.TestUtil;

namespace OpenMusic.Sync.Tests;

/// <summary>An in-memory vault and settings server for SignInSync and SettingsSync (port of the Swift test endpoints).</summary>
public sealed class FakeVault : IVaultEndpoint, ISettingsEndpoint
{
    public DeviceId? SelfId { get; set; } = new DeviceId("me");
    public LibraryKey? LibraryKey { get; set; }
    public bool VaultWritesPaused { get; set; }
    public List<VaultEntry>? Entries { get; set; } = new();
    public IReadOnlyList<VaultEntry>? VaultEntries => Entries?.ToList();
    public ServerClock Clock { get; } = new();
    public double Time = 1_000;
    public List<(ProviderId Provider, int Base)> Puts { get; } = new();
    public Dictionary<string, SettingEntry> Settings { get; } = new();
    public IReadOnlyList<SettingEntry>? SettingEntries { get; set; }

    public Task<VaultWrite> PutVaultAsync(ProviderId provider, string sealedText, string keyId, int baseRevision)
    {
        Puts.Add((provider, baseRevision));
        var current = Entries!.FirstOrDefault(e => e.Provider == provider)?.Revision ?? 0;
        if (current != baseRevision) throw new SyncConflictException(current);
        Write(new VaultEntry { Provider = provider, Sealed = sealedText, KeyId = keyId, Revision = current + 1, UpdatedAt = ++Time, UpdatedBy = SelfId!.Value });
        return Task.FromResult(new VaultWrite(Time, current + 1));
    }

    public Task<VaultWrite> SignOutVaultAsync(ProviderId provider, int baseRevision)
    {
        var current = Entries!.FirstOrDefault(e => e.Provider == provider)?.Revision ?? 0;
        if (current != baseRevision) throw new SyncConflictException(current);
        Write(new VaultEntry { Provider = provider, Sealed = null, KeyId = new string('0', 32), Revision = current + 1, UpdatedAt = ++Time, UpdatedBy = SelfId!.Value });
        return Task.FromResult(new VaultWrite(Time, current + 1));
    }

    public void Write(VaultEntry entry)
    {
        Entries!.RemoveAll(e => e.Provider == entry.Provider);
        Entries.Add(entry);
    }

    public SyncActor? Actor { get; set; }
    public bool PutOffActor;

    public Task<double> PutSettingAsync(string key, string value, string writeId, bool ifAbsent)
    {
        if (Actor is { IsCurrent: false }) PutOffActor = true;
        if (ifAbsent && Settings.TryGetValue(key, out var existing)) return Task.FromResult(existing.UpdatedAt);
        Settings[key] = new SettingEntry(key, value, ++Time, "me", writeId);
        return Task.FromResult(Time);
    }
}

public class SignInAndSettingsTests
{
    private static (SignInSync Sync, FakeVault Vault, SyncActor Actor, SyncCredentialStore Store) Make(LibraryKey? key = null)
    {
        var actor = SyncActor.CreateDedicated("signins");
        var vault = new FakeVault { LibraryKey = key ?? LibraryKey.Generate() };
        var store = new SyncCredentialStore(new MemorySecretStore());
        var sync = new SignInSync(store, vault, actor);
        actor.Post(() => sync.BeginSession("scope-1"));
        return (sync, vault, actor, store);
    }

    private static async Task Settle(SyncActor actor, SignInSync sync)
    {
        for (var i = 0; i < 3; i++) await actor.RunAsync(sync.Settle);
    }

    [Fact]
    public async Task ALocalSignInIsSealedForTheNextRevisionAndAnUnchangedOneIsNotUploadedAgain()
    {
        var (sync, vault, actor, _) = Make();
        var spotify = new FakeSignIn(ProviderId.Spotify, "token-1");
        await actor.Run(() => sync.Register(spotify));
        await Settle(actor, sync);
        var entry = Assert.Single(vault.Entries!);
        Assert.Equal(1, entry.Revision);
        Assert.Equal("token-1"u8.ToArray(), SignInSealing.Open(entry.Sealed!, ProviderId.Spotify, 1, vault.LibraryKey!));
        await actor.Run(() => sync.ReconcileAll());
        await Settle(actor, sync);
        Assert.Single(vault.Puts);
        await actor.Run(() => spotify.LocalChange("token-2"));
        await Settle(actor, sync);
        Assert.Equal(2, vault.Entries![0].Revision);
        Assert.Equal((ProviderId.Spotify, 1), vault.Puts[^1]);
    }

    [Fact]
    public async Task AnotherDevicesWriteIsImportedAndATombstoneSignsOutEvenWithoutTheKey()
    {
        var (sync, vault, actor, _) = Make();
        var ytm = new FakeSignIn(ProviderId.YouTubeMusic);
        vault.Write(new VaultEntry { Provider = ProviderId.YouTubeMusic, Sealed = SignInSealing.Seal("cookie-from-mac"u8, ProviderId.YouTubeMusic, 4, vault.LibraryKey!),
                                     KeyId = vault.LibraryKey!.Id, Revision = 4, UpdatedAt = 900, UpdatedBy = new DeviceId("mac") });
        var imports = new List<SignInImport>();
        sync.Imported += i => imports.Add(i);
        await actor.Run(() => sync.Register(ytm));
        await Settle(actor, sync);
        Assert.Equal("cookie-from-mac", ytm.Text);
        Assert.Single(imports);
        Assert.Empty(vault.Puts);   // what it imported isn't sent back

        vault.LibraryKey = null;
        vault.Write(new VaultEntry { Provider = ProviderId.YouTubeMusic, Sealed = null, KeyId = new string('0', 32), Revision = 5, UpdatedAt = 950, UpdatedBy = new DeviceId("mac") });
        await actor.Run(() => sync.ReconcileAll());
        await Settle(actor, sync);
        Assert.Null(ytm.Text);
        Assert.Equal(1, ytm.SignOuts);
        Assert.IsType<SignInStatus.NeedsKey>(await actor.Run(() => sync.Status[ProviderId.YouTubeMusic]));
    }

    [Fact]
    public async Task AnEntryThatDoesntOpenAtItsRevisionSignsThisDeviceOutAndIsNeverUploadedOver()
    {
        var (sync, vault, actor, _) = Make();
        var ytm = new FakeSignIn(ProviderId.YouTubeMusic, "mine");
        // An old blob (sealed for revision 2) replayed at revision 7, on top of a sign-out this device missed.
        vault.Write(new VaultEntry { Provider = ProviderId.YouTubeMusic, Sealed = SignInSealing.Seal("old"u8, ProviderId.YouTubeMusic, 2, vault.LibraryKey!),
                                     KeyId = vault.LibraryKey!.Id, Revision = 7, UpdatedAt = 900, UpdatedBy = new DeviceId("mac") });
        await actor.Run(() => sync.Register(ytm));
        await Settle(actor, sync);
        Assert.Null(ytm.Text);
        Assert.Empty(vault.Puts);
        Assert.Equal(new SignInStatus.Failed(SignInSync.UnreadableMessage), await actor.Run(() => sync.Status[ProviderId.YouTubeMusic]));
        // Only a fresh sign-in here replaces it.
        await actor.Run(() => ytm.LocalChange("fresh"));
        await Settle(actor, sync);
        Assert.Equal((ProviderId.YouTubeMusic, 7), vault.Puts[^1]);
    }

    [Fact]
    public async Task AConflictWaitsForTheOtherWriteAndALegacyEntryIsMigratedOnce()
    {
        var (sync, vault, actor, _) = Make();
        var spotify = new FakeSignIn(ProviderId.Spotify);
        vault.Write(new VaultEntry { Provider = ProviderId.Spotify, Sealed = SignInSealing.SealLegacy("legacy-token"u8, ProviderId.Spotify, vault.LibraryKey!),
                                     KeyId = vault.LibraryKey!.Id, Revision = 0, UpdatedAt = 800, UpdatedBy = new DeviceId("mac") });
        await actor.Run(() => sync.Register(spotify));
        await Settle(actor, sync);
        Assert.Equal("legacy-token", spotify.Text);
        var migrated = vault.Entries![0];
        Assert.Equal(1, migrated.Revision);
        Assert.Equal("legacy-token"u8.ToArray(), SignInSealing.Open(migrated.Sealed!, ProviderId.Spotify, 1, vault.LibraryKey));
        // Writes paused (key not confirmed): nothing is uploaded.
        vault.VaultWritesPaused = true;
        await actor.Run(() => spotify.LocalChange("new-token"));
        await Settle(actor, sync);
        Assert.Equal(1, vault.Entries![0].Revision);
        Assert.IsType<SignInStatus.Waiting>(await actor.Run(() => sync.Status[ProviderId.Spotify]));
    }

    [Fact]
    public async Task SignOutEverywhereLeavesATombstoneAndAFailedDeletionChangesNothing()
    {
        var (sync, vault, actor, _) = Make();
        var spotify = new FakeSignIn(ProviderId.Spotify, "t");
        await actor.Run(() => sync.Register(spotify));
        await Settle(actor, sync);
        spotify.RefuseSignOuts = true;
        await Assert.ThrowsAsync<IOException>(() => sync.SignOutAsync(ProviderId.Spotify, everywhere: true));
        Assert.NotNull(vault.Entries![0].Sealed);
        spotify.RefuseSignOuts = false;
        await sync.SignOutAsync(ProviderId.Spotify, everywhere: true);
        Assert.Null(vault.Entries![0].Sealed);
        Assert.Equal(2, vault.Entries![0].Revision);
        Assert.IsType<SignInStatus.SignedOutEverywhere>(await actor.Run(() => sync.Status[ProviderId.Spotify]));
    }

    // MARK: Settings

    [Fact]
    public async Task OnFirstSyncTheAccountsValueWinsAndMissingKeysAreFilledInFromHere()
    {
        var actor = SyncActor.CreateDedicated("settings");
        var vault = new FakeVault();
        var settings = new SettingsSync(vault, () => vault.Time, actor);
        string? crossfade = null;
        await settings.ObserveAsync(SettingKeys.CrossfadeSeconds, () => "6", v => crossfade = v);
        await settings.ObserveAsync(SettingKeys.Autoplay, () => "true", _ => { });
        var entries = new List<SettingEntry> { new(SettingKeys.CrossfadeSeconds, "2.5", 10, "mac") };
        vault.SettingEntries = entries;
        await actor.Run(() => settings.Apply(entries));
        await actor.RunAsync(settings.Settle);
        Assert.Equal("2.5", crossfade);                                // the account's value wins
        Assert.Equal("true", vault.Settings[SettingKeys.Autoplay].Value);   // filled in (ifAbsent)
        Assert.False(vault.Settings.ContainsKey(SettingKeys.CrossfadeSeconds));
        // A local change goes up after the debounce; a newer remote value then wins.
        await settings.SetAsync(SettingKeys.CrossfadeSeconds, 4.0);
        await actor.RunAsync(settings.Settle);
        Assert.Equal("4", vault.Settings[SettingKeys.CrossfadeSeconds].Value);
        var newer = new List<SettingEntry> { new(SettingKeys.CrossfadeSeconds, "8", vault.Time + 100, "mac") };
        await actor.Run(() => settings.Apply(newer));
        Assert.Equal("8", crossfade);
        Assert.Equal("[\"a\\/b\"]", SettingsSync.Json(new[] { "a/b" }));   // "/" escaped as Swift writes it
    }

    /// <summary>Review finding: the public methods resumed on the caller's thread. Everything now runs on the actor.</summary>
    [Fact]
    public async Task SettingsCalledFromAnotherThreadRunOnTheActor()
    {
        var actor = SyncActor.CreateDedicated("settings");
        var vault = new FakeVault { Actor = actor, SettingEntries = new List<SettingEntry>() };
        var settings = new SettingsSync(vault, () => vault.Time, actor);
        var handlerOffActor = false;
        await Task.Run(() => settings.ObserveAsync(SettingKeys.Autoplay, () => "true", _ => handlerOffActor |= !actor.IsCurrent));
        await actor.Run(() => settings.Apply([]));
        await Task.WhenAll(Enumerable.Range(0, 20).Select(i => Task.Run(() => settings.SetAsync(SettingKeys.CrossfadeSeconds, (double)i))));
        await actor.RunAsync(settings.Settle);
        await actor.Run(() => settings.Apply([new SettingEntry(SettingKeys.Autoplay, "false", vault.Time + 1000, "mac")]));
        Assert.False(vault.PutOffActor);
        Assert.False(handlerOffActor);
        Assert.True(vault.Settings.ContainsKey(SettingKeys.CrossfadeSeconds));
    }
}
