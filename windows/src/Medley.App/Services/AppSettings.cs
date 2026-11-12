using System.Text.Json;
using System.Text.Json.Serialization;

namespace Medley.App.Services;

/// <summary>
/// This PC's preferences, in %LOCALAPPDATA%\Medley\settings.json: theme, whether the welcome page was seen, the stream
/// preference, the device name sync shows, recent searches and recent radio stations. Nothing secret lives here.
/// Synced settings (autoplay, recent searches…) are also written through Medley Sync when it's on (<see cref="SyncHub"/>).
/// UI thread only; saves are debounced.
/// </summary>
public sealed class AppSettings
{
    public sealed class Data
    {
        [JsonPropertyName("theme")] public string Theme { get; set; } = "system";
        /// <summary>The first run was finished or skipped; it never shows again (an update doesn't reset it).</summary>
        [JsonPropertyName("welcomeDone")] public bool WelcomeDone { get; set; }
        /// <summary>The first-run step to reopen at the next launch ("sync" after restarting to switch servers).</summary>
        [JsonPropertyName("onboardingResume")] public string? OnboardingResume { get; set; }
        [JsonPropertyName("streamPreference")] public string StreamPreference { get; set; } = "direct";
        [JsonPropertyName("autoplay")] public bool Autoplay { get; set; } = true;
        [JsonPropertyName("normalize")] public bool Normalize { get; set; } = true;
        [JsonPropertyName("volume")] public double Volume { get; set; } = 1;
        [JsonPropertyName("deviceName")] public string? DeviceName { get; set; }
        [JsonPropertyName("recentSearches")] public List<string> RecentSearches { get; set; } = [];
        [JsonPropertyName("stations")] public List<RecentStation> Stations { get; set; } = [];
    }

    public sealed class RecentStation
    {
        [JsonPropertyName("seed")] public string Seed { get; set; } = "";
        [JsonPropertyName("kind")] public string Kind { get; set; } = "track";
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("detail")] public string? Detail { get; set; }
        [JsonPropertyName("artwork")] public string? Artwork { get; set; }
    }

    public const int MaxRecentSearches = 20;
    private readonly string _path;
    private bool _savePending;

    public Data Values { get; }

    public event Action? RecentSearchesChanged;

    public AppSettings(string path)
    {
        _path = path;
        Values = Load(path);
    }

    private static Data Load(string path)
    {
        try
        {
            if (File.Exists(path)) return JsonSerializer.Deserialize(File.ReadAllText(path), AppSettingsJson.Default.Data) ?? new Data();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            Log.Error($"settings: couldn't read, using defaults ({e.GetType().Name})");
        }
        return new Data();
    }

    /// <summary>Saves on the next idle turn, once per burst of changes.</summary>
    public void Save()
    {
        if (_savePending) return;
        _savePending = true;
        App.Services.Dispatcher.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, SaveNow);
    }

    public void SaveNow()
    {
        _savePending = false;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(Values, AppSettingsJson.Default.Data));
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Error($"settings: couldn't save ({e.GetType().Name})");
        }
    }

    public void AddRecentSearch(string query)
    {
        var q = query.Trim();
        if (q.Length == 0 || q.StartsWith("shelf:", StringComparison.Ordinal)) return;
        var list = Values.RecentSearches;
        list.RemoveAll(s => string.Equals(s, q, StringComparison.OrdinalIgnoreCase));
        list.Insert(0, q);
        if (list.Count > MaxRecentSearches) list.RemoveRange(MaxRecentSearches, list.Count - MaxRecentSearches);
        Save();
        RecentSearchesChanged?.Invoke();
    }

    /// <summary>Another device's list (Medley Sync). Doesn't echo back.</summary>
    public void ReplaceRecentSearches(IReadOnlyList<string> list)
    {
        Values.RecentSearches = [.. list.Take(MaxRecentSearches)];
        Save();
    }

    public void ClearRecentSearches()
    {
        Values.RecentSearches.Clear();
        Save();
        RecentSearchesChanged?.Invoke();
    }

    public void AddStation(RecentStation station)
    {
        Values.Stations.RemoveAll(s => s.Seed == station.Seed);
        Values.Stations.Insert(0, station);
        if (Values.Stations.Count > 24) Values.Stations.RemoveRange(24, Values.Stations.Count - 24);
        Save();
    }
}

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(AppSettings.Data))]
internal sealed partial class AppSettingsJson : JsonSerializerContext;
