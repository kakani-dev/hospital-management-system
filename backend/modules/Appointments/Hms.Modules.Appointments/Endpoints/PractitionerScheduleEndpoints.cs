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

/// <summary>Practitioners (tenant-level, admin-managed), weekly schedules (admin at the branch) and free slots.</summary>
public static class PractitionerScheduleEndpoints
{
    internal const int MaxSlotRangeDays = 31;

    public static RouteGroupBuilder MapPractitionerScheduleEndpoints(this RouteGroupBuilder api)
    {
        var practitioners = api.MapGroup("/practitioners").WithTags("Practitioners").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        practitioners.MapGet("/", ListPractitionersAsync).WithName("ListPractitioners");
        practitioners.MapPost("/", CreatePractitionerAsync).WithName("CreatePractitioner");
        practitioners.MapPatch("/{id:guid}", UpdatePractitionerAsync).WithName("UpdatePractitioner");
        practitioners.MapDelete("/{id:guid}", DeletePractitionerAsync).WithName("DeletePractitioner")
            .WithSummary("Soft delete (appointment.soft_delete_practitioner). 409 while the practitioner has open appointments.");
        practitioners.MapPost("/{id:guid}/restore", RestorePractitionerAsync).WithName("RestorePractitioner");

        var schedules = api.MapGroup("/schedules").WithTags("Schedules").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        schedules.MapGet("/", ListSchedulesAsync).WithName("ListSchedules");
        schedules.MapPost("/", CreateScheduleAsync).WithName("CreateSchedule");
        schedules.MapPatch("/{id:guid}", UpdateScheduleAsync).WithName("UpdateSchedule");
        schedules.MapDelete("/{id:guid}", DeleteScheduleAsync).WithName("DeleteSchedule")
            .WithSummary("Soft delete (appointment.soft_delete_schedule).");
        schedules.MapPost("/{id:guid}/restore", RestoreScheduleAsync).WithName("RestoreSchedule");

        api.MapGroup("/slots").WithTags("Schedules").RequireTenant().WithDbTransaction<AppointmentsDbContext>()
            .MapGet("/", SlotsAsync).WithName("ListFreeSlots")
            .WithSummary("Free future slots from the weekly schedules minus blocking appointments (appointment.available_slots).");

        return api;
    }

    // ------------------------------------------------------------- practitioners
    private static async Task<Results<Ok<List<PractitionerDto>>, ProblemHttpResult>> ListPractitionersAsync(
        AppointmentsDbContext db, ITenantContext tenant, TimeProvider clock, bool? activeOnly, Guid? branchId, CancellationToken ct)
    {
        var query = db.Practitioners.AsNoTracking();
        if (activeOnly ?? true)
        {
            query = query.Where(p => p.IsActive);
        }

        if (branchId is { } branch && branch != Guid.Empty)
        {
            // v4: another tenant's (or unknown) branch is 404; any branch of the own tenant is readable (schedules are tenant-wide).
            if (!await BranchScope.ExistsInTenantAsync(db, tenant, branch, ct))
            {
                return HmsProblems.NotFound("Branch not found.");
            }

            // "Active schedule at the branch": is_active and not ended before the branch-local today (future starts count).
            var tz = tenant.TimeZoneFor(branch);
            var today = BranchTime.Today(clock, tz);
            query = query.Where(p => db.Schedules.Any(s =>
                s.PractitionerId == p.Id && s.BranchId == branch && s.IsActive && (s.ValidTo == null || s.ValidTo >= today)));
        }

        var rows = await query.OrderBy(p => p.DisplayName).ThenBy(p => p.Id).ToListAsync(ct);
        return TypedResults.Ok(rows.Select(PractitionerDto.From).ToList());
    }

    private static async Task<Results<Created<PractitionerDto>, ValidationProblem, ProblemHttpResult>> CreatePractitionerAsync(
        CreatePractitionerRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.Admin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage practitioners.");
        }

