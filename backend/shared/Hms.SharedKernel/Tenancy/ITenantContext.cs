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
    IReadOnlySet<string> Roles { get; }
    IReadOnlySet<Guid> AccessibleBranchIds { get; }

    bool HasAnyRole(params string[] roles);
    bool CanAccessBranch(Guid branchId);
}
