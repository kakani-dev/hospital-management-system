using System.Text.RegularExpressions;

namespace Hms.Modules.Patients.Registry;

/// <summary>
/// C# mirror of <c>patient.to_e164(raw, country_code)</c>: turns what a receptionist types into
/// E.164 using the tenant's default calling code (identity.tenants.default_country_code, +91 by
/// default). Returns null when the input is not a phone number.
/// </summary>
public static partial class PhoneE164
{
    public const string FallbackCountryCode = "+91";

    public static string? Normalize(string? raw, string? countryCode)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        var v = SeparatorPattern().Replace(raw, string.Empty);
        var cc = (string.IsNullOrWhiteSpace(countryCode) ? FallbackCountryCode : countryCode).TrimStart('+');
        string candidate;
        if (v.StartsWith('+'))
        {
            candidate = v;
        }
        else if (v.StartsWith("00", StringComparison.Ordinal))
        {
            candidate = "+" + v[2..];
        }
        else if (!v.All(char.IsAsciiDigit))
        {
            return null;
        }
        else if (v.Length > 10 && v.StartsWith(cc, StringComparison.Ordinal))
        {
            candidate = "+" + v;
        }
        else
        {
            candidate = "+" + cc + v.TrimStart('0');
        }

        return E164Pattern().IsMatch(candidate) ? candidate : null;
    }

    public static bool IsE164(string? value) => value is not null && E164Pattern().IsMatch(value);

    [GeneratedRegex(@"[\s().-]")]
    private static partial Regex SeparatorPattern();

    [GeneratedRegex(@"^\+[1-9][0-9]{7,14}$")]
    private static partial Regex E164Pattern();
}
