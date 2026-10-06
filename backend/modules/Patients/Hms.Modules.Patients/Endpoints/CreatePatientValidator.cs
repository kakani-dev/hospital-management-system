using System.Text.RegularExpressions;
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

        if (string.IsNullOrWhiteSpace(request.Mrn) || !MrnPattern().IsMatch(request.Mrn))
        {
            errors["mrn"] = ["MRN is required: 1-32 letters, digits or hyphens."];
        }

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

        return errors;
    }

    /// <summary>MRNs are stored upper-case so uniqueness is case-insensitive (DB: unique (tenant_id, upper(mrn))).</summary>
    public static string NormalizeMrn(string mrn) => mrn.Trim().ToUpperInvariant();

    [GeneratedRegex("^[A-Za-z0-9-]{1,32}$")]
    private static partial Regex MrnPattern();
}
