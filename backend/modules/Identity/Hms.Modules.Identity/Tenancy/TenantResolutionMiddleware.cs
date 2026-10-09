using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace Hms.Modules.Identity.Tenancy;

/// <summary>
/// Runs after authentication. For authenticated requests it:
///   1. reads the user and requested tenant/branch from the VALIDATED token (never from headers);
///      if the token has no tenant claim (issued before the access token hook was enabled), asks
///      the database for the user's server-side default context (identity.my_active_context());
///   2. verifies an ACTIVE membership in an ACTIVE tenant (queried as the user, under RLS);
///   3. fills the scoped <see cref="TenantContext"/> (incl. the per-branch role map) and pins
///      <see cref="DbSessionContext"/> to the tenant, so every later query in the request is RLS-scoped to it;
///   4. adds the <c>X-Hms-Tenant</c> response header with the resolved tenant id.
/// It never short-circuits; endpoints opt in with <c>.RequireTenant()</c> (403 when unresolved).
/// </summary>
public sealed partial class TenantResolutionMiddleware(RequestDelegate next, ILogger<TenantResolutionMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context, TenantContext tenantContext, DbSessionContext dbSession, IMembershipStore membershipStore)
    {
        if (context.User.Identity?.IsAuthenticated != true)
        {
            await next(context);
            return;
        }

        if (!Guid.TryParse(context.User.FindFirst(HmsClaimTypes.Subject)?.Value, out var userId) || userId == Guid.Empty)
        {
            LogResolutionFailed(logger, "missing_or_invalid_subject");
            await next(context);
            return;
        }

        dbSession.SetUser(userId, context.User.FindFirst(HmsClaimTypes.Email)?.Value);

        Guid tenantId;
        Guid? branchId;
        var result = ClaimsTenantResolver.Resolve(context.User);
        if (result.Succeeded)
        {
            (tenantId, branchId) = (result.Claims!.TenantId, result.Claims.BranchId);
        }
        else if (result.Failure == "missing_tenant_claim"
                 && await membershipStore.FindDefaultContextAsync(context.RequestAborted) is { } fallback)
        {
            (tenantId, branchId) = (fallback.TenantId, fallback.BranchId);
        }
        else
        {
            LogResolutionFailed(logger, result.Failure ?? "no_membership");
            await next(context);
            return;
        }

        var grant = await membershipStore.FindActiveGrantAsync(userId, tenantId, branchId, context.RequestAborted);
        if (grant is null || grant.Roles.Count == 0)
        {
            LogNoMembership(logger, userId, tenantId);
            await next(context);
            return;
        }

        tenantContext.Resolve(tenantId, userId, branchId, grant.Roles, grant.AccessibleBranchIds, grant.RolesByBranch, grant.BranchTimeZones, grant.TenantTimeZone);
        dbSession.SetTenant(tenantId, branchId);

        // Tell the client which tenant the server acted in (review M3 option b). OnStarting so the
        // header survives handlers/exception handling that reset headers before the response starts.
        var tenantHeader = tenantId.ToString();
        context.Response.OnStarting(() =>
        {
            context.Response.Headers[HmsHeaders.Tenant] = tenantHeader;
            return Task.CompletedTask;
        });

        // Logging scope => Serilog (Enrich.FromLogContext) adds TenantId/UserId to every log line.
        using (logger.BeginScope(new Dictionary<string, object> { ["TenantId"] = tenantId, ["UserId"] = userId }))
        {
            await next(context);
        }
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Tenant resolution failed: {Reason}")]
    private static partial void LogResolutionFailed(ILogger logger, string reason);

    [LoggerMessage(Level = LogLevel.Warning, Message = "User {UserId} has no active membership in tenant {TenantId}")]
    private static partial void LogNoMembership(ILogger logger, Guid userId, Guid tenantId);
}
