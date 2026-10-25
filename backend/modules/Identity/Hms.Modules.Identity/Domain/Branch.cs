using Hms.SharedKernel.Domain;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Identity.Domain;

public sealed class Branch : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public required string Code { get; set; }
    public required string Name { get; set; }
    /// <summary>
    /// Optional IANA override of the tenant zone; null = inherit identity.tenants.time_zone. Mapped to
    /// identity.branches.timezone_override (code review MAJ-1: the legacy timezone column is a
    /// DB-maintained mirror of the effective zone for readers built before the migration).
    /// </summary>
    public string? Timezone { get; set; }
    public bool IsActive { get; set; } = true;

    /// <summary>Optional street address (identity.branches.address). Null when the hospital has not set one.</summary>
    public string? Address { get; set; }
}
