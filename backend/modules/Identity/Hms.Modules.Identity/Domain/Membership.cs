using Hms.SharedKernel.Domain;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Identity.Domain;

/// <summary>A user's role in a tenant, optionally restricted to one branch (BranchId null = all branches).</summary>
public sealed class Membership : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public Guid UserId { get; set; }
    public Guid? BranchId { get; set; }
    public required string Role { get; set; }
    public string Status { get; set; } = MembershipStatus.Active;
}

public static class MembershipStatus
{
    public const string Active = "active";
    public const string Invited = "invited";
    public const string Suspended = "suspended";
}
