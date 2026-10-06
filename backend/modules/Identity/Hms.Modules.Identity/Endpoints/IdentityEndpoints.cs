using Hms.Modules.Identity.Domain;
using Hms.Modules.Identity.Persistence;
using Hms.Modules.Identity.Tenancy;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Identity.Endpoints;

public sealed record MembershipDto(Guid TenantId, string TenantName, Guid? BranchId, string? BranchName, string Role);

public sealed record CurrentUserDto(Guid UserId, string? Email, Guid? ActiveTenantId, Guid? ActiveBranchId, IReadOnlyList<MembershipDto> Memberships);

public sealed record CurrentTenantDto(Guid Id, string Code, string Name, Guid? ActiveBranchId, IReadOnlyList<string> Roles);

public static class IdentityEndpoints
{
    public static RouteGroupBuilder MapIdentityEndpoints(this RouteGroupBuilder api)
    {
        api.MapGet("/me", GetCurrentUserAsync)
            .RequireAuthorization()
            .WithTags("Identity")
            .WithName("GetCurrentUser")
            .WithSummary("Current user and their active memberships (server-side source of truth for tenant/branch pickers).");

        api.MapGet("/tenants/current", GetCurrentTenantAsync)
            .RequireTenant()
            .WithTags("Identity")
            .WithName("GetCurrentTenant");

        return api;
    }

    private static async Task<Results<Ok<CurrentUserDto>, UnauthorizedHttpResult>> GetCurrentUserAsync(
        HttpContext http, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        var sub = http.User.FindFirst(HmsClaimTypes.Subject)?.Value;
        if (!Guid.TryParse(sub, out var userId))
        {
            return TypedResults.Unauthorized();
        }

        var memberships = await (
                from m in db.Memberships.AsNoTracking()
                join t in db.Tenants.AsNoTracking() on m.TenantId equals t.Id
                join b in db.Branches.AsNoTracking() on m.BranchId equals (Guid?)b.Id into branches
                from b in branches.DefaultIfEmpty()
                where m.UserId == userId && m.Status == MembershipStatus.Active && t.Status == TenantStatus.Active
                orderby t.Name
                select new MembershipDto(t.Id, t.Name, m.BranchId, b != null ? b.Name : null, m.Role))
            .ToListAsync(ct);

        return TypedResults.Ok(new CurrentUserDto(
            userId,
            http.User.FindFirst(HmsClaimTypes.Email)?.Value,
            tenant.IsResolved ? tenant.TenantId : null,
            tenant.IsResolved ? tenant.BranchId : null,
            memberships));
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
