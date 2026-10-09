using Hms.SharedKernel.Domain;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Identity.Domain;

public sealed class Branch : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public required string Code { get; set; }
    public required string Name { get; set; }
    /// <summary>Optional IANA override of the tenant zone; null = inherit identity.tenants.time_zone.</summary>
    public string? Timezone { get; set; }
    public bool IsActive { get; set; } = true;
}
