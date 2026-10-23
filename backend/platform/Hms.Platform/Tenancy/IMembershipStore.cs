namespace Hms.Platform.Tenancy;

/// <param name="Roles">Union of roles valid in the requested context (pinned branch, or all memberships).</param>
/// <param name="AccessibleBranchIds">Active branches of the tenant the user can access.</param>
/// <param name="RolesByBranch">For each accessible branch, the roles held AT that branch (tenant-wide memberships count everywhere).</param>
/// <param name="BranchTimeZones">EFFECTIVE IANA zone of each accessible branch (override, else tenant zone).</param>
/// <param name="TenantTimeZone">The tenant's required IANA zone.</param>
public sealed record MembershipGrant(
    IReadOnlyList<string> Roles,
    IReadOnlyList<Guid> AccessibleBranchIds,
    IReadOnlyDictionary<Guid, IReadOnlyCollection<string>> RolesByBranch,
    IReadOnlyDictionary<Guid, string> BranchTimeZones,
    string TenantTimeZone);

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