        var errors = ValidatePractitioner(request.DisplayName, request.Specialty, required: true);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var practitioner = new Practitioner
        {
            DisplayName = request.DisplayName!.Trim(),
            Specialty = string.IsNullOrWhiteSpace(request.Specialty) ? null : request.Specialty.Trim(),
            UserId = request.UserId is { } u && u != Guid.Empty ? u : null,
        };
        db.Practitioners.Add(practitioner);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "That staff account is already linked to a practitioner.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/practitioners/{practitioner.Id}", PractitionerDto.From(practitioner));
    }

    private static async Task<Results<Ok<PractitionerDto>, ValidationProblem, ProblemHttpResult>> UpdatePractitionerAsync(
        Guid id, UpdatePractitionerRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.Admin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage practitioners.");
        }

        var errors = ValidatePractitioner(request.DisplayName, request.Specialty, required: false);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var practitioner = await db.Practitioners.SingleOrDefaultAsync(p => p.Id == id, ct);
        if (practitioner is null)
        {
            return HmsProblems.NotFound("Practitioner not found.");
        }

        if (request.DisplayName is not null)
        {
            practitioner.DisplayName = request.DisplayName.Trim();
        }

        if (request.Specialty is not null)
        {
            practitioner.Specialty = string.IsNullOrWhiteSpace(request.Specialty) ? null : request.Specialty.Trim();
        }

        if (request.UnlinkUser == true)
        {
            practitioner.UserId = null;
        }
        else if (request.UserId is { } u && u != Guid.Empty)
        {
            practitioner.UserId = u;
        }

        if (request.IsActive is { } active)
        {
            practitioner.IsActive = active;
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "That staff account is already linked to a practitioner.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(PractitionerDto.From(practitioner));
    }

    private static Dictionary<string, string[]> ValidatePractitioner(string? displayName, string? specialty, bool required)
    {
        var errors = new Dictionary<string, string[]>();
        if ((required || displayName is not null) && (string.IsNullOrWhiteSpace(displayName) || displayName.Trim().Length > 120))
        {
            errors["displayName"] = ["Display name is required (1-120 characters)."];
        }

        if (specialty is { Length: > 120 })
        {
            errors["specialty"] = ["Specialty must be at most 120 characters."];
        }

        return errors;
    }

    // ----------------------------------------------------------------- schedules
    private static async Task<Ok<List<ScheduleDto>>> ListSchedulesAsync(
        AppointmentsDbContext db, Guid? branchId, Guid? practitionerId, CancellationToken ct)
    {
        var query = db.Schedules.AsNoTracking();
        if (branchId is { } b)
        {
            query = query.Where(s => s.BranchId == b);
        }

        if (practitionerId is { } p)
        {
            query = query.Where(s => s.PractitionerId == p);
        }

        var rows = await query.OrderBy(s => s.PractitionerId).ThenBy(s => s.Weekday).ThenBy(s => s.StartTime).ToListAsync(ct);
        return TypedResults.Ok(rows.Select(ScheduleDto.From).ToList());
    }

    private static async Task<Results<Created<ScheduleDto>, ValidationProblem, ProblemHttpResult>> CreateScheduleAsync(
        CreateScheduleRequest request, AppointmentsDbContext db, ITenantContext tenant, TimeProvider clock, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.Admin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage schedules.");
        }

        var errors = new Dictionary<string, string[]>();
        if (request.PractitionerId == Guid.Empty)
        {
            errors["practitionerId"] = ["Practitioner is required."];
        }

        if (request.BranchId == Guid.Empty)
        {
            errors["branchId"] = ["Branch is required."];
        }

        var tz = tenant.TimeZoneFor(request.BranchId);
        var schedule = new Schedule
        {
            PractitionerId = request.PractitionerId,
            BranchId = request.BranchId,
            Weekday = (short)(request.Weekday ?? 0),
            SlotMinutes = (short)Math.Clamp(request.SlotMinutes ?? 15, short.MinValue, short.MaxValue),
            ValidFrom = request.ValidFrom ?? BranchTime.Today(clock, tz),
            ValidTo = request.ValidTo,
        };
        ApplyTimes(schedule, request.StartTime, request.EndTime, required: true, errors);
        ValidateSchedule(schedule, request.Weekday, request.SlotMinutes ?? 15, errors);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!tenant.HasRoleAtBranch(request.BranchId, AppointmentRoles.Admin))
        {
            return await BranchScope.DenyAsync(db, tenant, request.BranchId, "You cannot manage schedules at this branch.", ct);
        }

        db.Schedules.Add(schedule);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (ScheduleProblem(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/schedules/{schedule.Id}", ScheduleDto.From(schedule));
    }

    private static async Task<Results<Ok<ScheduleDto>, ValidationProblem, ProblemHttpResult>> UpdateScheduleAsync(
        Guid id, UpdateScheduleRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.Admin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage schedules.");
        }

        var schedule = await db.Schedules.SingleOrDefaultAsync(s => s.Id == id, ct);
        if (schedule is null)
        {
            return HmsProblems.NotFound("Schedule not found.");
        }

        if (!tenant.HasRoleAtBranch(schedule.BranchId, AppointmentRoles.Admin))
        {
            return HmsProblems.Forbidden("You cannot manage schedules at this branch.");
        }

        var errors = new Dictionary<string, string[]>();
        if (request.Weekday is { } w)
        {
            schedule.Weekday = (short)Math.Clamp(w, 0, 8);
        }

        if (request.SlotMinutes is { } m)
        {
            schedule.SlotMinutes = (short)Math.Clamp(m, 0, 1000);
        }

        if (request.ValidFrom is { } from)
        {
            schedule.ValidFrom = from;
        }

        if (request.ClearValidTo == true)
        {
            schedule.ValidTo = null;
        }
        else if (request.ValidTo is { } to)
        {
            schedule.ValidTo = to;
        }

        if (request.IsActive is { } active)
        {
            schedule.IsActive = active;
        }

        ApplyTimes(schedule, request.StartTime, request.EndTime, required: false, errors);
        ValidateSchedule(schedule, schedule.Weekday, schedule.SlotMinutes, errors);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (ScheduleProblem(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(ScheduleDto.From(schedule));
    }

    private static async Task<Results<NoContent, ProblemHttpResult>> DeleteScheduleAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.Admin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage schedules.");
        }

        return await ScheduleSoftDeleteAsync(id, deleted: false, "select appointment.soft_delete_schedule(@id)", db, tenant, ct);
    }

    private static async Task<Results<NoContent, ProblemHttpResult>> RestoreScheduleAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.Admin))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage schedules.");
        }

        return await ScheduleSoftDeleteAsync(id, deleted: true, "select appointment.restore_schedule(@id)", db, tenant, ct);
    }

    // Branch-scoped admin check in the API too (the SQL function checks can_access_branch):
    // a branch-limited admin gets 403 for a schedule at another branch of the same tenant.
    private static async Task<Results<NoContent, ProblemHttpResult>> ScheduleSoftDeleteAsync(
        Guid id, bool deleted, string sql, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        var branchId = await db.Schedules.IgnoreQueryFilters().AsNoTracking()
            .Where(s => s.Id == id && s.TenantId == tenant.TenantId && s.IsDeleted == deleted)
            .Select(s => (Guid?)s.BranchId)
            .SingleOrDefaultAsync(ct);
        if (branchId is null)
        {
            return HmsProblems.NotFound("Schedule not found.");
        }

        if (!tenant.HasRoleAtBranch(branchId.Value, AppointmentRoles.Admin))
        {
            return HmsProblems.Forbidden("You cannot manage schedules at this branch.");
        }

        return await CallSoftDeleteAsync(db, sql, id, ct);
    }

    private static async Task<Results<NoContent, ProblemHttpResult>> DeletePractitionerAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
        tenant.HasAnyRole(AppointmentRoles.Admin)
            ? await CallSoftDeleteAsync(db, "select appointment.soft_delete_practitioner(@id)", id, ct)
            : HmsProblems.Forbidden("Only tenant admins can manage practitioners.");

    private static async Task<Results<NoContent, ProblemHttpResult>> RestorePractitionerAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
        tenant.HasAnyRole(AppointmentRoles.Admin)
            ? await CallSoftDeleteAsync(db, "select appointment.restore_practitioner(@id)", id, ct)
            : HmsProblems.Forbidden("Only tenant admins can manage practitioners.");

    // The SQL functions own is_deleted (clients cannot write it): P0002 -> 404 (unknown, other tenant,
    // wrong state), 42501 -> 403, 55000 -> 409 (open appointments), 23P01/23505 -> 409 on restore.
    private static async Task<Results<NoContent, ProblemHttpResult>> CallSoftDeleteAsync(AppointmentsDbContext db, string sql, Guid id, CancellationToken ct)
    {
        try
        {
            await Hms.SharedKernel.Persistence.RawSql.ScalarAsync(db, sql, ct, ("id", id));
            return TypedResults.NoContent();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(
            ex,
            exclusionCode: HmsProblems.Codes.ScheduleOverlap,
            exclusionDetail: "Restoring this schedule would overlap another active schedule.",
            uniqueDetail: "A live record with the same key already exists.") is { } problem)
        {
            return problem;
        }
    }

    private static void ApplyTimes(Schedule schedule, string? start, string? end, bool required, Dictionary<string, string[]> errors)
    {
        if (start is not null || required)
        {
            if (HhMm.TryParse(start, out var s))
            {
                schedule.StartTime = s;
            }
            else
            {
                errors["startTime"] = ["Start time is required as HH:mm (branch-local)."];
            }
        }

        if (end is not null || required)
        {
            if (HhMm.TryParse(end, out var e))
            {
                schedule.EndTime = e;
            }
            else
            {
                errors["endTime"] = ["End time is required as HH:mm (branch-local)."];
            }
        }
    }

    private static void ValidateSchedule(Schedule schedule, int? weekday, int slotMinutes, Dictionary<string, string[]> errors)
    {
        if (weekday is null or < 1 or > 7)
        {
            errors["weekday"] = ["Weekday must be 1 (Monday) to 7 (Sunday)."];
        }

        if (slotMinutes is < 5 or > 240)
        {
            errors["slotMinutes"] = ["Slot length must be 5-240 minutes."];
        }

        if (!errors.ContainsKey("startTime") && !errors.ContainsKey("endTime") && schedule.StartTime >= schedule.EndTime)
        {
            errors["endTime"] = ["End time must be after start time (no overnight shifts)."];
        }

        if (schedule.ValidTo is { } to && to < schedule.ValidFrom)
        {
            errors["validTo"] = ["validTo must be on or after validFrom."];
        }
    }

    private static ProblemHttpResult? ScheduleProblem(Exception ex) =>
        HmsProblems.FromDatabase(ex, exclusionCode: HmsProblems.Codes.ScheduleOverlap,
            exclusionDetail: "The practitioner already has an overlapping active schedule on that weekday.");

    // --------------------------------------------------------------------- slots
    private static async Task<Results<Ok<List<SlotDto>>, ValidationProblem, ProblemHttpResult>> SlotsAsync(
        Guid? branchId, DateOnly? from, DateOnly? to, Guid? practitionerId, AppointmentsDbContext db, ITenantContext tenant, TimeProvider clock,
        IAppointmentFunctions functions, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(AppointmentRoles.RegRead))
        {
            return HmsProblems.Forbidden();
        }

        if (branchId is not { } branch || branch == Guid.Empty)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["branchId"] = ["branchId is required."] });
        }

        if (!tenant.CanAccessBranch(branch))
        {
            return await BranchScope.DenyAsync(db, tenant, branch, "You cannot view slots at this branch.", ct);
        }

        var tz = tenant.TimeZoneFor(branch);
        var start = from ?? BranchTime.Today(clock, tz);
        var end = to ?? start;
        if (end < start || end.DayNumber - start.DayNumber > MaxSlotRangeDays)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["to"] = [$"'to' must be within {MaxSlotRangeDays} days after 'from'."] });
        }

        try
        {
            var slots = await functions.AvailableSlotsAsync(tenant.TenantId, branch, start, end, practitionerId, ct);
            return TypedResults.Ok(slots.Select(s => new SlotDto(s.PractitionerId, s.BranchId, s.SlotStart.ToUniversalTime(), s.SlotEnd.ToUniversalTime())).ToList());
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }
}
