namespace Hms.Modules.Identity.Domain;

/// <summary>identity.user_profiles (global, 1:1 with auth.users). Read-only from the API.</summary>
public sealed class UserProfile
{
    public Guid Id { get; set; }
    public string? Email { get; set; }
    public string? DisplayName { get; set; }
    public Guid? ActiveTenantId { get; set; }
    public Guid? ActiveBranchId { get; set; }
}
