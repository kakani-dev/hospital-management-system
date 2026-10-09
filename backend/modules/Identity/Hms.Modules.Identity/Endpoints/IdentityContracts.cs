namespace Hms.Modules.Identity.Endpoints;

public sealed record MembershipDto(Guid TenantId, string TenantName, Guid? BranchId, string? BranchName, string Role);

/// <param name="TimeZone">Effective IANA zone of the branch (override, else tenant zone).</param>
public sealed record BranchOptionDto(Guid Id, string Name, string? TimeZone = null);

public sealed record CurrentUserDto(
    Guid UserId,
    string? Email,
    Guid? ActiveTenantId,
    Guid? ActiveBranchId,
    IReadOnlyList<string> Roles,
    IReadOnlyList<BranchOptionDto> AccessibleBranches,
    IReadOnlyList<MembershipDto> Memberships,
    string? TimeZone = null);

public sealed record CurrentTenantDto(Guid Id, string Code, string Name, Guid? ActiveBranchId, IReadOnlyList<string> Roles, string TimeZone);

/// <summary>PATCH /api/v1/tenants/current (tenant_admin). A zone change is refused (409) while today's queue has entries.</summary>
public sealed record UpdateTenantRequest(string? Name, string? TimeZone);

/// <summary>POST /api/v1/platform/tenants (platform admins only; identity.create_tenant()).</summary>
public sealed record CreateTenantRequest(string? Code, string? Name, string? TimeZone, string? AdminEmail, string? BranchCode, string? BranchName);

public sealed record TenantDto(Guid Id, string Code, string Name, string TimeZone);

/// <summary>Requested tenant/branch switch. Validated in the database against memberships.</summary>
public sealed record SwitchContextRequest(Guid TenantId, Guid? BranchId);

/// <param name="Timezone">EFFECTIVE zone (override, else tenant zone): what every day-based rule at this branch uses.</param>
/// <param name="TimezoneOverride">The branch's own override, or null when it inherits the tenant zone.</param>
public sealed record BranchDto(Guid Id, string Code, string Name, string Timezone, bool IsActive, string? TimezoneOverride, bool IsDeleted);

/// <param name="Timezone">Optional override; omit to inherit the tenant zone.</param>
public sealed record CreateBranchRequest(string? Code, string? Name, string? Timezone);

/// <param name="InheritTimezone">true clears the override so the branch follows the tenant zone again.</param>
public sealed record UpdateBranchRequest(string? Name, string? Timezone, bool? IsActive, bool? InheritTimezone = null);

public sealed record MemberDto(Guid Id, Guid UserId, string? Email, string? DisplayName, string Role, Guid? BranchId, string? BranchName, string Status);

public sealed record AddMemberRequest(string? Email, string? Role, Guid? BranchId);

/// <summary>
/// Response of POST /api/v1/members. Identical for "no account", "invited" and "already a member"
/// so the endpoint cannot be used to enumerate platform accounts (review B1).
/// </summary>
public sealed record AddMemberAcceptedDto(string Message)
{
    public const string Text = "If an account exists for that email, an invitation has been sent.";

    public static readonly AddMemberAcceptedDto Instance = new(Text);
}

/// <summary>A pending invitation for the CURRENT user (identity.my_invitations()).</summary>
public sealed record InvitationDto(Guid MembershipId, Guid TenantId, string TenantName, Guid? BranchId, string Role, DateTimeOffset InvitedAt);

public sealed record UpdateMemberRequest(string? Role, string? Status);
