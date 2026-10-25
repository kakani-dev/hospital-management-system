using System.Text.RegularExpressions;

namespace Hms.Modules.Appointments.Endpoints;

/// <summary>
/// Format check for an NMC or State Medical Council registration number. This does not call the
/// NMC register. Stored form is uppercase, 4–30 characters, letters, digits, spaces, dots, slashes
/// and hyphens, starting and ending with a letter or digit, with at least three digits.
/// </summary>
public static partial class NmcRegistration
{
    public const int MaxLength = 30;

    public static bool TryNormalize(string? raw, out string? normalized)
    {
        normalized = null;
        if (string.IsNullOrWhiteSpace(raw))
        {
            return true;
        }

        var value = Whitespace().Replace(raw.Trim().ToUpperInvariant(), " ");
        if (value.Length is < 4 or > MaxLength || !Shape().IsMatch(value) || Digit().Count(value) < 3)
        {
            return false;
        }

        normalized = value;
        return true;
    }

    /// <summary>Empty becomes null. A non-empty value that is not E.164 (or a 10-digit Indian number) fails.</summary>
    public static bool TryNormalizePhone(string? raw, out string? phone)
    {
        phone = null;
        if (string.IsNullOrWhiteSpace(raw))
        {
            return true;
        }

        var compact = PhoneSeparators().Replace(raw, string.Empty);
        if (compact.StartsWith("00", StringComparison.Ordinal))
        {
            compact = "+" + compact[2..];
        }
        else if (!compact.StartsWith('+') && compact.All(char.IsAsciiDigit) && compact.Length == 10)
        {
            compact = "+91" + compact;
        }

        if (!E164().IsMatch(compact))
        {
            return false;
        }

        phone = compact;
        return true;
    }

    public static bool TryNormalizeEmail(string? raw, out string? email)
    {
        email = null;
        if (string.IsNullOrWhiteSpace(raw))
        {
            return true;
        }

        var value = raw.Trim();
        if (value.Length is < 3 or > 254 || value.Any(char.IsWhiteSpace) || !EmailShape().IsMatch(value))
        {
            return false;
        }

        email = value;
        return true;
    }

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    [GeneratedRegex(@"^[A-Z0-9][A-Z0-9./ -]{2,28}[A-Z0-9]$")]
    private static partial Regex Shape();

    [GeneratedRegex(@"[0-9]")]
    private static partial Regex Digit();

    [GeneratedRegex(@"[\s().-]")]
    private static partial Regex PhoneSeparators();

    [GeneratedRegex(@"^\+[1-9][0-9]{7,14}$")]
    private static partial Regex E164();

    [GeneratedRegex(@"^[^@]+@[^@]+\.[^@]+$")]
    private static partial Regex EmailShape();
}
