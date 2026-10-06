using System.Text.RegularExpressions;
using Hms.Modules.Patients.Domain;

namespace Hms.Modules.Patients.Endpoints;

/// <summary>Mirrors the CHECK constraints on patient.patients so callers get 400s instead of 500s.</summary>
public static partial class CreatePatientValidator
{
    public static Dictionary<string, string[]> Validate(CreatePatientRequest request)
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

        if (request.DateOfBirth is { } dob && (dob < new DateOnly(1900, 1, 1) || dob > DateOnly.FromDateTime(DateTime.UtcNow)))
        {
            errors["dateOfBirth"] = ["Date of birth must be between 1900-01-01 and today."];
        }

        if (request.RegisteredBranchId == Guid.Empty)
        {
            errors["registeredBranchId"] = ["Registered branch is required."];
        }

        if (request.Email is { Length: > 0 } email && !email.Contains('@', StringComparison.Ordinal))
        {
            errors["email"] = ["Email is not valid."];
        }

        return errors;
    }

    [GeneratedRegex("^[A-Za-z0-9-]{1,32}$")]
    private static partial Regex MrnPattern();
}
