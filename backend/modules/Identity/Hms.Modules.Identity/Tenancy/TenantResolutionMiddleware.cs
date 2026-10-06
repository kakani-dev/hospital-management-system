using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace Hms.Modules.Identity.Tenancy;

/// <summary>
/// Runs after authentication. For authenticated requests it:
///   1. reads user + requested tenant/branch from the validated token claims (never from headers);
///   2. verifies an ACTIVE membership in an ACTIVE tenant in identity.memberships;
///   3. populates the scoped <see cref="TenantContext"/> and enriches logs with tenant/user ids.
/// It never short-circuits; endpoints opt in with <c>.RequireTenant()</c> which returns 403
/// when the context is not resolved.
/// </summary>
public sealed partial class TenantResolutionMiddleware(RequestDelegate next, ILogger<TenantResolutionMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context, TenantContext tenantContext, IMembershipStore membershipStore)
    {
        if (context.User.Identity?.IsAuthenticated != true)
        {
            await next(context);
            return;
        }

        var result = ClaimsTenantResolver.Resolve(context.User);
        if (!result.Succeeded)
        {
            LogResolutionFailed(logger, result.Failure!);
            await next(context);
            return;
        }

        var claims = result.Claims!;
        var grant = await membershipStore.FindActiveGrantAsync(claims.UserId, claims.TenantId, claims.BranchId, context.RequestAborted);
        if (grant is null || grant.Roles.Count == 0)
        {
            LogNoMembership(logger, claims.UserId, claims.TenantId);
            await next(context);
            return;
        }

        tenantContext.Resolve(claims.TenantId, claims.UserId, claims.BranchId, grant.Roles, grant.AccessibleBranchIds);

        // Logging scope => Serilog (Enrich.FromLogContext) adds TenantId/UserId to every log line.
        using (logger.BeginScope(new Dictionary<string, object> { ["TenantId"] = claims.TenantId, ["UserId"] = claims.UserId }))
        {
            await next(context);
        }
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Tenant resolution failed: {Reason}")]
    private static partial void LogResolutionFailed(ILogger logger, string reason);

    [LoggerMessage(Level = LogLevel.Warning, Message = "User {UserId} has no active membership in tenant {TenantId}")]
    private static partial void LogNoMembership(ILogger logger, Guid userId, Guid tenantId);
}
