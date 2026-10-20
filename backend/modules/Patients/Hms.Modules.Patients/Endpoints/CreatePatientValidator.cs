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

        if (string.IsNullOrWhiteSpace(request.LastName) || request.LastName.Length > 100)
        {
            errors["lastName"] = ["Last name is required (max 100 characters)."];
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
