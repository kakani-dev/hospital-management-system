using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Functions;
using Hms.Modules.Appointments.Persistence;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Tenancy;
using Hms.SharedKernel.Time;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Appointments.Endpoints;

/// <summary>
/// OPD queue (2.3): branch-scoped board (D10), walk-in check-in (D11) and status changes. All queue
/// writes go through the DB RPCs; the API adds the branch-role binding (D9).
/// </summary>
public static class QueueEndpoints
{
    public static RouteGroupBuilder MapQueueEndpoints(this RouteGroupBuilder api)
    {
        var group = api.MapGroup("/queue").WithTags("OPD queue").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        group.MapGet("/", BoardAsync).WithName("GetQueueBoard")
            .WithSummary("Queue for one branch and branch-local day (default today), ordered by token.");
        group.MapPost("/walk-in", WalkInAsync).WithName("CheckInWalkIn");
        group.MapPatch("/{id:guid}", SetStatusAsync).WithName("SetQueueStatus");
        return api;
    }

    private static async Task<Results<Ok<List<QueueEntryDto>>, ValidationProblem, ProblemHttpResult>> BoardAsync(
        Guid? branchId, DateOnly? date, string? status, AppointmentsDbContext db, ITenantContext tenant, TimeProvider clock, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.RegRead))
        {
            return HmsProblems.Forbidden();
        }

        var errors = new Dictionary<string, string[]>();
        if (branchId is null || branchId == Guid.Empty)
        {
            errors["branchId"] = ["branchId is required."];
        }

        if (status is not null && !QueueStatus.All.Contains(status))
        {
            errors["status"] = [$"Status must be one of: {string.Join(", ", QueueStatus.All)}."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var branch = branchId!.Value;
        if (!tenant.CanAccessBranch(branch))
        {
            return HmsProblems.Forbidden("You cannot view the queue of this branch.");
        }

        tenant.BranchTimeZones.TryGetValue(branch, out var tz);
        var day = date ?? BranchTime.Today(clock, tz);
        var query = db.QueueEntries.AsNoTracking().Where(q => q.BranchId == branch && q.QueueDate == day);
        if (status is not null)
        {
            query = query.Where(q => q.Status == status);
        }

        var rows = await query.OrderBy(q => q.TokenNo).ToListAsync(ct);
        return TypedResults.Ok(rows.Select(QueueEntryDto.From).ToList());
    }

    private static async Task<Results<Created<CheckInResultDto>, ValidationProblem, ProblemHttpResult>> WalkInAsync(
        WalkInRequest request, AppointmentsDbContext db, ITenantContext tenant, IAppointmentFunctions functions, CancellationToken ct)
    {
        if (!AppointmentRoles.AnyBranch(tenant, AppointmentRoles.FrontDesk))
        {
            return HmsProblems.Forbidden();
        }

        var errors = new Dictionary<string, string[]>();
        if (request.BranchId == Guid.Empty)
        {
            errors["branchId"] = ["Branch is required."];
        }

        if (request.PatientId == Guid.Empty)
        {
            errors["patientId"] = ["Patient is required."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!tenant.HasRoleAtBranch(request.BranchId, AppointmentRoles.FrontDesk))
        {
            return HmsProblems.Forbidden("You cannot check patients in at this branch.");
        }

        IssuedToken token;
        try
        {
            token = await functions.CheckInWalkInAsync(request.BranchId, request.PatientId, request.PractitionerId is { } p && p != Guid.Empty ? p : null, ct);
        }
        catch (Exception ex) when (CheckInProblem(ex) is { } problem)
        {
            return problem;
        }

        var entry = await db.QueueEntries.AsNoTracking().SingleAsync(q => q.Id == token.QueueEntryId, ct);
        return TypedResults.Created(
            $"/api/v1/queue/{token.QueueEntryId}", new CheckInResultDto(token.QueueEntryId, token.TokenNo, token.QueueDate, QueueEntryDto.From(entry)));
    }

    private static async Task<Results<Ok<QueueEntryDto>, ValidationProblem, ProblemHttpResult>> SetStatusAsync(
        Guid id, UpdateQueueStatusRequest request, AppointmentsDbContext db, ITenantContext tenant, IAppointmentFunctions functions, CancellationToken ct)
    {
        if (request.Status is null || !QueueStatus.Settable.Contains(request.Status))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]>
            {
                ["status"] = [$"Status must be one of: {string.Join(", ", QueueStatus.Settable)}."],
            });
        }

        if (!tenant.HasAnyRole(AppointmentRoles.RegRead))
        {
            return HmsProblems.Forbidden();
        }

        var entry = await db.QueueEntries.AsNoTracking().SingleOrDefaultAsync(q => q.Id == id, ct);
        if (entry is null || !tenant.CanAccessBranch(entry.BranchId))
        {
            return HmsProblems.NotFound("Queue entry not found.");
        }

        var allowed = tenant.HasRoleAtBranch(entry.BranchId, AppointmentRoles.FrontDesk)
                      || (request.Status is QueueStatus.InConsultation or QueueStatus.Done
                          && tenant.HasRoleAtBranch(entry.BranchId, AppointmentRoles.Doctor));
        if (!allowed)
        {
            return HmsProblems.Forbidden("You cannot change this queue entry.");
        }

        try
        {
            await functions.SetQueueStatusAsync(id, request.Status, ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        var updated = await db.QueueEntries.AsNoTracking().SingleAsync(q => q.Id == id, ct);
        return TypedResults.Ok(QueueEntryDto.From(updated));
    }

    internal static ProblemHttpResult? CheckInProblem(Exception ex) =>
        HmsProblems.FromDatabase(ex, uniqueCode: HmsProblems.Codes.AlreadyCheckedIn,
            uniqueDetail: "Already checked in: the appointment has a token, or the patient is already waiting / in consultation at this branch today.");
}
