namespace Hms.Modules.Identity.Tenancy;

public sealed record MembershipGrant(IReadOnlyList<string> Roles, IReadOnlyList<Guid> AccessibleBranchIds);

public interface IMembershipStore
{
    /// <summary>
    /// Returns the user's active grant in an active tenant, or null when the user has no
    /// active membership there (or the requested branch is outside their branch scope).
    /// </summary>
    Task<MembershipGrant?> FindActiveGrantAsync(Guid userId, Guid tenantId, Guid? branchId, CancellationToken cancellationToken);
}
