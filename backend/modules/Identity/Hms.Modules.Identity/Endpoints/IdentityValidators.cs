using System.Text.RegularExpressions;
using Hms.Modules.Identity.Domain;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Identity.Endpoints;

/// <summary>Mirrors the CHECK constraints in supabase/migrations so callers get 400s, not 500s.</summary>
public static partial class IdentityValidators
{
    public static Dictionary<string, string[]> Validate(CreateBranchRequest r)
    {
        var errors = new Dictionary<string, string[]>();
        if (r.Code is null || !CodePattern().IsMatch(r.Code))
        {
            errors["code"] = ["Code must be 2-40 lowercase letters, digits or hyphens, starting with a letter or digit."];
        }

        ValidateName(r.Name, errors, required: true);
        ValidateTimezone(r.Timezone, errors);
        return errors;
    }

    public static Dictionary<string, string[]> Validate(UpdateBranchRequest r)
    {
        var errors = new Dictionary<string, string[]>();
        if (r.Name is not null)
        {
            ValidateName(r.Name, errors, required: true);
        }

        ValidateTimezone(r.Timezone, errors);
        return errors;
    }

    public static Dictionary<string, string[]> Validate(AddMemberRequest r)
    {
        var errors = new Dictionary<string, string[]>();
        if (string.IsNullOrWhiteSpace(r.Email) || !r.Email.Contains('@', StringComparison.Ordinal) || r.Email.Length > 254)
        {
            errors["email"] = ["A valid email is required."];
        }

        if (r.Role is null || !HmsRoles.All.Contains(r.Role))
        {
            errors["role"] = [$"Role must be one of: {string.Join(", ", HmsRoles.All.Order(StringComparer.Ordinal))}."];
        }

        return errors;
    }

    public static Dictionary<string, string[]> Validate(UpdateMemberRequest r)
    {
        var errors = new Dictionary<string, string[]>();
        if (r.Role is null && r.Status is null)
        {
            errors["request"] = ["Provide role and/or status."];
        }

        if (r.Role is not null && !HmsRoles.All.Contains(r.Role))
        {
            errors["role"] = ["Unknown role."];
        }

        if (r.Status is not null && r.Status is not (MembershipStatus.Active or MembershipStatus.Suspended))
        {
            errors["status"] = ["Status must be 'active' or 'suspended'."];
        }

        return errors;
    }

    private static void ValidateName(string? name, Dictionary<string, string[]> errors, bool required)
    {
        if ((required && string.IsNullOrWhiteSpace(name)) || name?.Length > 120)
        {
            errors["name"] = ["Name is required (max 120 characters)."];
        }
    }

    private static void ValidateTimezone(string? timezone, Dictionary<string, string[]> errors)
    {
        if (timezone is not null && !TimeZoneInfo.TryFindSystemTimeZoneById(timezone, out _))
        {
            errors["timezone"] = ["Unknown IANA timezone."];
        }
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{1,39}$")]
    private static partial Regex CodePattern();
}
