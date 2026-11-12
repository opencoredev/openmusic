using System.Text;
using System.Text.Json.Nodes;
using Medley.Core;
using Medley.Providers.YouTube.Json;

namespace Medley.Providers.YouTube.Auth;

/// <summary>
/// Where the app keeps the YouTube Music sign-in (Swift: the Keychain items <c>ytm.credentials</c> and
/// <c>ytm.account</c>). Windows backs it with DPAPI (<see cref="ProtectedFileCredentialStore"/> plus a DPAPI
/// <see cref="ISecretProtector"/>); tests and the probe use <see cref="MemoryCredentialStore"/>.
/// </summary>
public interface IYouTubeMusicCredentialStore
{
    YouTubeMusicCredentials? LoadCredentials();

    /// <summary>Throws when the store didn't take them; the caller then changes nothing.</summary>
    void SaveCredentials(YouTubeMusicCredentials credentials);

    /// <summary>Deletes the saved cookies, throwing when they couldn't be deleted. Also drops the account summary.</summary>
    void ClearCredentials();

    /// <summary>The last confirmed account (name, photo, id). Holds no credentials. Best effort.</summary>
    AccountInfo? LoadAccount();

    void SaveAccount(AccountInfo? account);
}

/// <summary>Encrypts and decrypts the saved blobs. On Windows: DPAPI <c>ProtectedData</c> with CurrentUser scope.</summary>
public interface ISecretProtector
{
    byte[] Protect(byte[] plaintext);
    byte[] Unprotect(byte[] ciphertext);
}

/// <summary>In memory only. Never persists anything.</summary>
public sealed class MemoryCredentialStore : IYouTubeMusicCredentialStore
{
    readonly Lock _lock = new();
    YouTubeMusicCredentials? _credentials;
    AccountInfo? _account;

    public YouTubeMusicCredentials? LoadCredentials() { lock (_lock) return _credentials; }
    public void SaveCredentials(YouTubeMusicCredentials credentials) { lock (_lock) _credentials = credentials; }
    public void ClearCredentials() { lock (_lock) { _credentials = null; _account = null; } }
    public AccountInfo? LoadAccount() { lock (_lock) return _account; }
    public void SaveAccount(AccountInfo? account) { lock (_lock) _account = account; }
}

/// <summary>
/// Two files in <paramref name="directory"/> (<c>ytm.credentials</c>, <c>ytm.account</c>), each the JSON the Swift app
/// keeps in its Keychain item, passed through <see cref="ISecretProtector"/>. Writes go to a temp file first and replace
/// the old one, so a crash never leaves half a sign-in.
/// </summary>
public sealed class ProtectedFileCredentialStore(string directory, ISecretProtector protector) : IYouTubeMusicCredentialStore
{
    public const string CredentialsFile = "ytm.credentials";
    public const string AccountFile = "ytm.account";

    readonly Lock _lock = new();

    string PathOf(string name) => Path.Combine(directory, name);

    byte[]? Read(string name)
    {
        try
        {
            var path = PathOf(name);
            return File.Exists(path) ? protector.Unprotect(File.ReadAllBytes(path)) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
        {
            return null;
        }
    }

    void Write(string name, byte[]? plaintext)
    {
        var path = PathOf(name);
        if (plaintext == null)
        {
            if (File.Exists(path)) File.Delete(path);
            return;
        }
        Directory.CreateDirectory(directory);
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, protector.Protect(plaintext));
        File.Move(temp, path, overwrite: true);
    }

    public YouTubeMusicCredentials? LoadCredentials()
    {
        lock (_lock)
        {
            if (Read(CredentialsFile) is not { } bytes) return null;
            try { return YouTubeMusicCredentials.FromJson(bytes); } catch (Exception e) when (e is FormatException or System.Text.Json.JsonException) { return null; }
        }
    }

    public void SaveCredentials(YouTubeMusicCredentials credentials)
    {
        lock (_lock) Write(CredentialsFile, Encoding.UTF8.GetBytes(credentials.ToJson()));
    }

    public void ClearCredentials()
    {
        lock (_lock)
        {
            Write(CredentialsFile, null);
            try { Write(AccountFile, null); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { } // best effort, holds no credentials
        }
    }

    public AccountInfo? LoadAccount()
    {
        lock (_lock)
        {
            if (Read(AccountFile) is not { } bytes) return null;
            try { return AccountJson.FromNode(JsonNav.Parse(bytes) as JsonObject); } catch (System.Text.Json.JsonException) { return null; }
        }
    }

    public void SaveAccount(AccountInfo? account)
    {
        lock (_lock)
        {
            try { Write(AccountFile, account == null ? null : SwiftJson.SerializeToUtf8(AccountJson.ToNode(account))); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException) { } // best effort
        }
    }
}

/// <summary><see cref="AccountInfo"/> in the Swift Codable shape (<c>name</c>, <c>avatar</c>, <c>detail</c>, <c>id</c>).</summary>
internal static class AccountJson
{
    public static JsonObject ToNode(AccountInfo info)
    {
        var o = new JsonObject { ["name"] = info.Name };
        if (info.Avatar != null) o["avatar"] = info.Avatar.OriginalString;
        if (info.Detail != null) o["detail"] = info.Detail;
        if (info.Id != null) o["id"] = info.Id;
        return o;
    }

    public static AccountInfo? FromNode(JsonObject? o)
    {
        if (o == null || o.S("name") is not { } name) return null;
        Uri? avatar = o.S("avatar") is { } a && Uri.TryCreate(a, UriKind.Absolute, out var u) ? u : null;
        return new AccountInfo(name, avatar, o.S("detail"), o.S("id"));
    }
}
