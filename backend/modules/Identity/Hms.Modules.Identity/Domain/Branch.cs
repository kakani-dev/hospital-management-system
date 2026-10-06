using Hms.SharedKernel.Domain;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Identity.Domain;

public sealed class Branch : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public required string Code { get; set; }
    public required string Name { get; set; }
    public string Timezone { get; set; } = "Asia/Kolkata";
    public bool IsActive { get; set; } = true;
}
