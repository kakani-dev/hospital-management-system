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

    public static Dictionary<string, string[]> Validate(UpdateTenantRequest r)
    {
        var errors = new Dictionary<string, string[]>();
        if (r.Name is null && r.TimeZone is null)
        {
            errors["request"] = ["Provide name and/or timeZone."];
        }

        if (r.Name is not null)
        {
            ValidateName(r.Name, errors, required: true);
        }

        ValidateTimezone(r.TimeZone, errors, "timeZone");
        return errors;
    }

    /// <summary>True for an IANA id this runtime knows (the database re-checks against pg_timezone_names).</summary>
    public static bool IsIanaTimeZone(string? timezone) => Hms.SharedKernel.Time.TenantTimeZones.IsValidIana(timezone);

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

        if (r.Role == HmsRoles.TenantAdmin && r.BranchId is not null)
        {
            errors["branchId"] = [TenantAdminIsTenantWide];
        }

        return errors;
    }

    public static Dictionary<string, string[]> Validate(UpdateMemberRequest r)
    {
        var errors = new Dictionary<string, string[]>();
        if (r.Role is null && r.Status is null && r.BranchId is null && r.AllBranches is null)
        {
            errors["request"] = ["Provide role, status, branchId and/or allBranches."];
        }

        if (r.BranchId is not null && r.AllBranches == true)
        {
            errors["branchId"] = ["Use either branchId or allBranches, not both."];
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

    /// <summary>tenant_admin is tenant-wide (product decision; DB CHECK role &lt;&gt; 'tenant_admin' or branch_id is null).</summary>
    public const string TenantAdminIsTenantWide = "tenant_admin is tenant-wide: omit branchId.";

    private static void ValidateName(string? name, Dictionary<string, string[]> errors, bool required)
    {
        if ((required && string.IsNullOrWhiteSpace(name)) || name?.Length > 120)
        {
            errors["name"] = ["Name is required (max 120 characters)."];
        }
    }

    private static void ValidateTimezone(string? timezone, Dictionary<string, string[]> errors, string field = "timezone")
    {
        if (timezone is not null && !IsIanaTimeZone(timezone))
        {
            // code review MIN-2 / re-review N3: say which canonical id to use
            var suggestion = Hms.SharedKernel.Time.TenantTimeZones.Suggest(timezone);
            errors[field] = [suggestion is null
                ? "Unknown or unsupported IANA timezone. Use a canonical IANA id such as Asia/Kolkata."
                : $"Unknown or unsupported IANA timezone. Did you mean '{suggestion}'?"];
        }
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{1,39}$")]
    private static partial Regex CodePattern();
}
