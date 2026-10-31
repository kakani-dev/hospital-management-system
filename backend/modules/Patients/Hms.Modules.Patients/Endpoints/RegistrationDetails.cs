using System.Text.RegularExpressions;
using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Registry;

namespace Hms.Modules.Patients.Endpoints;

/// <summary>
/// #58: what Indian front desks capture beyond name / age / phone. Every field is optional on the wire;
/// which ones are REQUIRED comes from the tenant's <see cref="RegistrationSettings"/> (server side).
/// Blank strings mean "not recorded" (null).
/// </summary>
public sealed record RegistrationDetails(
    string? AddressLine = null, string? City = null, string? District = null, string? State = null, string? PinCode = null,
    string? EmergencyContactName = null, string? EmergencyContactRelation = null, string? EmergencyContactPhone = null,
    string? GuardianName = null, string? GuardianRelation = null,
    string? BloodGroup = null, string? ReferralSource = null, string? ReferredBy = null)
{
    public static RegistrationDetails From(Patient p) => new(
        p.AddressLine, p.City, p.District, p.State, p.PinCode, p.EmergencyContactName, p.EmergencyContactRelation,
        p.EmergencyContactPhone, p.GuardianName, p.GuardianRelation, p.BloodGroup, p.ReferralSource, p.ReferredBy);
}

/// <summary>Per-tenant registration rules (patient.registration_settings). Defaults apply when the tenant has no row.</summary>
public sealed record RegistrationSettings(
    int GuardianRequiredBelowAgeYears = 18,
    bool EmergencyContactRequired = false,
    bool AddressRequired = false,
    bool ReferredByRequiredForReferrals = true)
{
    public static readonly RegistrationSettings Defaults = new();
    public const int MaxGuardianAge = 21;
}

public static partial class RegistrationRules
{
    public static readonly IReadOnlySet<string> BloodGroups = new HashSet<string>(StringComparer.Ordinal)
        { "A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-" };

    public static readonly IReadOnlySet<string> ReferralSources = new HashSet<string>(StringComparer.Ordinal)
        { "walk_in", "self", "doctor", "hospital", "health_camp", "insurance", "corporate", "other" };

    /// <summary>Referrals that name a person / facility the hospital pays or reports back to.</summary>
    public static readonly IReadOnlySet<string> NamedReferrals = new HashSet<string>(StringComparer.Ordinal) { "doctor", "hospital" };

    [GeneratedRegex("^[1-9][0-9]{5}$")]
    private static partial Regex PinPattern();

