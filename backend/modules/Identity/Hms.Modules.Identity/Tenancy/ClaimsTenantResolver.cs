using System.Security.Claims;
using System.Text.Json;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Identity.Tenancy;

public sealed record TenantClaims(Guid UserId, Guid TenantId, Guid? BranchId);

public sealed record TenantResolutionResult(TenantClaims? Claims, string? Failure)
{
    public bool Succeeded => Claims is not null;

    public static TenantResolutionResult Success(TenantClaims claims) => new(claims, null);

    public static TenantResolutionResult Fail(string reason) => new(null, reason);
}

/// <summary>
/// Extracts the user and requested tenant/branch from an AUTHENTICATED principal (signed JWT).
/// Pure function: no I/O. Membership is validated separately against the database.
///
/// Supported shapes (Supabase):
///   * top-level "tenant_id"/"branch_id" claims (custom access token hook), or
///   * "app_metadata": { "tenant_id": "...", "branch_id": "..." } (server-controlled; users cannot edit it).
/// Client-controlled sources (headers, query strings, bodies, user_metadata) are deliberately ignored.
/// </summary>
public static class ClaimsTenantResolver
{
    public static TenantResolutionResult Resolve(ClaimsPrincipal? principal)
    {
        if (principal?.Identity?.IsAuthenticated != true)
        {
            return TenantResolutionResult.Fail("unauthenticated");
        }

        var sub = principal.FindFirst(HmsClaimTypes.Subject)?.Value ?? principal.FindFirst(ClaimTypes.NameIdentifier)?.Value;
        if (!Guid.TryParse(sub, out var userId) || userId == Guid.Empty)
        {
            return TenantResolutionResult.Fail("missing_or_invalid_subject");
        }

        var appMetadata = ReadAppMetadata(principal);

        var tenantRaw = principal.FindFirst(HmsClaimTypes.TenantId)?.Value ?? GetString(appMetadata, HmsClaimTypes.TenantId);
        if (string.IsNullOrWhiteSpace(tenantRaw))
        {
            return TenantResolutionResult.Fail("missing_tenant_claim");
        }

        if (!Guid.TryParse(tenantRaw, out var tenantId) || tenantId == Guid.Empty)
        {
            return TenantResolutionResult.Fail("invalid_tenant_claim");
        }

        Guid? branchId = null;
        var branchRaw = principal.FindFirst(HmsClaimTypes.BranchId)?.Value ?? GetString(appMetadata, HmsClaimTypes.BranchId);
        if (!string.IsNullOrWhiteSpace(branchRaw))
        {
            if (!Guid.TryParse(branchRaw, out var parsedBranch) || parsedBranch == Guid.Empty)
            {
                return TenantResolutionResult.Fail("invalid_branch_claim");
            }

            branchId = parsedBranch;
        }

        return TenantResolutionResult.Success(new TenantClaims(userId, tenantId, branchId));
    }

    private static JsonElement? ReadAppMetadata(ClaimsPrincipal principal)
    {
        var raw = principal.FindFirst(HmsClaimTypes.AppMetadata)?.Value;
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(raw);
            return doc.RootElement.ValueKind == JsonValueKind.Object ? doc.RootElement.Clone() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? GetString(JsonElement? element, string property) =>
        element is { } e && e.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}
