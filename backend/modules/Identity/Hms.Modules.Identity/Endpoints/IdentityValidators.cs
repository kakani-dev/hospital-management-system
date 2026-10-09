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

    public static Dictionary<string, string[]> Validate(CreateTenantRequest r)
    {
        var errors = new Dictionary<string, string[]>();
        if (r.Code is null || !CodePattern().IsMatch(r.Code))
        {
            errors["code"] = ["Code must be 2-40 lowercase letters, digits or hyphens, starting with a letter or digit."];
        }

        ValidateName(r.Name, errors, required: true);
        if (string.IsNullOrWhiteSpace(r.TimeZone))
        {
            errors["timeZone"] = ["A time zone is required (IANA id, e.g. Asia/Kolkata)."];
        }
        else
        {
            ValidateTimezone(r.TimeZone, errors, "timeZone");
        }

        if (r.AdminEmail is not null && (!r.AdminEmail.Contains('@', StringComparison.Ordinal) || r.AdminEmail.Length > 254))
        {
            errors["adminEmail"] = ["adminEmail must be a valid email."];
        }

        if (r.BranchCode is not null && !CodePattern().IsMatch(r.BranchCode))
        {
            errors["branchCode"] = ["Branch code must be 2-40 lowercase letters, digits or hyphens."];
        }

        if (r.BranchName is not null)
        {
            var branchErrors = new Dictionary<string, string[]>();
            ValidateName(r.BranchName, branchErrors, required: true);
            if (branchErrors.Count > 0)
            {
                errors["branchName"] = branchErrors["name"];
            }
        }

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
            errors[field] = ["Unknown IANA timezone."];
        }
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{1,39}$")]
    private static partial Regex CodePattern();
}
