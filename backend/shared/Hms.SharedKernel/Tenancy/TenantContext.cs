namespace Hms.SharedKernel.Tenancy;

/// <summary>Scoped, request-lifetime implementation of <see cref="ITenantContext"/>.</summary>
public sealed class TenantContext : ITenantContext
{
    private static readonly IReadOnlySet<string> NoRoles = new HashSet<string>(StringComparer.Ordinal);

    private Guid _tenantId;
    private Guid _userId;

    public bool IsResolved { get; private set; }

    public Guid TenantId => IsResolved ? _tenantId : throw new TenantNotResolvedException();

    public Guid? BranchId { get; private set; }

    public Guid UserId => IsResolved ? _userId : throw new TenantNotResolvedException();

    public IReadOnlySet<string> Roles { get; private set; } = NoRoles;

    public IReadOnlySet<Guid> AccessibleBranchIds { get; private set; } = new HashSet<Guid>();

    public IReadOnlyDictionary<Guid, IReadOnlySet<string>> RolesByBranch { get; private set; } = new Dictionary<Guid, IReadOnlySet<string>>();

    public IReadOnlyDictionary<Guid, string> BranchTimeZones { get; private set; } = new Dictionary<Guid, string>();

    private string? _tenantTimeZone;

    /// <summary>The tenant's required zone. Throws when the resolver did not supply one (never defaulted).</summary>
    public string TenantTimeZone => IsResolved
        ? _tenantTimeZone ?? throw new Time.MissingTimeZoneException()
        : throw new TenantNotResolvedException();

    public string TimeZoneFor(Guid? branchId) =>
        Time.TenantTimeZones.Effective(
            branchId is { } b && BranchTimeZones.TryGetValue(b, out var zone) ? zone : null,
            IsResolved ? _tenantTimeZone : throw new TenantNotResolvedException());

    /// <summary>
    /// Resolves the context. <paramref name="rolesByBranch"/> is the per-branch role map; when it is
    /// null, every accessible branch gets <paramref name="roles"/> (only for callers that have no
    /// per-branch data, e.g. tests of tenant-wide behaviour).
    /// </summary>
    public void Resolve(
        Guid tenantId,
        Guid userId,
        Guid? branchId,
        IEnumerable<string> roles,
        IEnumerable<Guid> accessibleBranchIds,
        IReadOnlyDictionary<Guid, IReadOnlyCollection<string>>? rolesByBranch = null,
        IReadOnlyDictionary<Guid, string>? branchTimeZones = null,
        string? tenantTimeZone = null)
    {
        if (IsResolved)
        {
            throw new InvalidOperationException("Tenant context has already been resolved for this request.");
        }

        if (tenantId == Guid.Empty || userId == Guid.Empty)
        {
            throw new ArgumentException("Tenant and user ids must be non-empty.");
        }

        var roleSet = new HashSet<string>(roles, StringComparer.Ordinal);
        var accessible = new HashSet<Guid>(accessibleBranchIds);

        var map = new Dictionary<Guid, IReadOnlySet<string>>();
        foreach (var id in accessible)
        {
            map[id] = rolesByBranch is null
                ? roleSet
                : rolesByBranch.TryGetValue(id, out var atBranch)
                    ? new HashSet<string>(atBranch, StringComparer.Ordinal)
                    : NoRoles;
        }

        _tenantId = tenantId;
        _userId = userId;
        BranchId = branchId;
        Roles = roleSet;
        AccessibleBranchIds = accessible;
        RolesByBranch = map;
        _tenantTimeZone = string.IsNullOrWhiteSpace(tenantTimeZone) ? null : tenantTimeZone;
        BranchTimeZones = branchTimeZones is null
            ? new Dictionary<Guid, string>()
            : branchTimeZones.Where(kv => accessible.Contains(kv.Key) && !string.IsNullOrWhiteSpace(kv.Value)).ToDictionary(kv => kv.Key, kv => kv.Value);
        IsResolved = true;
    }

    public bool HasAnyRole(params string[] roles) => IsResolved && roles.Any(Roles.Contains);

    public bool CanAccessBranch(Guid branchId) => IsResolved && AccessibleBranchIds.Contains(branchId);

    public bool HasRoleAtBranch(Guid branchId, params string[] roles) =>
        IsResolved && RolesByBranch.TryGetValue(branchId, out var atBranch) && roles.Any(atBranch.Contains);
}

public sealed class TenantNotResolvedException : InvalidOperationException
{
    public TenantNotResolvedException()
        : base("No tenant has been resolved for the current request.")
    {
    }
}
