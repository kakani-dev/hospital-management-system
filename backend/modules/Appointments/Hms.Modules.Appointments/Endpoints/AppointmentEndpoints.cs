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
/// Appointments (2.2) and appointment check-in (2.3). Reads are tenant-wide for REG_READ (D10); writes
/// need REG_WRITE at the appointment's branch (D9). Double booking is a DB exclusion constraint
/// (23P01 → 409 appointment_overlap); the API pre-check only gives a faster, friendlier answer.
/// Outbox events are written by DB triggers inside the same transaction (D8).
/// </summary>
public static class AppointmentEndpoints
{
    internal static readonly TimeSpan MaxDuration = TimeSpan.FromHours(8);
    internal const int ReasonMaxLength = 500;

    public static RouteGroupBuilder MapAppointmentEndpoints(this RouteGroupBuilder api)
    {
        var group = api.MapGroup("/appointments").WithTags("Appointments").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        group.MapGet("/", ListAsync).WithName("ListAppointments");
        group.MapGet("/{id:guid}", GetAsync).WithName("GetAppointment");
        group.MapPost("/", BookAsync).WithName("BookAppointment")
            .WithSummary("Book a slot. 409 appointment_overlap when the practitioner is already booked in that time.");
        group.MapPost("/{id:guid}/reschedule", RescheduleAsync).WithName("RescheduleAppointment");
        group.MapPost("/{id:guid}/cancel", CancelAsync).WithName("CancelAppointment");
        group.MapPost("/{id:guid}/no-show", NoShowAsync).WithName("MarkAppointmentNoShow");
        group.MapPost("/{id:guid}/check-in", CheckInAsync).WithName("CheckInAppointment")
            .WithSummary("Reception check-in (appointment.check_in): issues the branch's next OPD token for today.");
        return api;
    }

