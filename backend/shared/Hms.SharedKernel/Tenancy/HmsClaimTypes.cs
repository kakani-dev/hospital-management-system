namespace Hms.SharedKernel.Tenancy;

/// <summary>
/// Claim names as issued by Supabase Auth (JWT) plus HMS custom claims added server-side
/// by a Supabase custom access token hook / app_metadata (users cannot edit app_metadata).
/// </summary>
public static class HmsClaimTypes
{
    public const string Subject = "sub";
    public const string Email = "email";
    public const string AppMetadata = "app_metadata";
    public const string TenantId = "tenant_id";
    public const string BranchId = "branch_id";
}
