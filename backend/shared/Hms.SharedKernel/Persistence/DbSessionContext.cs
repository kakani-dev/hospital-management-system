using System.Text.Json;

namespace Hms.SharedKernel.Persistence;

/// <summary>
/// The identity the API presents to PostgreSQL for the current request. It is built ONLY from
/// the validated JWT (user) and the server-resolved tenant context (tenant/branch). The
/// <see cref="RlsTransactionInterceptor"/> turns it into
/// <c>SET LOCAL ROLE authenticated</c> + <c>request.jwt.claims</c> for every transaction, so the
/// database's RLS policies apply to API traffic exactly as they do to PostgREST traffic.
/// </summary>
public sealed class DbSessionContext
{
    public Guid? UserId { get; private set; }
    public string? Email { get; private set; }
    public Guid? TenantId { get; private set; }
    public Guid? BranchId { get; private set; }

    public bool IsAuthenticated => UserId is not null;

    public void SetUser(Guid userId, string? email)
    {
        if (userId == Guid.Empty)
        {
            throw new ArgumentException("User id must be non-empty.", nameof(userId));
        }

        UserId = userId;
        Email = email;
    }

    /// <summary>Pins RLS to one tenant (must already be validated against memberships).</summary>
    public void SetTenant(Guid tenantId, Guid? branchId)
    {
        if (UserId is null)
        {
            throw new InvalidOperationException("Set the user before pinning a tenant.");
        }

        TenantId = tenantId;
        BranchId = branchId;
    }

    public string ToClaimsJson()
    {
        if (UserId is null)
        {
            return "{\"role\":\"anon\"}";
        }

        var claims = new Dictionary<string, object?>
        {
            ["sub"] = UserId,
            ["role"] = "authenticated",
            ["aud"] = "authenticated",
        };
        if (Email is not null)
        {
            claims["email"] = Email;
        }

        if (TenantId is not null)
        {
            claims["tenant_id"] = TenantId;
        }

        if (BranchId is not null)
        {
            claims["branch_id"] = BranchId;
        }

        return JsonSerializer.Serialize(claims);
    }
}