    private static async Task<Results<Ok<PagedResult<AppointmentDto>>, ValidationProblem, ProblemHttpResult>> ListAsync(
        AppointmentsDbContext db, ITenantContext tenant, Guid? branchId, Guid? practitionerId, Guid? patientId, DateOnly? date,
        DateTimeOffset? from, DateTimeOffset? to, string? status, int? page, int? pageSize, IPatientSummaries patients, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.RegRead))
        {
            return HmsProblems.Forbidden();
        }

        var errors = new Dictionary<string, string[]>();
        if (status is not null && !AppointmentStatus.All.Contains(status))
        {
            errors["status"] = [$"Status must be one of: {string.Join(", ", AppointmentStatus.All)}."];
        }

        if (date is not null && branchId is null)
        {
            errors["date"] = ["'date' is branch-local and needs branchId (or use from/to instants)."];
        }

        if (from is { } f && to is { } t && t <= f)
        {
            errors["to"] = ["'to' must be after 'from'."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var query = db.Appointments.AsNoTracking();
        if (branchId is { } b)
        {
            query = query.Where(a => a.BranchId == b);
        }

        if (practitionerId is { } pr)
        {
            query = query.Where(a => a.PractitionerId == pr);
        }

        if (patientId is { } pa)
        {
            query = query.Where(a => a.PatientId == pa);
        }

        if (status is not null)
        {
            query = query.Where(a => a.Status == status);
        }

        if (date is { } day)
        {
            var tz = tenant.TimeZoneFor(branchId!.Value);
            var (dayStart, dayEnd) = BranchTime.DayRangeUtc(day, tz);
            query = query.Where(a => a.StartsAt >= dayStart && a.StartsAt < dayEnd);
        }

        if (from is { } fromUtc)
        {
            var value = fromUtc.ToUniversalTime();
            query = query.Where(a => a.EndsAt > value);
        }

        if (to is { } toUtc)
        {
            var value = toUtc.ToUniversalTime();
            query = query.Where(a => a.StartsAt < value);
        }

        var p = Math.Max(page ?? 1, 1);
        var size = Math.Clamp(pageSize ?? 25, 1, 100);
        var total = await query.CountAsync(ct);
        var items = await query.WithPatient(db)
            .OrderBy(r => r.Appointment.StartsAt).ThenBy(r => r.Appointment.Id)
            .Skip((p - 1) * size).Take(size).ToListAsync(ct);
        await patients.AttachAsync(items, ct);
        return TypedResults.Ok(new PagedResult<AppointmentDto>([.. items.Select(r => r.ToDto())], p, size, total));
    }

    private static async Task<Results<Ok<AppointmentDto>, ProblemHttpResult>> GetAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, IPatientSummaries patients, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.RegRead))
        {
            return HmsProblems.Forbidden();
        }

        var row = await db.Appointments.AsNoTracking().Where(a => a.Id == id).WithPatient(db).SingleOrDefaultAsync(ct);
        if (row is not null)
        {
            await patients.AttachAsync([row], ct);
        }

        return row is null ? HmsProblems.NotFound("Appointment not found.") : TypedResults.Ok(row.ToDto());
    }

    private static async Task<Results<Created<AppointmentDto>, ValidationProblem, ProblemHttpResult>> BookAsync(
        CreateAppointmentRequest request, AppointmentsDbContext db, ITenantContext tenant, IPatientSummaries patients, CancellationToken ct)
    {
        if (!AppointmentRoles.AnyBranch(tenant, AppointmentRoles.RegWrite))
        {
            return HmsProblems.Forbidden();
        }

        var errors = new Dictionary<string, string[]>();
        if (request.BranchId == Guid.Empty)
        {
            errors["branchId"] = ["Branch is required."];
        }

        if (request.PractitionerId == Guid.Empty)
        {
            errors["practitionerId"] = ["Practitioner is required."];
        }

        if (request.PatientId == Guid.Empty)
        {
            errors["patientId"] = ["Patient is required."];
        }

        ValidateTimes(request.StartsAt, request.EndsAt, errors);
        if (request.Reason is { Length: > ReasonMaxLength })
        {
            errors["reason"] = [$"Reason must be at most {ReasonMaxLength} characters."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!tenant.HasRoleAtBranch(request.BranchId, AppointmentRoles.RegWrite))
        {
            return await BranchScope.DenyAsync(db, tenant, request.BranchId, "You cannot book appointments at this branch.", ct);
        }

        var startsAt = request.StartsAt!.Value.ToUniversalTime();
        var endsAt = request.EndsAt!.Value.ToUniversalTime();
        if (await OverlapsAsync(db, request.PractitionerId, startsAt, endsAt, null, ct))
        {
            return Overlap();
        }

        var appointment = new Appointment
        {
            BranchId = request.BranchId,
            PractitionerId = request.PractitionerId,
            PatientId = request.PatientId,
            StartsAt = startsAt,
            EndsAt = endsAt,
            Reason = string.IsNullOrWhiteSpace(request.Reason) ? null : request.Reason.Trim(),
        };
        db.Appointments.Add(appointment);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (BookingProblem(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/appointments/{appointment.Id}", await PatientEmbedding.LoadAppointmentAsync(db, patients, appointment.Id, ct));
    }

    private static async Task<Results<Ok<AppointmentDto>, ValidationProblem, ProblemHttpResult>> RescheduleAsync(
        Guid id, RescheduleAppointmentRequest request, AppointmentsDbContext db, ITenantContext tenant, IPatientSummaries patients, CancellationToken ct)
    {
        var errors = new Dictionary<string, string[]>();
        ValidateTimes(request.StartsAt, request.EndsAt, errors);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var (appointment, denied) = await LoadForWriteAsync(db, tenant, id, ct);
        if (denied is not null)
        {
            return denied;
        }

        if (appointment!.Status != AppointmentStatus.Booked)
        {
            return InvalidTransition($"invalid_transition:reschedule_not_booked ({appointment.Status})");
        }

        var startsAt = request.StartsAt!.Value.ToUniversalTime();
        var endsAt = request.EndsAt!.Value.ToUniversalTime();
        var practitioner = request.PractitionerId is { } p && p != Guid.Empty ? p : appointment.PractitionerId;
        if (await OverlapsAsync(db, practitioner, startsAt, endsAt, appointment.Id, ct))
        {
            return Overlap();
        }

        appointment.StartsAt = startsAt;
        appointment.EndsAt = endsAt;
        appointment.PractitionerId = practitioner;
        return await SaveAsync(db, appointment, patients, ct);
    }

    private static async Task<Results<Ok<AppointmentDto>, ValidationProblem, ProblemHttpResult>> CancelAsync(
        Guid id, CancelAppointmentRequest? request, AppointmentsDbContext db, ITenantContext tenant, IPatientSummaries patients, CancellationToken ct)
    {
        if (request?.Reason is { Length: > ReasonMaxLength })
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["reason"] = [$"Reason must be at most {ReasonMaxLength} characters."] });
        }

        var (appointment, denied) = await LoadForWriteAsync(db, tenant, id, ct);
        if (denied is not null)
        {
            return denied;
        }

        if (appointment!.Status is not (AppointmentStatus.Booked or AppointmentStatus.CheckedIn))
        {
            return InvalidTransition($"invalid_transition:{appointment.Status}->cancelled");
        }

        appointment.Status = AppointmentStatus.Cancelled;
        appointment.CancelReason = string.IsNullOrWhiteSpace(request?.Reason) ? null : request.Reason.Trim();
        return await SaveAsync(db, appointment, patients, ct);
    }

    private static async Task<Results<Ok<AppointmentDto>, ValidationProblem, ProblemHttpResult>> NoShowAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, TimeProvider clock, IPatientSummaries patients, CancellationToken ct)
    {
        var (appointment, denied) = await LoadForWriteAsync(db, tenant, id, ct);
        if (denied is not null)
        {
            return denied;
        }

        if (appointment!.Status != AppointmentStatus.Booked || clock.GetUtcNow() < appointment.StartsAt)
        {
            return InvalidTransition($"invalid_transition:{appointment.Status}->no_show (only booked appointments, once they have started)");
        }

        appointment.Status = AppointmentStatus.NoShow;
        return await SaveAsync(db, appointment, patients, ct);
    }

    private static async Task<Results<Created<CheckInResultDto>, ProblemHttpResult>> CheckInAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, IAppointmentFunctions functions, IPatientSummaries patients, CancellationToken ct)
    {
        if (!AppointmentRoles.AnyBranch(tenant, AppointmentRoles.FrontDesk))
        {
            return HmsProblems.Forbidden();
        }

        var appointment = await db.Appointments.AsNoTracking().SingleOrDefaultAsync(a => a.Id == id, ct);
        if (appointment is null)
        {
            return HmsProblems.NotFound("Appointment not found.");
        }

        if (!tenant.HasRoleAtBranch(appointment.BranchId, AppointmentRoles.FrontDesk))
        {
            return HmsProblems.Forbidden("You cannot check patients in at this branch.");
        }

        IssuedToken token;
        try
        {
            token = await functions.CheckInAsync(tenant.TenantId, appointment.BranchId, appointment.PatientId, appointment.Id, ct);
        }
        catch (Exception ex) when (QueueEndpoints.CheckInProblem(ex) is { } problem)
        {
            return problem;
        }

        var entry = await PatientEmbedding.LoadQueueEntryAsync(db, patients, token.QueueEntryId, ct);
        return TypedResults.Created(
            $"/api/v1/queue/{token.QueueEntryId}", new CheckInResultDto(token.QueueEntryId, token.TokenNo, token.QueueDate, entry));
    }

    // ------------------------------------------------------------------ helpers
    private static void ValidateTimes(DateTimeOffset? startsAt, DateTimeOffset? endsAt, Dictionary<string, string[]> errors)
    {
        if (startsAt is null)
        {
            errors["startsAt"] = ["Start is required (ISO-8601 instant with offset)."];
        }

        if (endsAt is null)
        {
            errors["endsAt"] = ["End is required (ISO-8601 instant with offset)."];
        }

        if (startsAt is { } s && endsAt is { } e && (e <= s || e - s > MaxDuration))
        {
            errors["endsAt"] = ["End must be after start and at most 8 hours later."];
        }
    }

    private static Task<bool> OverlapsAsync(
        AppointmentsDbContext db, Guid practitionerId, DateTimeOffset startsAt, DateTimeOffset endsAt, Guid? excludeId, CancellationToken ct) =>
        db.Appointments.AsNoTracking().AnyAsync(
            a => a.PractitionerId == practitionerId
                 && a.Id != excludeId
                 && (a.Status == AppointmentStatus.Booked || a.Status == AppointmentStatus.CheckedIn
                     || a.Status == AppointmentStatus.InConsultation || a.Status == AppointmentStatus.Completed)
                 && a.StartsAt < endsAt && startsAt < a.EndsAt,
            ct);

    private static async Task<(Appointment? Appointment, ProblemHttpResult? Denied)> LoadForWriteAsync(
        AppointmentsDbContext db, ITenantContext tenant, Guid id, CancellationToken ct)
    {
        if (!AppointmentRoles.AnyBranch(tenant, AppointmentRoles.RegWrite))
        {
            return (null, HmsProblems.Forbidden());
        }

        var appointment = await db.Appointments.SingleOrDefaultAsync(a => a.Id == id, ct);
        if (appointment is null)
        {
            return (null, HmsProblems.NotFound("Appointment not found."));
        }

        return tenant.HasRoleAtBranch(appointment.BranchId, AppointmentRoles.RegWrite)
            ? (appointment, null)
            : (null, HmsProblems.Forbidden("You cannot change appointments at this branch."));
    }

    private static async Task<Results<Ok<AppointmentDto>, ValidationProblem, ProblemHttpResult>> SaveAsync(
        AppointmentsDbContext db, Appointment appointment, IPatientSummaries patients, CancellationToken ct)
    {
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            return HmsProblems.NotFound("Appointment not found.");
        }
        catch (Exception ex) when (AppointmentProblem(ex) is { } problem)
        {
            return problem;
        }

        // fresh read: trigger-owned timestamps, then the patient summary through patient.patient_summary_v1
        return TypedResults.Ok(await PatientEmbedding.LoadAppointmentAsync(db, patients, appointment.Id, ct));
    }

    // Booking insert: concurrent overlapping inserts can deadlock (40P01) inside the exclusion-constraint
    // check instead of raising 23P01; either way the slot was taken by the concurrent booking.
    // Npgsql's default execution strategy wraps transient errors (40P01 / 40001) in an
    // InvalidOperationException ("likely due to a transient failure"), not a DbUpdateException, so the
    // callers catch Exception and let FindDbError walk the inner-exception chain.
    private static ProblemHttpResult? BookingProblem(Exception ex) =>
        HmsProblems.FromDatabase(ex, exclusionCode: HmsProblems.Codes.AppointmentOverlap,
            exclusionDetail: "The practitioner is already booked for part of that time.",
            concurrencyCode: HmsProblems.Codes.AppointmentOverlap,
            concurrencyDetail: "The practitioner is already booked for part of that time.");

    private static ProblemHttpResult? AppointmentProblem(Exception ex) =>
        HmsProblems.FromDatabase(ex, exclusionCode: HmsProblems.Codes.AppointmentOverlap,
            exclusionDetail: "The practitioner is already booked for part of that time.");

    private static ProblemHttpResult Overlap() =>
        HmsProblems.Conflict(HmsProblems.Codes.AppointmentOverlap, "The practitioner is already booked for part of that time.");

    private static ProblemHttpResult InvalidTransition(string detail) => HmsProblems.Conflict(HmsProblems.Codes.InvalidTransition, detail);
}
