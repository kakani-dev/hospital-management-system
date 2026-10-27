using Hms.Platform.Http;
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
        group.MapPost("/close-day", CloseDayAsync).WithName("CloseQueueDay")
            .WithSummary("Expire waiting tokens for a branch-local day that has ended. Today only for a hospital admin with a reason; a future day is rejected.");
        group.MapPatch("/{id:guid}", SetStatusAsync).WithName("SetQueueStatus");
        return api;
    }

    private static async Task<Results<Ok<List<QueueEntryDto>>, ValidationProblem, ProblemHttpResult>> BoardAsync(
        Guid? branchId, DateOnly? date, string? status, AppointmentsDbContext db, ITenantContext tenant, TimeProvider clock, IPatientSummaries patients, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.QueueView))
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
            return await BranchScope.DenyAsync(db, tenant, branch, "You cannot view the queue of this branch.", ct);
        }

        var tz = tenant.TimeZoneFor(branch);
        var day = date ?? BranchTime.Today(clock, tz);
        var query = db.QueueEntries.AsNoTracking().Where(q => q.BranchId == branch && q.QueueDate == day);
        if (tenant.HasAnyRole(HmsRoles.Doctor)
            && !tenant.HasAnyRole(HmsRoles.TenantAdmin, HmsRoles.Nurse, HmsRoles.Receptionist, HmsRoles.Billing))
        {
            var me = tenant.UserId;
            query = query.Where(q => q.PractitionerId != null && db.Practitioners.Any(p => p.Id == q.PractitionerId && p.UserId == me));
        }

        if (status is not null)
        {
            query = query.Where(q => q.Status == status);
        }

        var rows = await query.WithPatient(db).OrderBy(r => r.Entry.TokenNo).ToListAsync(ct);
        await patients.AttachAsync(rows, ct);
        return TypedResults.Ok(rows.Select(r => r.ToDto()).ToList());
    }

    private static async Task<Results<Created<CheckInResultDto>, ValidationProblem, ProblemHttpResult>> WalkInAsync(
        WalkInRequest request, AppointmentsDbContext db, ITenantContext tenant, IAppointmentFunctions functions, IPatientSummaries patients, CancellationToken ct)
    {
        if (!tenant.CanAtAnyBranch(HmsPermissions.QueueManage))
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

        if (!tenant.CanAtBranch(request.BranchId, HmsPermissions.QueueManage))
        {
            return await BranchScope.DenyAsync(db, tenant, request.BranchId, "You cannot check patients in at this branch.", ct);
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

        var entry = await PatientEmbedding.LoadQueueEntryAsync(db, patients, token.QueueEntryId, ct);
        return TypedResults.Created(
            $"/api/v1/queue/{token.QueueEntryId}", new CheckInResultDto(token.QueueEntryId, token.TokenNo, token.QueueDate, entry));
    }

    private const string DayNotEnded = "A queue day cannot be closed before it ends in the branch time zone.";
    private const int EarlyCloseReasonMinLength = 3;

    private static async Task<Results<Ok<CloseQueueDayResult>, ValidationProblem, ProblemHttpResult>> CloseDayAsync(
        CloseQueueDayRequest request, AppointmentsDbContext db, ITenantContext tenant, IAppointmentFunctions functions, TimeProvider clock, CancellationToken ct)
    {
        if (!tenant.CanAtAnyBranch(HmsPermissions.QueueManage))
        {
            return HmsProblems.Forbidden();
        }

        if (request.BranchId == Guid.Empty)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["branchId"] = ["Branch is required."] });
        }

        if (!tenant.CanAtBranch(request.BranchId, HmsPermissions.QueueManage))
        {
            return await BranchScope.DenyAsync(db, tenant, request.BranchId, "You cannot close the queue of this branch.", ct);
        }

        var tz = tenant.TimeZoneFor(request.BranchId);
        var today = BranchTime.Today(clock, tz);
        var day = request.Date ?? today;
        var reason = string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim();
        if (day > today)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]>
            {
                ["date"] = [DayNotEnded],
            });
        }

        if (reason is { Length: < EarlyCloseReasonMinLength or > AppointmentEndpoints.ReasonMaxLength })
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]>
            {
                ["reason"] = [$"The reason for closing early must be {EarlyCloseReasonMinLength} to {AppointmentEndpoints.ReasonMaxLength} characters."],
            });
        }

        // #142 / QUE-007: today has not ended in the branch zone. Only a hospital admin may close it
        // early (emergency closure, branch shutting early), and only with a reason. Otherwise the
        // pg_cron end-of-day close expires the day's waiting tokens after branch-local midnight.
        if (day == today)
        {
            if (reason is null)
            {
                return TypedResults.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["date"] = [DayNotEnded + " Only a hospital admin can close it early, with a reason."],
                });
            }

            if (!tenant.HasRoleAtBranch(request.BranchId, HmsRoles.TenantAdmin))
            {
                return HmsProblems.Forbidden("Only a hospital admin can close the queue before the day ends.");
            }
        }

        int expired;
        try
        {
            expired = await functions.CloseQueueDayAsync(tenant.TenantId, request.BranchId, day, day == today ? reason : null, ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(new CloseQueueDayResult(request.BranchId, day, expired));
    }

    private static async Task<Results<Ok<QueueEntryDto>, ValidationProblem, ProblemHttpResult>> SetStatusAsync(
        Guid id, UpdateQueueStatusRequest request, AppointmentsDbContext db, ITenantContext tenant, IAppointmentFunctions functions, IPatientSummaries patients, CancellationToken ct)
    {
        if (request.Status is null || !QueueStatus.Settable.Contains(request.Status))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]>
            {
                ["status"] = [$"Status must be one of: {string.Join(", ", QueueStatus.Settable)}."],
            });
        }

        if (!tenant.Can(HmsPermissions.QueueView))
        {
            return HmsProblems.Forbidden();
        }

        var entry = await db.QueueEntries.AsNoTracking().SingleOrDefaultAsync(q => q.Id == id, ct);
        if (entry is null || !tenant.CanAccessBranch(entry.BranchId))
        {
            // Not visible to us: let the DB tell foreign/unknown (P0002 -> 404) from same-tenant out of scope (42501 -> 403).
            // The function is expected to raise here; any write is rolled back by the 4xx below.
            try
            {
                await functions.SetQueueStatusAsync(id, request.Status, ct);
            }
            catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } scopeProblem)
            {
                return scopeProblem;
            }

            return HmsProblems.NotFound("Queue entry not found.");
        }

        // queue.consult_own: a doctor may start/finish only the practitioner linked to their login.
        var allowed = tenant.CanAtBranch(entry.BranchId, HmsPermissions.QueueManage)
                      || (request.Status is QueueStatus.InConsultation or QueueStatus.Done
                          && tenant.CanAtBranch(entry.BranchId, HmsPermissions.QueueConsultOwn)
                          && entry.PractitionerId is { } practitionerId
                          && await db.Practitioners.AsNoTracking().AnyAsync(p => p.Id == practitionerId && p.UserId == tenant.UserId, ct));
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

        return TypedResults.Ok(await PatientEmbedding.LoadQueueEntryAsync(db, patients, id, ct));
    }

    internal static ProblemHttpResult? CheckInProblem(Exception ex) =>
        HmsProblems.FromDatabase(ex, uniqueCode: HmsProblems.Codes.AlreadyCheckedIn,
            uniqueDetail: "Already checked in: the appointment has a token, or the patient is already waiting / in consultation at this branch today.");
}
