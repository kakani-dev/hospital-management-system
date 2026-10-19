using Hms.Platform.Http;
using Hms.Modules.Identity.Domain;
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
using Npgsql;

namespace Hms.Modules.Identity.Endpoints;

/// <summary>
/// Branch and membership administration for the RESOLVED tenant. Every operation is checked
/// twice: tenant_admin role in the API, and RLS/SQL functions in the database.
/// </summary>
public static class TenantAdminEndpoints
{
    public static RouteGroupBuilder MapTenantAdminEndpoints(this RouteGroupBuilder api)
    {
        var branches = api.MapGroup("/branches").WithTags("Tenant admin").RequireTenant().WithDbTransaction<IdentityDbContext>();
        branches.MapGet("/", ListBranchesAsync).WithName("ListBranches");
        branches.MapPost("/", CreateBranchAsync).WithName("CreateBranch");
        branches.MapPatch("/{id:guid}", UpdateBranchAsync).WithName("UpdateBranch");
        branches.MapDelete("/{id:guid}", DeleteBranchAsync).WithName("DeleteBranch")
            .WithSummary("Soft delete (identity.soft_delete_branch). 409 for the last branch or one with open appointments/queue entries.");
        branches.MapPost("/{id:guid}/restore", RestoreBranchAsync).WithName("RestoreBranch")
            .WithSummary("Restore a soft-deleted branch (comes back inactive).");

        var members = api.MapGroup("/members").WithTags("Tenant admin").RequireTenant().WithDbTransaction<IdentityDbContext>();
        members.MapGet("/", ListMembersAsync).WithName("ListMembers");
        members.MapPost("/", AddMemberAsync).WithName("AddMember");
        members.MapPatch("/{id:guid}", UpdateMemberAsync).WithName("UpdateMember");
        members.MapDelete("/{id:guid}", DeleteMemberAsync).WithName("DeleteMember")
            .WithSummary("Soft delete (identity.soft_delete_membership): the membership grants nothing afterwards.");
        members.MapPost("/{id:guid}/restore", RestoreMemberAsync).WithName("RestoreMember");

        return api;
    }

    private static ProblemHttpResult AdminOnly() =>
        TypedResults.Problem(title: "Forbidden", detail: "Only tenant admins can manage branches and members.", statusCode: StatusCodes.Status403Forbidden);

    private static BranchDto ToDto(Branch b, string tenantZone) =>
        new(b.Id, b.Code, b.Name, TenantTimeZones.Effective(b.Timezone, tenantZone), b.IsActive, b.Timezone, b.IsDeleted);

    // Any member may list branches of their tenant (needed for forms); admins see inactive ones too,
    // and deleted ones with ?includeDeleted=true (to restore them).
    private static async Task<Ok<List<BranchDto>>> ListBranchesAsync(IdentityDbContext db, ITenantContext tenant, bool? includeDeleted, CancellationToken ct)
    {
        var isAdmin = tenant.HasAnyRole(HmsRoles.TenantAdmin);
        var query = db.Branches.AsNoTracking();
        if (isAdmin && includeDeleted == true)
        {
            query = query.IgnoreQueryFilters();
        }

        var rows = await query
            .Where(b => b.TenantId == tenant.TenantId && (isAdmin || b.IsActive))
            .OrderBy(b => b.Name)
            .ToListAsync(ct);
        var zone = await TenantZoneAsync(db, tenant, ct);
        return TypedResults.Ok(rows.Select(b => ToDto(b, zone)).ToList());
    }

    private static async Task<string> TenantZoneAsync(IdentityDbContext db, ITenantContext tenant, CancellationToken ct) =>
        await db.Tenants.AsNoTracking().Where(t => t.Id == tenant.TenantId).Select(t => t.TimeZone).FirstOrDefaultAsync(ct)
        ?? tenant.TenantTimeZone;

    private static async Task<Results<NoContent, ProblemHttpResult>> DeleteBranchAsync(Guid id, IdentityDbContext db, ITenantContext tenant, CancellationToken ct) =>
        await SoftDeleteAsync(db, tenant, "select identity.soft_delete_branch(@id)", id, "Only tenant admins can manage branches and members.", ct);

    private static async Task<Results<NoContent, ProblemHttpResult>> RestoreBranchAsync(Guid id, IdentityDbContext db, ITenantContext tenant, CancellationToken ct) =>
        await SoftDeleteAsync(db, tenant, "select identity.restore_branch(@id)", id, "Only tenant admins can manage branches and members.", ct);

