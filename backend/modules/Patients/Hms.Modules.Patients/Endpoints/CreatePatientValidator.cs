using Hms.Modules.Patients.Domain;

namespace Hms.Modules.Patients.Endpoints;

/// <summary>Mirrors the CHECK constraints on patient.patients so callers get 400s instead of 500s.</summary>
public static partial class CreatePatientValidator
{
    /// <summary>Max phone length (matches the web form and the DB CHECK).</summary>
    public const int PhoneMaxLength = 32;

    /// <summary>Max email length (RFC 5321 path limit; matches the DB CHECK).</summary>
    public const int EmailMaxLength = 254;

    /// <summary>
    /// Validates a create request. <paramref name="today"/> is the current date IN THE REGISTERING
    /// BRANCH'S time zone (see <see cref="BranchClock"/>), so a baby born after local midnight is
    /// accepted even while the UTC date is still yesterday.
    /// </summary>
    public static Dictionary<string, string[]> Validate(CreatePatientRequest request, DateOnly today)
    {
        var errors = new Dictionary<string, string[]>();

        if (string.IsNullOrWhiteSpace(request.FirstName) || request.FirstName.Length > 100)
        {
            errors["firstName"] = ["First name is required (max 100 characters)."];
        }

        // #190: many patients have a single name, so the last name is optional (stored as '').
        if (request.LastName is { Length: > 100 })
        {
            errors["lastName"] = ["Last name must be at most 100 characters."];
        }

        if (request.Sex is not null && !PatientSex.All.Contains(request.Sex))
        {
            errors["sex"] = ["Sex must be one of: female, male, other, unknown."];
        }

        if (request.DateOfBirth is { } dob && (dob < new DateOnly(1900, 1, 1) || dob > today))
        {
            errors["dateOfBirth"] = ["Date of birth must be between 1900-01-01 and today."];
        }

        if (request.RegisteredBranchId == Guid.Empty)
        {
            errors["registeredBranchId"] = ["Registered branch is required."];
        }

        if (request.Phone is { Length: > PhoneMaxLength })
        {
            errors["phone"] = [$"Phone must be at most {PhoneMaxLength} characters."];
        }

        if (request.Email is { Length: > 0 } email && (email.Length > EmailMaxLength || !email.Contains('@', StringComparison.Ordinal)))
        {
            errors["email"] = [$"Email is not valid (max {EmailMaxLength} characters)."];
        }

        if (!string.IsNullOrWhiteSpace(request.AbhaNumber) && NormalizeAbha(request.AbhaNumber) is null)
        {
            errors["abhaNumber"] = ["ABHA number must be 14 digits (XX-XXXX-XXXX-XXXX)."];
        }

        return errors;
    }

    /// <summary>Oldest age accepted when the date of birth is estimated from an age.</summary>
    public const int MaxAgeYears = 120;

    /// <summary>
    /// #190: extra rules for a NEW registration (not for edits of existing charts):
    /// sex must be chosen (no silent default), a date of birth or an age is required,
    /// and a mobile number is required unless a "no phone" reason is given.
    /// </summary>
    public static void ValidateRegistration(CreatePatientRequest request, Dictionary<string, string[]> errors)
    {
        if (string.IsNullOrWhiteSpace(request.Sex))
        {
            errors.TryAdd("sex", ["Sex is required (female, male, other or unknown)."]);
        }

        if (request.AgeYears is { } age && (age < 0 || age > MaxAgeYears))
        {
            errors.TryAdd("ageYears", [$"Age must be between 0 and {MaxAgeYears} years."]);
        }
        else if (request.DateOfBirth is null && request.AgeYears is null)
        {
            errors.TryAdd("dateOfBirth", ["Enter a date of birth or an age."]);
        }

        var hasPhone = !string.IsNullOrWhiteSpace(request.Phone);
        var reason = request.NoPhoneReason?.Trim();
        if (!hasPhone && string.IsNullOrEmpty(reason))
        {
            errors.TryAdd("phone", ["Mobile number is required, or give a reason why the patient has none."]);
        }
        else if (!hasPhone && reason is { Length: < 3 or > 200 })
        {
            errors.TryAdd("noPhoneReason", ["The no-phone reason must be 3 to 200 characters."]);
        }
    }

    /// <summary>Date of birth estimated from an age: the same day and month, <paramref name="ageYears"/> years ago.</summary>
    public static DateOnly EstimateDateOfBirth(int ageYears, DateOnly today) => today.AddYears(-ageYears);

    /// <summary>
    /// ABHA number (14 digits) to its canonical XX-XXXX-XXXX-XXXX form; spaces / dashes in the input are
    /// ignored. Null for blank input or anything that is not exactly 14 digits.
    /// </summary>
    public static string? NormalizeAbha(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var digits = new string([.. value.Where(c => c is not (' ' or '-'))]);
        if (digits.Length != 14 || !digits.All(char.IsAsciiDigit))
        {
            return null;
        }

        return $"{digits[..2]}-{digits[2..6]}-{digits[6..10]}-{digits[10..]}";
    }

    /// <summary>MRNs are stored upper-case so uniqueness is case-insensitive (DB: unique (tenant_id, upper(mrn))).</summary>
    public static string NormalizeMrn(string mrn) => mrn.Trim().ToUpperInvariant();
}
