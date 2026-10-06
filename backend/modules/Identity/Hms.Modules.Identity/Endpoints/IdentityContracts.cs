namespace Hms.Modules.Identity.Endpoints;

public sealed record MembershipDto(Guid TenantId, string TenantName, Guid? BranchId, string? BranchName, string Role);

public sealed record BranchOptionDto(Guid Id, string Name);

public sealed record CurrentUserDto(
    Guid UserId,
    string? Email,
    Guid? ActiveTenantId,
    Guid? ActiveBranchId,
    IReadOnlyList<string> Roles,
    IReadOnlyList<BranchOptionDto> AccessibleBranches,
    IReadOnlyList<MembershipDto> Memberships);

public sealed record CurrentTenantDto(Guid Id, string Code, string Name, Guid? ActiveBranchId, IReadOnlyList<string> Roles);

/// <summary>Requested tenant/branch switch. Validated in the database against memberships.</summary>
public sealed record SwitchContextRequest(Guid TenantId, Guid? BranchId);

public sealed record BranchDto(Guid Id, string Code, string Name, string Timezone, bool IsActive);

public sealed record CreateBranchRequest(string? Code, string? Name, string? Timezone);

public sealed record UpdateBranchRequest(string? Name, string? Timezone, bool? IsActive);

public sealed record MemberDto(Guid Id, Guid UserId, string? Email, string? DisplayName, string Role, Guid? BranchId, string? BranchName, string Status);

public sealed record AddMemberRequest(string? Email, string? Role, Guid? BranchId);

public sealed record UpdateMemberRequest(string? Role, string? Status);