    private static string? Clean(string? v) => string.IsNullOrWhiteSpace(v) ? null : string.Join(' ', v.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    /// <summary>
    /// Validates and normalizes. <paramref name="ageYears"/> is the patient's age today (null = unknown).
    /// <paramref name="patientPhoneE164"/> is the patient's own number: an emergency contact on the same
    /// number is useless when the patient cannot answer, so it is refused.
    /// <paramref name="isNewRegistration"/>: tenant "required" rules apply to new registrations and to
    /// edits that touch the details, never retro-actively block unrelated edits of old charts.
    /// </summary>
    public static RegistrationDetails Normalize(
        RegistrationDetails? input, RegistrationSettings settings, int? ageYears, string? patientPhoneE164, string countryCode,
        bool enforceRequired, Dictionary<string, string[]> errors)
    {
        var d = input ?? new RegistrationDetails();
        var pin = Clean(d.PinCode)?.Replace(" ", string.Empty, StringComparison.Ordinal);
        var blood = Clean(d.BloodGroup)?.ToUpperInvariant().Replace("POSITIVE", "+", StringComparison.Ordinal).Replace("NEGATIVE", "-", StringComparison.Ordinal).Replace("VE", string.Empty, StringComparison.Ordinal).Replace(" ", string.Empty, StringComparison.Ordinal);
        var source = Clean(d.ReferralSource)?.ToLowerInvariant();
        var emergencyRaw = Clean(d.EmergencyContactPhone);
        var emergencyPhone = emergencyRaw is null ? null : PhoneE164.Normalize(emergencyRaw, countryCode);
        var r = new RegistrationDetails(
            Max(Clean(d.AddressLine), 300, "details.addressLine", errors),
            Max(Clean(d.City), 100, "details.city", errors),
            Max(Clean(d.District), 100, "details.district", errors),
            Max(Clean(d.State), 100, "details.state", errors),
            pin,
            Max(Clean(d.EmergencyContactName), 100, "details.emergencyContactName", errors),
            Max(Clean(d.EmergencyContactRelation), 50, "details.emergencyContactRelation", errors),
            emergencyPhone,
            Max(Clean(d.GuardianName), 100, "details.guardianName", errors),
            Max(Clean(d.GuardianRelation), 50, "details.guardianRelation", errors),
            blood, source,
            Max(Clean(d.ReferredBy), 150, "details.referredBy", errors));

        if (pin is not null && !PinPattern().IsMatch(pin))
        {
            errors["details.pinCode"] = ["PIN code must be 6 digits and cannot start with 0."];
        }

        if (blood is not null && !BloodGroups.Contains(blood))
        {
            errors["details.bloodGroup"] = ["Blood group must be one of A+, A-, B+, B-, AB+, AB-, O+, O- (leave blank if not known)."];
        }

        if (source is not null && !ReferralSources.Contains(source))
        {
            errors["details.referralSource"] = ["Referral source is not a known value."];
        }

        if (emergencyRaw is not null && emergencyPhone is null)
        {
            errors["details.emergencyContactPhone"] = ["Emergency contact phone is not a valid number."];
        }
        else if (emergencyPhone is not null && emergencyPhone == patientPhoneE164)
        {
            errors["details.emergencyContactPhone"] = ["Emergency contact must be a different number from the patient's own."];
        }

        if ((r.EmergencyContactName is null) != (emergencyRaw is null) && !errors.ContainsKey("details.emergencyContactPhone"))
        {
            errors["details.emergencyContactName"] = ["Give both the emergency contact's name and phone."];
        }

        if (!enforceRequired)
        {
            return r;
        }

        if (settings.EmergencyContactRequired && r.EmergencyContactName is null && r.EmergencyContactPhone is null)
        {
            errors.TryAdd("details.emergencyContactName", ["An emergency contact (name and phone) is required."]);
        }

        if (settings.AddressRequired && (r.AddressLine is null || r.PinCode is null))
        {
            errors.TryAdd("details.addressLine", ["Address and PIN code are required."]);
        }

        if (settings.GuardianRequiredBelowAgeYears > 0 && ageYears is { } age && age < settings.GuardianRequiredBelowAgeYears
            && r.GuardianName is null)
        {
            errors.TryAdd("details.guardianName", [$"A guardian is required for patients under {settings.GuardianRequiredBelowAgeYears}."]);
        }

        if (settings.ReferredByRequiredForReferrals && source is not null && NamedReferrals.Contains(source) && r.ReferredBy is null)
        {
            errors.TryAdd("details.referredBy", ["Name the referring doctor or hospital."]);
        }

        return r;
    }

    public static int? AgeYears(DateOnly? dob, DateOnly today)
    {
        if (dob is not { } d)
        {
            return null;
        }

        var age = today.Year - d.Year;
        return d.AddYears(age) > today ? age - 1 : age;
    }

    public static void Apply(Patient p, RegistrationDetails d)
    {
        p.AddressLine = d.AddressLine; p.City = d.City; p.District = d.District; p.State = d.State; p.PinCode = d.PinCode;
        p.EmergencyContactName = d.EmergencyContactName; p.EmergencyContactRelation = d.EmergencyContactRelation;
        p.EmergencyContactPhone = d.EmergencyContactPhone; p.GuardianName = d.GuardianName; p.GuardianRelation = d.GuardianRelation;
        p.BloodGroup = d.BloodGroup; p.ReferralSource = d.ReferralSource; p.ReferredBy = d.ReferredBy;
    }

    private static string? Max(string? v, int max, string field, Dictionary<string, string[]> errors)
    {
        if (v is { Length: var n } && n > max)
        {
            errors[field] = [$"Must be at most {max} characters."];
        }

        return v;
    }
}
