using Hms.Modules.Identity.Domain;
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

        var members = api.MapGroup("/members").WithTags("Tenant admin").RequireTenant().WithDbTransaction<IdentityDbContext>();
        members.MapGet("/", ListMembersAsync).WithName("ListMembers");
        members.MapPost("/", AddMemberAsync).WithName("AddMember");
        members.MapPatch("/{id:guid}", UpdateMemberAsync).WithName("UpdateMember");

        return api;
    }

    private static ProblemHttpResult AdminOnly() =>
        TypedResults.Problem(title: "Forbidden", detail: "Only tenant admins can manage branches and members.", statusCode: StatusCodes.Status403Forbidden);

    private static BranchDto ToDto(Branch b) => new(b.Id, b.Code, b.Name, b.Timezone, b.IsActive);

    // Any member may list branches of their tenant (needed for forms); admins see inactive ones too.
    private static async Task<Ok<List<BranchDto>>> ListBranchesAsync(IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        var isAdmin = tenant.HasAnyRole(HmsRoles.TenantAdmin);
        var rows = await db.Branches.AsNoTracking()
            .Where(b => b.TenantId == tenant.TenantId && (isAdmin || b.IsActive))
            .OrderBy(b => b.Name)
            .ToListAsync(ct);
        return TypedResults.Ok(rows.Select(ToDto).ToList());
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
        var branch = new Branch { Code = request.Code!, Name = request.Name!.Trim(), Timezone = request.Timezone ?? "Asia/Kolkata" };
        db.Branches.Add(branch);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex) when (PostgresErrors.ToProblem(ex, "A branch with this code already exists in this hospital.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/branches/{branch.Id}", ToDto(branch));
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

        if (request.Name is not null)
        {
            branch.Name = request.Name.Trim();
        }

        if (request.Timezone is not null)
        {
            branch.Timezone = request.Timezone;
        }

        if (request.IsActive is { } active)
        {
            branch.IsActive = active;
        }

        await db.SaveChangesAsync(ct);
        return TypedResults.Ok(ToDto(branch));
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
                where m.TenantId == tenant.TenantId
                join p in db.UserProfiles.AsNoTracking() on m.UserId equals p.Id into profiles
                from p in profiles.DefaultIfEmpty()
                join b in db.Branches.AsNoTracking() on m.BranchId equals (Guid?)b.Id into branches
                from b in branches.DefaultIfEmpty()
                orderby p.Email, m.Role
                select new MemberDto(m.Id, m.UserId, p != null ? p.Email : null, p != null ? p.DisplayName : null, m.Role, m.BranchId, b != null ? b.Name : null, m.Status))
            .ToListAsync(ct);
        return TypedResults.Ok(rows);
    }

    private static async Task<Results<Created<MemberDto>, ValidationProblem, ProblemHttpResult>> AddMemberAsync(
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

        Guid id;
        try
        {
            id = (Guid)(await RawSql.ScalarAsync(
                db,
                "select identity.add_member(@tenant, @email, @role, @branch)",
                ct,
                ("tenant", tenant.TenantId),
                ("email", request.Email!.Trim()),
                ("role", request.Role),
                ("branch", request.BranchId)))!;
        }
        catch (Exception ex) when (PostgresErrors.ToProblem(ex, "That person already has this membership.") is { } problem)
        {
            return problem;
        }

        var created = await (
                from m in db.Memberships.AsNoTracking()
                where m.Id == id
                join p in db.UserProfiles.AsNoTracking() on m.UserId equals p.Id into profiles
                from p in profiles.DefaultIfEmpty()
                select new MemberDto(m.Id, m.UserId, p != null ? p.Email : null, p != null ? p.DisplayName : null, m.Role, m.BranchId, null, m.Status))
            .SingleAsync(ct);
        return TypedResults.Created($"/api/v1/members/{id}", created);
    }

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

        var membership = await db.Memberships.SingleOrDefaultAsync(m => m.Id == id && m.TenantId == tenant.TenantId, ct);
        if (membership is null)
        {
            return TypedResults.NotFound();
        }

        if (membership.UserId == tenant.UserId)
        {
            return TypedResults.Problem(title: "Not allowed", detail: "You cannot change your own membership (prevents admin lock-out).", statusCode: StatusCodes.Status409Conflict);
        }

        membership.Role = request.Role ?? membership.Role;
        membership.Status = request.Status ?? membership.Status;
        await db.SaveChangesAsync(ct);

        var email = await db.UserProfiles.AsNoTracking().Where(p => p.Id == membership.UserId).Select(p => p.Email).SingleOrDefaultAsync(ct);
        return TypedResults.Ok(new MemberDto(membership.Id, membership.UserId, email, null, membership.Role, membership.BranchId, null, membership.Status));
    }
}
