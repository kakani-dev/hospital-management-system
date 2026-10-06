namespace Hms.SharedKernel.Tenancy;

/// <summary>Scoped, request-lifetime implementation of <see cref="ITenantContext"/>.</summary>
public sealed class TenantContext : ITenantContext
{
    private Guid _tenantId;
    private Guid _userId;

    public bool IsResolved { get; private set; }

    public Guid TenantId => IsResolved ? _tenantId : throw new TenantNotResolvedException();

    public Guid? BranchId { get; private set; }

    public Guid UserId => IsResolved ? _userId : throw new TenantNotResolvedException();

    public IReadOnlySet<string> Roles { get; private set; } = new HashSet<string>();

    public IReadOnlySet<Guid> AccessibleBranchIds { get; private set; } = new HashSet<Guid>();

    public void Resolve(Guid tenantId, Guid userId, Guid? branchId, IEnumerable<string> roles, IEnumerable<Guid> accessibleBranchIds)
    {
        if (IsResolved)
        {
            throw new InvalidOperationException("Tenant context has already been resolved for this request.");
        }

        if (tenantId == Guid.Empty || userId == Guid.Empty)
        {
            throw new ArgumentException("Tenant and user ids must be non-empty.");
        }

        _tenantId = tenantId;
        _userId = userId;
        BranchId = branchId;
        Roles = new HashSet<string>(roles, StringComparer.Ordinal);
        AccessibleBranchIds = new HashSet<Guid>(accessibleBranchIds);
        IsResolved = true;
    }

    public bool HasAnyRole(params string[] roles) => IsResolved && roles.Any(Roles.Contains);

    public bool CanAccessBranch(Guid branchId) => IsResolved && AccessibleBranchIds.Contains(branchId);
}

public sealed class TenantNotResolvedException : InvalidOperationException
{
    public TenantNotResolvedException()
        : base("No tenant has been resolved for the current request.")
    {
    }
}
