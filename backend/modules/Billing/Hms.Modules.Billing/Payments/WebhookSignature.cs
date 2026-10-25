using System.Buffers;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Hms.Modules.Billing.Payments;

/// <summary>
/// Sandbox webhook signature. Header <c>X-MediCore-Signature: t=&lt;unix&gt;,v1=&lt;hex&gt;</c>
/// is HMAC-SHA256 over <c>{unix}.{raw body}</c>. No live provider key is read.
/// </summary>
public static class WebhookSignature
{
    public const string HeaderName = "X-MediCore-Signature";

    public static string Sign(string secret, ReadOnlySpan<byte> body, long unixSeconds)
    {
        var mac = Hash(secret, body, unixSeconds);
        return string.Create(CultureInfo.InvariantCulture, $"t={unixSeconds},v1={Convert.ToHexString(mac).ToLowerInvariant()}");
    }

    public static bool Verify(
        string secret,
        string? previousSecret,
        ReadOnlySpan<byte> body,
        string? header,
        DateTimeOffset now,
        TimeSpan tolerance)
    {
        if (string.IsNullOrEmpty(secret) || !TryParse(header, out var unixSeconds, out var presented))
        {
            return false;
        }

        DateTimeOffset stamped;
        try
        {
            stamped = DateTimeOffset.FromUnixTimeSeconds(unixSeconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            return false;
        }

        var skew = (now - stamped).Duration();
        if (skew > tolerance)
        {
            return false;
        }

        var expected = Hash(secret, body, unixSeconds);
        var matches = FixedEquals(expected, presented);
        if (!string.IsNullOrEmpty(previousSecret))
        {
            var previous = Hash(previousSecret, body, unixSeconds);
            matches |= FixedEquals(previous, presented);
        }

        return matches;
    }

    private static byte[] Hash(string secret, ReadOnlySpan<byte> body, long unixSeconds)
    {
        var prefix = Encoding.ASCII.GetBytes(string.Create(CultureInfo.InvariantCulture, $"{unixSeconds}."));
        var payload = new byte[prefix.Length + body.Length];
        prefix.CopyTo(payload, 0);
        body.CopyTo(payload.AsSpan(prefix.Length));
        return HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), payload);
    }

    private static bool FixedEquals(byte[] expected, string presentedHex)
    {
        var presented = new byte[expected.Length];
        var status = Convert.FromHexString(presentedHex, presented, out _, out var written);
        if (presentedHex.Length != expected.Length * 2
            || status != OperationStatus.Done
            || written != expected.Length)
        {
            CryptographicOperations.FixedTimeEquals(expected, expected);
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(expected, presented);
    }

    private static bool TryParse(string? header, out long unixSeconds, out string presented)
    {
        unixSeconds = 0;
        presented = "";
        if (string.IsNullOrWhiteSpace(header))
        {
            return false;
        }

        foreach (var part in header.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var eq = part.IndexOf('=', StringComparison.Ordinal);
            if (eq <= 0)
            {
                continue;
            }

            var key = part[..eq];
            var value = part[(eq + 1)..];
            if (key == "t" && !long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out unixSeconds))
            {
                return false;
            }

            if (key == "v1")
            {
                presented = value;
            }
        }

        return unixSeconds > 0 && presented.Length > 0;
    }
}
