using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Hosting;

// CredService -- M6 RE-bait Windows service.
//
// Per-build constants (CipherBlob) live in Constants.g.cs, regenerated
// by scripts/seed_credservice.py from flags/manifest.yaml. Do NOT hand-edit them.
//
// Three M6 flags ride on this binary:
//   m6.s1 = AssemblyMetadata("ServiceTag") -- flag UUID in the binary's
//           metadata; no decryption needed.
//   m6.s2 = the AES-128 key used to decrypt CipherBlob, on disk at
//           C:\ProgramData\CredService\key.bin with NTFS ACL = SYSTEM only
//           (SDDL `D:P(A;;FA;;;SY)`); local Administrators are EXCLUDED.
//           Reading it requires elevating local-Administrator -> SYSTEM via
//           token impersonation (PtH-to-SYSTEM via SCM is blocked by SCM SDDL
//           hardening). The flag UUID is the key's 16 raw bytes as a UUID.
//   m6.s3 = the plaintext of AES-128-GCM-Decrypt(CipherBlob, key), recovered
//           by reading key.bin + CipherBlob and decrypting offline. CipherBlob
//           layout: 12B nonce || ct || 16B GCM tag.

namespace Nilgiri.CredService;

public static class Program
{
    public static async Task Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--probe")
        {
            // Manual probe -- prints whether the key file is readable
            // in the current process context. Useful for smoke-testing
            // the SYSTEM-only ACL gate from a console.
            try
            {
                var len = File.ReadAllBytes(KeyPath).Length;
                Console.WriteLine($"key.bin readable ({len} bytes)");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"key.bin NOT readable: {ex.GetType().Name}: {ex.Message}");
            }
            return;
        }
        var host = Host.CreateDefaultBuilder(args)
            .UseWindowsService(o => o.ServiceName = "CredService")
            .ConfigureServices(s => s.AddHostedService<TickerService>())
            .Build();
        await host.RunAsync();
    }

    private const string KeyPath = @"C:\ProgramData\CredService\key.bin";

    // Reads the AES key from the SYSTEM-only key file. An RE'er sees the
    // literal path here; the gate is then reading that file, which forces
    // elevation to SYSTEM via token impersonation.
    internal static byte[]? TryReadKey()
    {
        try
        {
            var bytes = File.ReadAllBytes(KeyPath);
            return bytes.Length == 16 ? bytes : null;
        }
        catch
        {
            return null;
        }
    }

    internal static string? TryDecrypt()
    {
        try
        {
            var key = TryReadKey();
            if (key is null) return null;
            var nonce = Constants.CipherBlob[..12];
            var ct = Constants.CipherBlob[12..^16];
            var tag = Constants.CipherBlob[^16..];
            var pt = new byte[ct.Length];
            using var gcm = new AesGcm(key, tagSizeInBytes: 16);
            gcm.Decrypt(nonce, ct, tag, pt);
            return Encoding.UTF8.GetString(pt);
        }
        catch (CryptographicException)
        {
            return null;
        }
    }
}

// TickerService is intentionally a no-op heartbeat: it exists so Get-Service
// shows the service, but writes no files and never surfaces the plaintext.
internal sealed class TickerService(ILogger<TickerService> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        log.LogInformation("CredService alive (no on-disk plaintext in this build).");
        while (!stop.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromMinutes(10), stop);
            }
            catch (OperationCanceledException) { }
        }
    }
}
