using OpenMusic.Core;
using OpenMusic.Core.Sync;
using OpenMusic.Sync.Keys;
using static OpenMusic.Sync.Tests.TestUtil;

namespace OpenMusic.Sync.Tests;

/// <summary>The P1s Sol's review of the sealed content found (port of SealedPublishRaceTests.swift), each failing before its fix.</summary>
public class SealedPublishRaceTests
{
    private static List<QueueEntry> Tracks(int n) => Enumerable.Range(0, n)
        .Select(i => new QueueEntry(new Track { ProviderID = $"t{i}", Provider = ProviderId.YouTubeMusic, Title = $"Song {i}", Duration = 200 })).ToList();

    /// <summary>A publish in flight when the key changed used to write its queue signature back on completion, so the
    /// publish the key change asked for went out anchor-only and the queue stayed under the old key.</summary>
    [Fact]
    public async Task AKeyChangeDuringAPublishStillPublishesTheQueueAgain()
    {
        var actor = SyncActor.CreateDedicated("coordinator");
        var hub = new FakeHub();
        var player = new FakePlayer { Entries = Tracks(3), CurrentIndex = 0, State = SyncPlayerState.Playing };
        var coordinator = new SyncCoordinator(hub, player, actor);
        await coordinator.AttachAsync();
        Assert.True(await Eventually(() => { lock (hub.Published) return hub.Published.Count == 1; }));
        var release = new TaskCompletionSource();
        var held = new TaskCompletionSource();
        hub.PublishGate = () => { held.TrySetResult(); return release.Task; };
        await actor.Run(() => player.Seek(30));   // an anchor-only publish, now held in flight
        await held.Task.WaitAsync(TimeSpan.FromSeconds(5));
        hub.PublishGate = null;
        hub.RaiseContentKeyChanged();
        await Task.Delay(100);
        release.SetResult();
        Assert.True(await Eventually(() => { lock (hub.Published) return hub.Published.Skip(1).Any(p => p.Queue is not null); }),
                    "the queue went out again under the new key");
        await coordinator.DetachAsync();
    }

    /// <summary>At launch the saved key is known before the server's keyId: settings that arrived first used to start the
    /// first sync, whose fill-ins couldn't be sealed and were never sent again.</summary>
    [Fact]
    public async Task SettingsWaitUntilTheDeviceCanSealThenFillIn()
    {
        var key = LibraryKey.Generate();
        var service = new SyncService(Deployment, new DeviceInfo("PC", DevicePlatform.Windows, "t", "1"), new SyncCredentialStore(new MemorySecretStore()),
                                      SyncActor.CreateDedicated("settings"), new FakeTransport { AutoFail = true }, new FakeKeyServer(), FastOptions(fallbackAfter: 1));
        await service.Actor.Run(() =>
        {
            service.Credentials = new SyncCredentials
            {
                DeviceId = new DeviceId("d1"), LibraryId = new LibraryId("lib"), Token = new string('t', 43), DeploymentUrl = Deployment,
                DeviceKey = DeviceKeyPair.Generate(), LibraryKey = key,
            };
            service.SealedSettings = [];
            service.ApplySettings();
            Assert.Null(service.SettingEntries);   // no first sync before the server's keyId says the saved key is the account's
            service.ServerKeyId = key.Id;
            Assert.NotNull(service.SettingEntries);   // it starts once the device can seal
            return true;
        });
    }
}