    private static async Task<Results<NoContent, ProblemHttpResult>> DeleteMemberAsync(Guid id, IdentityDbContext db, ITenantContext tenant, CancellationToken ct) =>
        await SoftDeleteAsync(db, tenant, "select identity.soft_delete_membership(@id)", id, "Only tenant admins can manage branches and members.", ct);

    private static async Task<Results<NoContent, ProblemHttpResult>> RestoreMemberAsync(Guid id, IdentityDbContext db, ITenantContext tenant, CancellationToken ct) =>
        await SoftDeleteAsync(db, tenant, "select identity.restore_membership(@id)", id, "Only tenant admins can manage branches and members.", ct);

    /// <summary>
    /// Soft delete / restore through the SQL functions (they own is_deleted). The DB decides
    /// 404 (unknown / other tenant / wrong state), 403 (not admin) and 409 (business conflict).
    /// </summary>
    internal static async Task<Results<NoContent, ProblemHttpResult>> SoftDeleteAsync(
        DbContext db, ITenantContext tenant, string sql, Guid id, string forbiddenDetail, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return HmsProblems.Forbidden(forbiddenDetail);
        }

        try
        {
            await RawSql.ScalarAsync(db, sql, ct, ("id", id));
            return TypedResults.NoContent();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "A live record with the same key already exists.") is { } problem)
        {
            return problem;
        }
    }

    private static async Task<Results<Created<BranchDto>, ValidationProblem, ProblemHttpResult>> CreateBranchAsync(
        CreateBranchRequest request, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return AdminOnly();
        }

        var errors = IdentityValidators.Validate(request);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (await db.Branches.AnyAsync(b => b.TenantId == tenant.TenantId && b.Code == request.Code, ct))
        {
            return TypedResults.Problem(title: "Conflict", detail: "A branch with this code already exists in this hospital.", statusCode: StatusCodes.Status409Conflict);
        }

        // TenantId is set by TenantSaveChangesInterceptor; RLS (branches_insert_admin) re-checks it.
        // Timezone null = inherit the tenant zone (no override).
        var branch = new Branch { Code = request.Code!, Name = request.Name!.Trim(), Timezone = TenantTimeZones.Canonicalize(request.Timezone) };
        db.Branches.Add(branch);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex) when (PostgresErrors.ToProblem(ex, "A branch with this code already exists in this hospital.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/branches/{branch.Id}", ToDto(branch, await TenantZoneAsync(db, tenant, ct)));
    }

    private static async Task<Results<Ok<BranchDto>, NotFound, ValidationProblem, ProblemHttpResult>> UpdateBranchAsync(
        Guid id, UpdateBranchRequest request, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return AdminOnly();
        }

        var errors = IdentityValidators.Validate(request);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        // Another tenant's branch id is indistinguishable from a missing one.
        var branch = await db.Branches.SingleOrDefaultAsync(b => b.Id == id && b.TenantId == tenant.TenantId, ct);
        if (branch is null)
        {
            return TypedResults.NotFound();
        }

        try
        {
            // Zone first (identity.change_time_zone_v1, DB re-review R5): when it needs confirmation
            // nothing is saved. 55000 time_zone_locked (today's queue) -> 409.
            if (request.InheritTimezone == true || request.Timezone is not null)
            {
                var zone = request.InheritTimezone == true ? null : request.Timezone;
                var outcome = await TimeZoneChange.ApplyAsync(db, tenant.TenantId, branch.Id, zone, request.ConfirmFutureBookings == true, ct);
                if (!outcome.Changed)
                {
                    return TimeZoneChange.NeedsConfirmation(outcome);
                }

                // keep the tracked entity in step without EF sending the column (AfterSave Ignore)
                var property = db.Entry(branch).Property(b => b.Timezone);
                property.CurrentValue = outcome.TimeZone;
                property.OriginalValue = outcome.TimeZone;
                property.IsModified = false;
            }

            if (request.Name is not null)
            {
                branch.Name = request.Name.Trim();
            }

            if (request.IsActive is { } active)
            {
                branch.IsActive = active;
            }

            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (TimeZoneChange.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(ToDto(branch, await TenantZoneAsync(db, tenant, ct)));
    }

    private static async Task<Results<Ok<List<MemberDto>>, ProblemHttpResult>> ListMembersAsync(
        IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return AdminOnly();
        }

        var rows = await (
                from m in db.Memberships.AsNoTracking()
                // Pending invitations are hidden: listing them would reveal which emails have accounts.
                where m.TenantId == tenant.TenantId && m.Status != MembershipStatus.Invited
                join p in db.UserProfiles.AsNoTracking() on m.UserId equals p.Id into profiles
                from p in profiles.DefaultIfEmpty()
                join b in db.Branches.AsNoTracking() on m.BranchId equals (Guid?)b.Id into branches
                from b in branches.DefaultIfEmpty()
                orderby p.Email, m.Role
                select new MemberDto(m.Id, m.UserId, p != null ? p.Email : null, p != null ? p.DisplayName : null, m.Role, m.BranchId, b != null ? b.Name : null, m.Status))
            .ToListAsync(ct);
        return TypedResults.Ok(rows);
    }

    /// <summary>
    /// Invites an existing platform user to the RESOLVED tenant. Always answers 202 with the same
    /// body whether the email has no account, was invited, or is already a member (no account
    /// enumeration, review B1). The membership is created as 'invited' by identity.add_member()
    /// and only the invitee can activate it (POST /api/v1/me/invitations/{id}/accept).
    /// Validation errors stay 400; authorization failures stay 403.
    /// </summary>
    private static async Task<Results<Accepted<AddMemberAcceptedDto>, ValidationProblem, ProblemHttpResult>> AddMemberAsync(
        AddMemberRequest request, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return AdminOnly();
        }

        var errors = IdentityValidators.Validate(request);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (request.BranchId is { } branchId && !tenant.CanAccessBranch(branchId))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["branchId"] = ["Branch does not belong to this hospital."] });
        }

        // Savepoint: if the function raises, roll back just this statement so the request
        // transaction can still commit and every outcome looks identical to the caller.
        var tx = db.Database.CurrentTransaction;
        if (tx is not null)
        {
            await tx.CreateSavepointAsync(AddMemberSavepoint, ct);
        }

        try
        {
            // Contract: returns the new invited membership id, the EXISTING membership id when the
            // user is already a member, or NULL when no account exists. The id is deliberately not
            // returned to the client.
            await RawSql.ScalarAsync(
                db,
                "select identity.add_member(@tenant, @email, @role, @branch)",
                ct,
                ("tenant", tenant.TenantId),
                ("email", request.Email!.Trim()),
                ("role", request.Role),
                ("branch", request.BranchId));
        }
        catch (Exception ex) when (PostgresErrors.Find(ex)?.SqlState is PostgresErrorCodes.NoDataFound or PostgresErrorCodes.UniqueViolation)
        {
            // Older add_member versions raised for "no account" (P0002) / "already a member" (23505).
            // Map both to the same 202 so no version of the DB function can leak account existence.
            if (tx is not null)
            {
                await tx.RollbackToSavepointAsync(AddMemberSavepoint, ct);
            }
        }
        catch (Exception ex) when (PostgresErrors.ToProblem(ex, "That person already has this membership.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Accepted((string?)null, AddMemberAcceptedDto.Instance);
    }

    private const string AddMemberSavepoint = "hms_add_member";

    private static async Task<Results<Ok<MemberDto>, NotFound, ValidationProblem, ProblemHttpResult>> UpdateMemberAsync(
        Guid id, UpdateMemberRequest request, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return AdminOnly();
        }

        var errors = IdentityValidators.Validate(request);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        // Invited memberships are not visible to admins (that would reveal that the account exists)
        // and only the invitee may activate them, so they are treated as not found here.
        var membership = await db.Memberships.SingleOrDefaultAsync(
            m => m.Id == id && m.TenantId == tenant.TenantId && m.Status != MembershipStatus.Invited, ct);
        if (membership is null)
        {
            return TypedResults.NotFound();
        }

        var branchId = request.AllBranches == true ? null : request.BranchId ?? membership.BranchId;
        if (request.BranchId is { } target && !tenant.BranchTimeZones.ContainsKey(target))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["branchId"] = ["Branch does not belong to this hospital."] });
        }

        if ((request.Role ?? membership.Role) == HmsRoles.TenantAdmin && branchId is not null)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { [request.Role is null ? "branchId" : "role"] = [IdentityValidators.TenantAdminIsTenantWide] });
        }

        if (membership.UserId == tenant.UserId)
        {
            return TypedResults.Problem(title: "Not allowed", detail: "You cannot change your own membership (prevents admin lock-out).", statusCode: StatusCodes.Status409Conflict);
        }

        membership.Role = request.Role ?? membership.Role;
        membership.Status = request.Status ?? membership.Status;
        membership.BranchId = branchId;
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex) when (PostgresErrors.ToProblem(ex, "That person already has a membership for this branch scope.") is { } problem)
        {
            return problem;
        }

        var email = await db.UserProfiles.AsNoTracking().Where(p => p.Id == membership.UserId).Select(p => p.Email).SingleOrDefaultAsync(ct);
        return TypedResults.Ok(new MemberDto(membership.Id, membership.UserId, email, null, membership.Role, membership.BranchId, null, membership.Status));
    }
}
