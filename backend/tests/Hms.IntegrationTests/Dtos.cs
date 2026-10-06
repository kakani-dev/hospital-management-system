namespace Hms.IntegrationTests;

// Local mirrors of the API contracts (deserialization only; keeps tests honest about the wire format).
public sealed record MembershipView(Guid TenantId, string TenantName, Guid? BranchId, string? BranchName, string Role);

public sealed record BranchOptionView(Guid Id, string Name);

public sealed record MeView(Guid UserId, string? Email, Guid? ActiveTenantId, Guid? ActiveBranchId, List<string> Roles, List<BranchOptionView> AccessibleBranches, List<MembershipView> Memberships);

public sealed record TenantView(Guid Id, string Code, string Name, Guid? ActiveBranchId, List<string> Roles);

public sealed record PatientView(Guid Id, string Mrn, string FirstName, string LastName, Guid RegisteredBranchId);

public sealed record PagedView<T>(List<T> Items, int Page, int PageSize, int Total);

public sealed record BranchView(Guid Id, string Code, string Name, string Timezone, bool IsActive);

public sealed record MemberView(Guid Id, Guid UserId, string? Email, string? DisplayName, string Role, Guid? BranchId, string? BranchName, string Status);
