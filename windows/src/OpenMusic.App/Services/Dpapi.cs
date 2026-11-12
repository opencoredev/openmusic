using System.Runtime.InteropServices;
using OpenMusic.Providers.YouTube.Auth;
using OpenMusic.Providers.YouTube.Sync;
using OpenMusic.Sync.Keys;

namespace OpenMusic.App.Services;

/// <summary>
/// DPAPI (CryptProtectData, CurrentUser scope) through crypt32 directly, so the app needs no package for it. Only the
/// signed-in Windows user can open what it seals; blobs are bound to this machine's user profile.
/// </summary>
internal static partial class Dpapi
{
    /// <summary>Mixed into every blob, so another app's DPAPI blobs can't be passed off as OpenMusic's.</summary>
    private static readonly byte[] Entropy = "Medley for Windows v1"u8.ToArray();
    private const int CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptProtectData(ref DataBlob dataIn, IntPtr description, ref DataBlob entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob dataOut);

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptUnprotectData(ref DataBlob dataIn, IntPtr description, ref DataBlob entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob dataOut);

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr LocalFree(IntPtr mem);

    public static byte[] Protect(byte[] plain) => Run(plain, protect: true);

    public static byte[] Unprotect(byte[] sealedBytes) => Run(sealedBytes, protect: false);

    private static unsafe byte[] Run(byte[] input, bool protect)
    {
        fixed (byte* inPtr = input)
        fixed (byte* entPtr = Entropy)
        {
            var dataIn = new DataBlob { Size = input.Length, Data = (IntPtr)inPtr };
            var entropy = new DataBlob { Size = Entropy.Length, Data = (IntPtr)entPtr };
            var ok = protect
                ? CryptProtectData(ref dataIn, IntPtr.Zero, ref entropy, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out var output)
                : CryptUnprotectData(ref dataIn, IntPtr.Zero, ref entropy, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out output);
            if (!ok) throw new System.Security.Cryptography.CryptographicException(Marshal.GetLastPInvokeError());
            try
            {
                var result = new byte[output.Size];
                Marshal.Copy(output.Data, result, 0, output.Size);
                return result;
            }
            finally
            {
                if (output.Data != IntPtr.Zero)
                {
                    // Clear the plaintext copy DPAPI handed back before freeing it.
                    if (!protect) new Span<byte>((void*)output.Data, output.Size).Clear();
                    LocalFree(output.Data);
                }
            }
        }
    }

    /// <summary>%LOCALAPPDATA%\OpenMusic\secrets: one DPAPI blob per name.</summary>
    public static string SecretsDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), OpenMusic.Core.ProductInfo.FolderName, "secrets");
}

/// <summary>The YouTube provider's <see cref="ISecretProtector"/>: DPAPI, CurrentUser.</summary>
public sealed class DpapiProtector : ISecretProtector
{
    public byte[] Protect(byte[] plaintext) => Dpapi.Protect(plaintext);
    public byte[] Unprotect(byte[] ciphertext) => Dpapi.Unprotect(ciphertext);
}

/// <summary>
/// OpenMusic.Sync's <see cref="ISecretStore"/>: each name is a DPAPI-sealed file in <see cref="Dpapi.SecretsDirectory"/>,
/// written to a temp file first and moved over the old one. A blob that can't be opened (another user, another machine)
/// reads as missing.
/// </summary>
public sealed class DpapiSecretStore(string directory) : ISecretStore
{
    private readonly Lock _lock = new();

    private string PathFor(string name)
    {
        foreach (var c in name)
            if (!(char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_')) throw new ArgumentException($"unsupported secret name {name}");
        return Path.Combine(directory, name + ".dpapi");
    }

    public byte[]? Read(string name)
    {
        lock (_lock)
        {
            var path = PathFor(name);
            try
            {
                return File.Exists(path) ? Dpapi.Unprotect(File.ReadAllBytes(path)) : null;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
            {
                Log.Error($"secret store: couldn't read {name}: {e.GetType().Name}");
                return null;
            }
        }
    }

    public bool Write(string name, byte[]? data)
    {
        lock (_lock)
        {
            var path = PathFor(name);
            try
            {
                if (data is null)
                {
                    File.Delete(path);
                    return true;
                }
                Directory.CreateDirectory(directory);
                var temp = path + ".tmp";
                File.WriteAllBytes(temp, Dpapi.Protect(data));
                File.Move(temp, path, overwrite: true);
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
            {
                Log.Error($"secret store: couldn't write {name}: {e.GetType().Name}");
                return false;
            }
        }
    }
}

/// <summary>The YouTube sign-in transfer's snapshot (the payload sync seals), DPAPI-sealed like the sign-in itself.</summary>
public sealed class DpapiTransferStore(ISecretStore store) : IYouTubeMusicTransferStore
{
    private const string Name = "ytm.transfer";

    public YouTubeMusicTransferSnapshot? Load()
    {
        if (store.Read(Name) is not { Length: > 8 } bytes) return null;
        var ticks = BitConverter.ToInt64(bytes, 0);
        return new YouTubeMusicTransferSnapshot(bytes[8..], new DateTimeOffset(ticks, TimeSpan.Zero));
    }

    public void Save(YouTubeMusicTransferSnapshot? snapshot)
    {
        var ok = snapshot is null
            ? store.Write(Name, null)
            : store.Write(Name, [.. BitConverter.GetBytes(snapshot.TakenAt.UtcTicks), .. snapshot.Payload]);
        if (!ok) throw new IOException("The YouTube Music sign-in snapshot couldn't be saved.");
    }
}
