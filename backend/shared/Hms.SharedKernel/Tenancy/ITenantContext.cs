namespace Hms.SharedKernel.Tenancy;

/// <summary>
/// The tenant/branch/user the current request is allowed to act in.
/// Populated ONLY by the Identity module's tenant resolution middleware from validated
/// token claims + server-side membership lookup. Never populated from client headers or bodies.
/// </summary>
public interface ITenantContext
{
    bool IsResolved { get; }
    Guid TenantId { get; }
    Guid? BranchId { get; }
    Guid UserId { get; }

    /// <summary>
    /// Union of roles valid in the current context (all memberships, or only those valid at the
    /// pinned branch). Use for TENANT-WIDE decisions (e.g. reading the patient registry).
    /// Never combine it with <see cref="CanAccessBranch"/> for branch-scoped writes; use
    /// <see cref="HasRoleAtBranch"/> instead (roles are bound to the branch they were granted for).
    /// </summary>
    IReadOnlySet<string> Roles { get; }

    IReadOnlySet<Guid> AccessibleBranchIds { get; }

    /// <summary>
    /// Per-branch role map: for every active branch of the tenant the user can access, the roles
    /// they hold AT that branch (tenant-wide memberships, branch_id null, apply to every branch).
    /// </summary>
    IReadOnlyDictionary<Guid, IReadOnlySet<string>> RolesByBranch { get; }

    /// <summary>IANA time zone of each accessible branch (identity.branches.timezone).</summary>
    IReadOnlyDictionary<Guid, string> BranchTimeZones { get; }

    bool HasAnyRole(params string[] roles);

    bool CanAccessBranch(Guid branchId);

    /// <summary>
    /// True when the user holds at least one of <paramref name="roles"/> AT <paramref name="branchId"/>
    /// (a branch of the resolved tenant). Mirrors identity.has_branch_role() in the database.
    /// </summary>
    bool HasRoleAtBranch(Guid branchId, params string[] roles);
}
