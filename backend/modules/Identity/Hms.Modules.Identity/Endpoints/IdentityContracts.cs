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
    string? TimeZone = null,
    bool IsPlatformAdmin = false,
    IReadOnlyList<string>? Permissions = null);

/// <summary>DefaultCountryCode: E.164 calling code applied to phones typed without one (e.g. "+91").</summary>
public sealed record CurrentTenantDto(Guid Id, string Code, string Name, Guid? ActiveBranchId, IReadOnlyList<string> Roles, string TimeZone, string? DefaultCountryCode = null);

/// <summary>
/// PATCH /api/v1/tenants/current (tenant_admin). A zone change is refused with 409 time_zone_locked
/// while today's queue has entries; one that would shift future bookings answers 409
/// time_zone_has_future_bookings with futureBookings = N; repeat with confirmFutureBookings = true.
/// The create-tenant HTTP endpoint lives in the identity service (code review MIN-5).
/// </summary>
public sealed record UpdateTenantRequest(string? Name, string? TimeZone, bool? ConfirmFutureBookings = null);

/// <summary>Requested tenant/branch switch. Validated in the database against memberships.</summary>
public sealed record SwitchContextRequest(Guid TenantId, Guid? BranchId);

/// <param name="Timezone">EFFECTIVE zone (override, else tenant zone): what every day-based rule at this branch uses.</param>
/// <param name="TimezoneOverride">The branch's own override, or null when it inherits the tenant zone.</param>
public sealed record BranchDto(Guid Id, string Code, string Name, string Timezone, bool IsActive, string? TimezoneOverride, bool IsDeleted);

/// <param name="Timezone">Optional override; omit to inherit the tenant zone.</param>
public sealed record CreateBranchRequest(string? Code, string? Name, string? Timezone);

/// <param name="InheritTimezone">true clears the override so the branch follows the tenant zone again.</param>
/// <summary>PATCH /api/v1/branches/{id}. Same future-bookings confirmation as the tenant zone.</summary>
public sealed record UpdateBranchRequest(string? Name, string? Timezone, bool? IsActive, bool? InheritTimezone = null, bool? ConfirmFutureBookings = null);

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

/// <param name="BranchId">Move the membership to this branch (branch-scoped staff).</param>
/// <param name="AllBranches">true = make the membership tenant-wide (branchId null).</param>
public sealed record UpdateMemberRequest(string? Role, string? Status, Guid? BranchId = null, bool? AllBranches = null);
