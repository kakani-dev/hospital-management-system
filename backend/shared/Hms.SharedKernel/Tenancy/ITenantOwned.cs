namespace Hms.SharedKernel.Tenancy;

/// <summary>Marker for entities that belong to exactly one tenant (tenant_id column).</summary>
public interface ITenantOwned
{
    Guid TenantId { get; set; }
}
