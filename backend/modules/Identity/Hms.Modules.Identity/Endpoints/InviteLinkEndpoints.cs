using Hms.Modules.Identity.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Routing;

namespace Hms.Modules.Identity.Endpoints;

/// <summary>
/// Invite links: a tenant admin issues a single-use, expiring link for an email (works whether or not
/// the person has an account yet, and reveals nothing about accounts). The invitee opens it, signs in
/// with THAT email and claims it. No email provider is configured, so the admin copies the link.
/// </summary>
public static class InviteLinkEndpoints
{
    public static RouteGroupBuilder MapInviteLinkEndpoints(this RouteGroupBuilder api)
    {
        var links = api.MapGroup("/members/invite-links").WithTags("Tenant admin").RequireTenant().WithDbTransaction<IdentityDbContext>();
        links.MapGet("/", ListAsync).WithName("ListInviteLinks");
        links.MapPost("/", CreateAsync).WithName("CreateInviteLink");
        links.MapDelete("/{id:guid}", RevokeAsync).WithName("RevokeInviteLink");

        api.MapPost("/me/invite-links/claim", ClaimAsync)
            .RequireAuthorization()
            .WithDbTransaction<IdentityDbContext>()
            .WithTags("Identity")
            .WithName("ClaimInviteLink")
            .WithSummary("Claim an invite link as the signed-in user (email must match). 404 unknown/used/expired, 403 invite_email_mismatch.");
        return api;
    }

    private static async Task<Results<Ok<List<InviteLinkDto>>, ProblemHttpResult>> ListAsync(IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage invites.");
        }

        var rows = await RawSql.QueryAsync(
            db,
            "select id, email, role, branch_id, status, expires_on, created_on, claimed_on from identity.list_member_invite_links(@tenant)",
            r => new InviteLinkDto(r.GetGuid(0), r.GetString(1), r.GetString(2), r.IsDBNull(3) ? null : r.GetGuid(3), r.GetString(4),
                r.GetFieldValue<DateTimeOffset>(5), r.GetFieldValue<DateTimeOffset>(6), r.IsDBNull(7) ? null : r.GetFieldValue<DateTimeOffset>(7)),
            ct,
            ("tenant", tenant.TenantId));
        return TypedResults.Ok(rows);
    }

    private static async Task<Results<Created<InviteLinkIssuedDto>, ValidationProblem, ProblemHttpResult>> CreateAsync(
        CreateInviteLinkRequest request, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage invites.");
        }

        var errors = IdentityValidators.Validate(new AddMemberRequest(request.Email, request.Role, request.BranchId));
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (request.BranchId is { } branchId && !tenant.CanAccessBranch(branchId))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["branchId"] = ["Branch does not belong to this hospital."] });
        }

        try
        {
            var rows = await RawSql.QueryAsync(
                db,
                "select id, token, expires_on from identity.create_member_invite_link(@tenant, @email, @role, @branch)",
                r => PlatformEndpoints.Issued(r.GetGuid(0), r.GetString(1), r.GetFieldValue<DateTimeOffset>(2)),
                ct,
                ("tenant", tenant.TenantId),
                ("email", request.Email!.Trim()),
                ("role", request.Role),
                ("branch", request.BranchId));
            return TypedResults.Created($"/api/v1/members/invite-links/{rows[0].Id}", rows[0]);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<Results<NoContent, ProblemHttpResult>> RevokeAsync(Guid id, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(HmsRoles.TenantAdmin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage invites.");
        }

        try
        {
            await RawSql.ScalarAsync(db, "select identity.revoke_invite_link(@tenant, @id)", ct, ("tenant", tenant.TenantId), ("id", id));
            return TypedResults.NoContent();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<Results<Ok<ClaimedInviteDto>, NotFound, ProblemHttpResult>> ClaimAsync(
        ClaimInviteRequest request, IdentityDbContext db, CancellationToken ct)
    {
        if (request.Token is null || !PlatformEndpoints.TokenPattern().IsMatch(request.Token))
        {
            return TypedResults.NotFound();
        }

        try
        {
            var rows = await RawSql.QueryAsync(
                db,
                "select tenant_id, tenant_name, role, branch_id from identity.claim_invite_link(@token)",
                r => new ClaimedInviteDto(r.GetGuid(0), r.GetString(1), r.GetString(2), r.IsDBNull(3) ? null : r.GetGuid(3)),
                ct,
                ("token", request.Token));
            return TypedResults.Ok(rows[0]);
        }
        catch (Exception ex) when (HmsProblems.FindDbError(ex) is { SqlState: "42501" } db42501 && db42501.Message.Contains("invite_email_mismatch", StringComparison.Ordinal))
        {
            return TypedResults.Problem(title: "Forbidden", detail: "This invite is for a different email address. Sign in with the invited email.",
                statusCode: StatusCodes.Status403Forbidden, extensions: new Dictionary<string, object?> { ["code"] = "invite_email_mismatch" });
        }
        catch (Exception ex) when (HmsProblems.FindDbError(ex)?.SqlState == HmsProblems.SqlStates.NoDataFound)
        {
            return TypedResults.NotFound();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }
}
