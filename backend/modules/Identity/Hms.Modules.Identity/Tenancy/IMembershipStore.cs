namespace Hms.Modules.Identity.Tenancy;

public sealed record MembershipGrant(IReadOnlyList<string> Roles, IReadOnlyList<Guid> AccessibleBranchIds);

public sealed record ActiveContext(Guid TenantId, Guid? BranchId);

public interface IMembershipStore
{
    /// <summary>
    /// Returns the user's active grant in an active tenant, or null when the user has no
    /// active membership there (or the requested branch is outside their branch scope).
    /// </summary>
    Task<MembershipGrant?> FindActiveGrantAsync(Guid userId, Guid tenantId, Guid? branchId, CancellationToken cancellationToken);

    /// <summary>
    /// Server-side default context for the CURRENT database user (stored choice if still valid,
    /// else first membership) — used when a token predates the custom access token hook.
    /// </summary>
    Task<ActiveContext?> FindDefaultContextAsync(CancellationToken cancellationToken);
}
