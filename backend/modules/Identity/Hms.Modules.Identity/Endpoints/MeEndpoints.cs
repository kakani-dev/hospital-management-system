using Hms.Platform.Http;
using Hms.Modules.Identity.Persistence;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Hms.SharedKernel.Time;
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

        // Invitations need only an authenticated user (NOT a resolved tenant): an invitee may have
        // no active membership anywhere yet.
        api.MapGet("/me/invitations", ListMyInvitationsAsync)
            .RequireAuthorization()
            .WithDbTransaction<IdentityDbContext>()
            .WithTags("Identity")
            .WithName("ListMyInvitations")
            .WithSummary("Pending membership invitations for the current user (identity.my_invitations()).");

        api.MapPost("/me/invitations/{membershipId:guid}/accept", AcceptInvitationAsync)
            .RequireAuthorization()
            .WithDbTransaction<IdentityDbContext>()
            .WithTags("Identity")
            .WithName("AcceptInvitation")
            .WithSummary("Accept one of your pending invitations (identity.accept_membership()). 404 if it is not yours or not pending.");

        api.MapGet("/tenants/current", GetCurrentTenantAsync)
            .RequireTenant()
            .WithDbTransaction<IdentityDbContext>()
            .WithTags("Identity")
            .WithName("GetCurrentTenant");

        api.MapPatch("/tenants/current", UpdateCurrentTenantAsync)
            .RequireTenant()
            .WithDbTransaction<IdentityDbContext>()
            .WithTags("Identity")
            .WithName("UpdateCurrentTenant")
            .WithSummary("Tenant settings (tenant_admin): name and the REQUIRED IANA time zone. 409 time_zone_locked while today's queue has entries; 409 time_zone_has_future_bookings (futureBookings = N) until confirmFutureBookings = true.");

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
            var rows = await db.Branches.AsNoTracking()
                .Where(b => ids.Contains(b.Id))
                .OrderBy(b => b.Name)
                .Select(b => new { b.Id, b.Name })
                .ToListAsync(ct);
            branches = [.. rows.Select(b => new BranchOptionDto(b.Id, b.Name, tenant.TimeZoneFor(b.Id)))];
        }

        return TypedResults.Ok(new CurrentUserDto(
            userId,
            session.Email,
            tenant.IsResolved ? tenant.TenantId : null,
            tenant.IsResolved ? tenant.BranchId : null,
            tenant.IsResolved ? [.. tenant.Roles.Order(StringComparer.Ordinal)] : [],
            branches,
            memberships,
            // effective zone of the active branch (else the tenant zone): what "today" means for this user
            tenant.IsResolved ? tenant.TimeZoneFor(tenant.BranchId) : null,
            // drives the /platform console entry; grants NO tenant access (identity.is_platform_admin)
            await RawSql.ScalarAsync(db, "select identity.is_platform_admin()", ct) is true));
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

    private static async Task<Ok<List<InvitationDto>>> ListMyInvitationsAsync(IdentityDbContext db, CancellationToken ct)
    {
        var rows = await RawSql.QueryAsync(
            db,
            "select membership_id, tenant_id, tenant_name, branch_id, role, invited_at from identity.my_invitations()",
            r => new InvitationDto(
                r.GetGuid(0),
                r.GetGuid(1),
                r.GetString(2),
                r.IsDBNull(3) ? null : r.GetGuid(3),
                r.GetString(4),
                r.GetFieldValue<DateTimeOffset>(5)),
            ct);
        return TypedResults.Ok(rows);
    }

    private static async Task<Results<NoContent, NotFound>> AcceptInvitationAsync(Guid membershipId, IdentityDbContext db, CancellationToken ct)
    {
        try
        {
            await RawSql.ScalarAsync(db, "select identity.accept_membership(@id)", ct, ("id", membershipId));
            return TypedResults.NoContent();
        }
        catch (Exception ex) when (PostgresErrors.Find(ex)?.SqlState == Npgsql.PostgresErrorCodes.NoDataFound)
        {
            // Not found, not yours, or not pending: indistinguishable on purpose.
            return TypedResults.NotFound();
        }
    }

    private static async Task<Results<Ok<CurrentTenantDto>, NotFound>> GetCurrentTenantAsync(
        IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        var row = await db.Tenants.AsNoTracking().SingleOrDefaultAsync(t => t.Id == tenant.TenantId, ct);
        return row is null
            ? TypedResults.NotFound()
            : TypedResults.Ok(new CurrentTenantDto(row.Id, row.Code, row.Name, tenant.BranchId, [.. tenant.Roles.Order(StringComparer.Ordinal)], row.TimeZone));
    }

    private static async Task<Results<Ok<CurrentTenantDto>, NotFound, ValidationProblem, ProblemHttpResult>> UpdateCurrentTenantAsync(
        UpdateTenantRequest request, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return HmsProblems.Forbidden("Only tenant admins can change hospital settings.");
        }

        var errors = IdentityValidators.Validate(request);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var row = await db.Tenants.SingleOrDefaultAsync(t => t.Id == tenant.TenantId, ct);
        if (row is null)
        {
            return TypedResults.NotFound();
        }

        var zone = row.TimeZone;
        try
        {
            // Zone first (identity.change_time_zone_v1, DB re-review R5): when it needs confirmation
            // nothing is saved, including the name.
            if (request.TimeZone is not null)
            {
                var outcome = await TimeZoneChange.ApplyAsync(db, row.Id, null, request.TimeZone, request.ConfirmFutureBookings == true, ct);
                if (!outcome.Changed)
                {
                    return TimeZoneChange.NeedsConfirmation(outcome);
                }

                zone = outcome.TimeZone!; // canonical (Asia/Calcutta -> Asia/Kolkata)
            }

            if (request.Name is not null)
            {
                row.Name = request.Name.Trim();
                await db.SaveChangesAsync(ct);
            }
        }
        catch (Exception ex) when (TimeZoneChange.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(new CurrentTenantDto(row.Id, row.Code, row.Name, tenant.BranchId, [.. tenant.Roles.Order(StringComparer.Ordinal)], zone));
    }
}
