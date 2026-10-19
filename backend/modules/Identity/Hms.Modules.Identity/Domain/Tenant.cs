using Hms.SharedKernel.Domain;

namespace Hms.Modules.Identity.Domain;

public sealed class Tenant : AuditableEntity
{
    public required string Code { get; set; }
    public required string Name { get; set; }
    public string Status { get; set; } = TenantStatus.Active;

    /// <summary>REQUIRED IANA zone (identity.tenants.time_zone); branches inherit it unless they override it.</summary>
    public required string TimeZone { get; set; }
}

public static class TenantStatus
{
    public const string Active = "active";
    public const string Suspended = "suspended";
    public const string Archived = "archived";
}
