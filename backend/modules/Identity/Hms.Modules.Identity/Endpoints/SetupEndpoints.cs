using System.Data.Common;
using Hms.Platform.Http;
using Hms.Modules.Identity.Persistence;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Routing;

namespace Hms.Modules.Identity.Endpoints;

/// <summary>
/// Resumable hospital setup. The tenant id comes from the validated JWT
/// (<see cref="ITenantContext"/>); the request body cannot name a tenant.
/// </summary>
public static class SetupEndpoints
{
    public static RouteGroupBuilder MapSetupEndpoints(this RouteGroupBuilder api)
    {
        var setup = api.MapGroup("/setup").WithTags("Setup").RequireTenant().WithDbTransaction<IdentityDbContext>();
        setup.MapGet("/", GetSetupAsync).WithName("GetSetup")
            .WithSummary("Setup step for the signed-in tenant admin. 403 for anyone else.");
        setup.MapPost("/step", AdvanceSetupAsync).WithName("AdvanceSetup")
            .WithSummary("Move the wizard. Forward one step, or back any number. Already done is idempotent for done and 409 otherwise.");
        return api;
    }

    private static async Task<Results<Ok<SetupStateDto>, ValidationProblem, ProblemHttpResult>> GetSetupAsync(
        IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.SettingsManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can view hospital setup.");
        }

        return await ReadAsync(db, "select step, completed_on, branch_id, document_prefix from identity.setup_state_v1()", ct);
    }

    private static async Task<Results<Ok<SetupStateDto>, ValidationProblem, ProblemHttpResult>> AdvanceSetupAsync(
        AdvanceSetupRequest request, IdentityDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.SettingsManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can change hospital setup.");
        }

        var errors = IdentityValidators.Validate(request);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        return await ReadAsync(db, "select step, completed_on, branch_id, document_prefix from identity.advance_setup_v1(@step)", ct, ("step", request.Step));
    }

    private static async Task<Results<Ok<SetupStateDto>, ValidationProblem, ProblemHttpResult>> ReadAsync(
        IdentityDbContext db, string sql, CancellationToken ct, params (string Name, object? Value)[] parameters)
    {
        try
        {
            var rows = await RawSql.QueryAsync(db, sql, Map, ct, parameters);
            return rows.Count == 1
                ? TypedResults.Ok(rows[0])
                : HmsProblems.NotFound("Setup state is not available for this sign-in.");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static SetupStateDto Map(DbDataReader reader) =>
        new(
            reader.GetString(0),
            reader.IsDBNull(1) ? null : reader.GetFieldValue<DateTimeOffset>(1),
            reader.IsDBNull(2) ? null : reader.GetGuid(2),
            reader.IsDBNull(3) ? null : reader.GetString(3));
}
