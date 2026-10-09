namespace Hms.Modules.Patients.Registry;

/// <summary>
/// C# mirror of <c>patient.normalize_phone(text)</c> (SPRINT2-CONTRACT §1.4): digits only, the LAST
/// 10 digits, or null when fewer than 7 digits. The search compares the stored column through the
/// mapped DB function against this value, so the expression index is used.
/// </summary>
public static class PatientPhone
{
    public const int MinDigits = 7;
    public const int KeptDigits = 10;

    public static string? Normalize(string? phone)
    {
        if (phone is null)
        {
            return null;
        }

        var digits = new string(phone.Where(char.IsAsciiDigit).ToArray());
        if (digits.Length < MinDigits)
        {
            return null;
        }

        return digits.Length > KeptDigits ? digits[^KeptDigits..] : digits;
    }
}
