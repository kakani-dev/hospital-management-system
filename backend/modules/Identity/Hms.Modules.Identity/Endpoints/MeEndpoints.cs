using Hms.Modules.Identity.Persistence;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Identity.Endpoints;

public static class MeEndpoints
{
    public static RouteGroupBuilder MapMeEndpoints(this RouteGroupBuilder api)
    {
        api.MapGet("/me", GetCurrentUserAsync)
            .RequireAuthorization()
            .WithDbTransaction<IdentityDbContext>()
            .WithTags("Identity")
            .WithName("GetCurrentUser")
            .WithSummary("Current user, resolved tenant/branch and all memberships (drives the switcher).");

        api.MapPost("/me/context", SwitchContextAsync)
            .RequireAuthorization()
            .WithDbTransaction<IdentityDbContext>()
            .WithTags("Identity")
            .WithName("SwitchContext")
            .WithSummary("Switch active tenant/branch. Validated against memberships in the database; refresh the session afterwards to get a token with the new tenant.");

        api.MapGet("/tenants/current", GetCurrentTenantAsync)
            .RequireTenant()
            .WithDbTransaction<IdentityDbContext>()
            .WithTags("Identity")
            .WithName("GetCurrentTenant");

        return api;
    }

    private static async Task<Results<Ok<CurrentUserDto>, UnauthorizedHttpResult>> GetCurrentUserAsync(
        IdentityDbContext db, DbSessionContext session, ITenantContext tenant, CancellationToken ct)
    {
        if (session.UserId is not { } userId)
        {
            return TypedResults.Unauthorized();
        }

        var memberships = await RawSql.QueryAsync(
            db,
            "select tenant_id, tenant_name, branch_id, branch_name, role from identity.my_memberships()",
            r => new MembershipDto(r.GetGuid(0), r.GetString(1), r.IsDBNull(2) ? null : r.GetGuid(2), r.IsDBNull(3) ? null : r.GetString(3), r.GetString(4)),
            ct);

        IReadOnlyList<BranchOptionDto> branches = [];
        if (tenant.IsResolved)
        {
            var ids = tenant.AccessibleBranchIds.ToList();
            branches = await db.Branches.AsNoTracking()
                .Where(b => ids.Contains(b.Id))
                .OrderBy(b => b.Name)
                .Select(b => new BranchOptionDto(b.Id, b.Name))
                .ToListAsync(ct);
        }

        return TypedResults.Ok(new CurrentUserDto(
            userId,
            session.Email,
            tenant.IsResolved ? tenant.TenantId : null,
            tenant.IsResolved ? tenant.BranchId : null,
            tenant.IsResolved ? [.. tenant.Roles.Order(StringComparer.Ordinal)] : [],
            branches,
            memberships));
    }

    private static async Task<Results<NoContent, ProblemHttpResult>> SwitchContextAsync(
        SwitchContextRequest request, IdentityDbContext db, CancellationToken ct)
    {
        try
        {
            await RawSql.ScalarAsync(db, "select identity.set_active_context(@tenant, @branch)", ct, ("tenant", request.TenantId), ("branch", request.BranchId));
            return TypedResults.NoContent();
        }
        catch (Exception ex) when (PostgresErrors.Find(ex)?.SqlState == Npgsql.PostgresErrorCodes.InsufficientPrivilege)
        {
            return TypedResults.Problem(
                title: "Forbidden",
                detail: "You have no active membership for that hospital/branch.",
                statusCode: StatusCodes.Status403Forbidden);
        }
    }

    private static async Task<Results<Ok<CurrentTenantDto>, NotFound>> GetCurrentTenantAsync(
        IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        var row = await db.Tenants.AsNoTracking().SingleOrDefaultAsync(t => t.Id == tenant.TenantId, ct);
        return row is null
            ? TypedResults.NotFound()
            : TypedResults.Ok(new CurrentTenantDto(row.Id, row.Code, row.Name, tenant.BranchId, [.. tenant.Roles.Order(StringComparer.Ordinal)]));
    }
}
