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

/// <summary>Branch membership, day overrides, the travel buffer, and a doctor's cross-branch day.</summary>
public static class PractitionerBranchEndpoints
{
    public static RouteGroupBuilder MapPractitionerBranchEndpoints(this RouteGroupBuilder api)
    {
        var branches = api.MapGroup("/practitioner-branches").WithTags("Practitioners").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        branches.MapGet("/", ListBranchesAsync).WithName("ListPractitionerBranches");
        branches.MapPost("/", CreateBranchAsync).WithName("CreatePractitionerBranch");
        branches.MapPatch("/{id:guid}", UpdateBranchAsync).WithName("UpdatePractitionerBranch");

        var overrides = api.MapGroup("/schedule-overrides").WithTags("Schedules").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        overrides.MapGet("/", ListOverridesAsync).WithName("ListScheduleOverrides");
        overrides.MapPost("/", CreateOverrideAsync).WithName("CreateScheduleOverride");
        overrides.MapPatch("/{id:guid}", UpdateOverrideAsync).WithName("UpdateScheduleOverride");

        var settings = api.MapGroup("/scheduling-settings").WithTags("Schedules").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        settings.MapGet("/", GetSettingsAsync).WithName("GetSchedulingSettings");
        settings.MapPut("/", PutSettingsAsync).WithName("PutSchedulingSettings");

        api.MapGet("/practitioners/me/day", MyDayAsync).WithTags("Practitioners").RequireTenant().WithDbTransaction<AppointmentsDbContext>()
            .WithName("MyDay");
        return api;
    }

    private static async Task<Ok<List<PractitionerBranchDto>>> ListBranchesAsync(
        AppointmentsDbContext db, Guid? practitionerId, Guid? branchId, CancellationToken ct)
    {
        var query = db.PractitionerBranches.AsNoTracking();
        if (practitionerId is { } p)
        {
            query = query.Where(m => m.PractitionerId == p);
        }

        if (branchId is { } b)
        {
            query = query.Where(m => m.BranchId == b);
        }

        var rows = await query.OrderBy(m => m.BranchId).ThenBy(m => m.Id).ToListAsync(ct);
        return TypedResults.Ok(rows.Select(PractitionerBranchDto.From).ToList());
    }

    private static async Task<Results<Created<PractitionerBranchDto>, ValidationProblem, ProblemHttpResult>> CreateBranchAsync(
        CreatePractitionerBranchRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage practitioners.");
        }

        var errors = MembershipErrors(request.ConsultationRoom, request.ConsultationFeeCents);
        if (request.PractitionerId == Guid.Empty)
        {
            errors["practitionerId"] = ["Practitioner is required."];
        }

        if (request.BranchId == Guid.Empty)
        {
            errors["branchId"] = ["Branch is required."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!tenant.CanAtBranch(request.BranchId, HmsPermissions.PractitionersManage))
        {
            return await BranchScope.DenyAsync(db, tenant, request.BranchId, "You cannot manage practitioners at this branch.", ct);
        }

        if (!await db.Practitioners.AnyAsync(p => p.Id == request.PractitionerId, ct))
        {
            return HmsProblems.NotFound("Practitioner not found.");
        }

        if (await db.PractitionerBranches.AnyAsync(m => m.PractitionerId == request.PractitionerId && m.BranchId == request.BranchId, ct))
        {
            return HmsProblems.Conflict(HmsProblems.Codes.Conflict, "This doctor is already at that branch.");
        }

        var row = new PractitionerBranch
        {
            PractitionerId = request.PractitionerId,
            BranchId = request.BranchId,
            IsActive = true,
            ConsultationRoom = CleanRoom(request.ConsultationRoom),
            ConsultationFeeCents = request.ConsultationFeeCents,
        };
        db.PractitionerBranches.Add(row);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "This doctor is already at that branch.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/practitioner-branches/{row.Id}", PractitionerBranchDto.From(row));
    }

    private static async Task<Results<Ok<PractitionerBranchDto>, ValidationProblem, ProblemHttpResult>> UpdateBranchAsync(
        Guid id, UpdatePractitionerBranchRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage practitioners.");
        }

        var row = await db.PractitionerBranches.SingleOrDefaultAsync(m => m.Id == id, ct);
        if (row is null)
        {
            return HmsProblems.NotFound("Branch membership not found.");
        }

        if (!tenant.CanAtBranch(row.BranchId, HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("You cannot manage practitioners at this branch.");
        }

        var errors = MembershipErrors(request.ConsultationRoom, request.ConsultationFeeCents);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (request.IsActive is { } active)
        {
            row.IsActive = active;
        }

        if (request.ConsultationRoom is not null)
        {
            row.ConsultationRoom = CleanRoom(request.ConsultationRoom);
        }

        if (request.ClearFee == true)
        {
            row.ConsultationFeeCents = null;
        }
        else if (request.ConsultationFeeCents is { } fee)
        {
            row.ConsultationFeeCents = fee;
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(PractitionerBranchDto.From(row));
    }

    private static async Task<Ok<List<ScheduleOverrideDto>>> ListOverridesAsync(
        AppointmentsDbContext db, Guid? practitionerId, Guid? branchId, DateOnly? from, DateOnly? to, CancellationToken ct)
    {
        var query = db.ScheduleOverrides.AsNoTracking().Where(o => o.IsActive);
        if (practitionerId is { } p)
        {
            query = query.Where(o => o.PractitionerId == p);
        }

        if (branchId is { } b)
        {
            query = query.Where(o => o.BranchId == b);
        }

        if (from is { } f)
        {
            query = query.Where(o => o.OverrideDate >= f);
        }

        if (to is { } end)
        {
            query = query.Where(o => o.OverrideDate <= end);
        }

        var rows = await query.OrderBy(o => o.OverrideDate).ThenBy(o => o.BranchId).ToListAsync(ct);
        return TypedResults.Ok(rows.Select(ScheduleOverrideDto.From).ToList());
    }

    private static async Task<Results<Created<ScheduleOverrideDto>, ValidationProblem, ProblemHttpResult>> CreateOverrideAsync(
        CreateScheduleOverrideRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
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

        if (request.Date is null)
        {
            errors["date"] = ["Date is required."];
        }

        var leave = request.IsLeave ?? false;
        TimeOnly start = default, end = default;
        if (!leave)
        {
            if (!HhMm.TryParse(request.StartTime, out start))
            {
                errors["startTime"] = ["Start time is required as HH:mm (branch-local)."];
            }

            if (!HhMm.TryParse(request.EndTime, out end))
            {
                errors["endTime"] = ["End time is required as HH:mm (branch-local)."];
            }
            else if (!errors.ContainsKey("startTime") && start >= end)
            {
                errors["endTime"] = ["End time must be after start time."];
            }

            if (request.SlotMinutes is < 5 or > 240)
            {
                errors["slotMinutes"] = ["Slot length must be 5-240 minutes."];
            }
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!tenant.CanAtBranch(request.BranchId, HmsPermissions.PractitionersManage))
        {
            return await BranchScope.DenyAsync(db, tenant, request.BranchId, "You cannot manage schedules at this branch.", ct);
        }

        if (!await db.Practitioners.AnyAsync(p => p.Id == request.PractitionerId, ct))
        {
            return HmsProblems.NotFound("Practitioner not found.");
        }

        if (await PractitionerScheduleEndpoints.EnsureActiveMembershipAsync(db, request.PractitionerId, request.BranchId, ct) is { } membershipProblem)
        {
            return membershipProblem;
        }

        var existing = await db.ScheduleOverrides.SingleOrDefaultAsync(
            o => o.PractitionerId == request.PractitionerId && o.BranchId == request.BranchId && o.OverrideDate == request.Date, ct);
        if (existing is not null)
        {
            ApplyOverride(existing, leave, start, end, request.SlotMinutes ?? existing.SlotMinutes ?? 15, true);
            try
            {
                await db.SaveChangesAsync(ct);
            }
            catch (Exception ex) when (OverrideProblem(ex) is { } problem)
            {
                return problem;
            }

            return TypedResults.Created($"/api/v1/schedule-overrides/{existing.Id}", ScheduleOverrideDto.From(existing));
        }

        var row = new ScheduleOverride
        {
            PractitionerId = request.PractitionerId,
            BranchId = request.BranchId,
            OverrideDate = request.Date!.Value,
            IsActive = true,
        };
        ApplyOverride(row, leave, start, end, request.SlotMinutes ?? 15, true);
        db.ScheduleOverrides.Add(row);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (OverrideProblem(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/schedule-overrides/{row.Id}", ScheduleOverrideDto.From(row));
    }

    private static async Task<Results<Ok<ScheduleOverrideDto>, ValidationProblem, ProblemHttpResult>> UpdateOverrideAsync(
        Guid id, UpdateScheduleOverrideRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage schedules.");
        }

        var row = await db.ScheduleOverrides.SingleOrDefaultAsync(o => o.Id == id, ct);
        if (row is null)
        {
            return HmsProblems.NotFound("Day override not found.");
        }

        if (!tenant.CanAtBranch(row.BranchId, HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("You cannot manage schedules at this branch.");
        }

        var leave = request.IsLeave ?? row.IsLeave;
        var start = row.StartTime ?? default;
        var end = row.EndTime ?? default;
        var errors = new Dictionary<string, string[]>();
        if (request.StartTime is not null && !HhMm.TryParse(request.StartTime, out start))
        {
            errors["startTime"] = ["Start time is required as HH:mm (branch-local)."];
        }

        if (request.EndTime is not null && !HhMm.TryParse(request.EndTime, out end))
        {
            errors["endTime"] = ["End time is required as HH:mm (branch-local)."];
        }

        if (!leave && !errors.ContainsKey("startTime") && !errors.ContainsKey("endTime") && start >= end)
        {
            errors["endTime"] = ["End time must be after start time."];
        }

        var slot = request.SlotMinutes ?? row.SlotMinutes ?? 15;
        if (!leave && slot is < 5 or > 240)
        {
            errors["slotMinutes"] = ["Slot length must be 5-240 minutes."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        ApplyOverride(row, leave, start, end, slot, request.IsActive ?? row.IsActive);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (OverrideProblem(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(ScheduleOverrideDto.From(row));
    }

    private static async Task<Ok<SchedulingSettingsDto>> GetSettingsAsync(AppointmentsDbContext db, CancellationToken ct)
    {
        var minutes = await db.TenantSchedulingSettings.AsNoTracking().Select(s => (int?)s.TravelBufferMinutes).SingleOrDefaultAsync(ct);
        return TypedResults.Ok(new SchedulingSettingsDto(minutes ?? 0));
    }

    private static async Task<Results<Ok<SchedulingSettingsDto>, ValidationProblem, ProblemHttpResult>> PutSettingsAsync(
        UpdateSchedulingSettingsRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can manage schedules.");
        }

        if (request.TravelBufferMinutes is null or < 0 or > 180)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]>
            {
                ["travelBufferMinutes"] = ["Travel buffer must be 0-180 minutes."],
            });
        }

        var row = await db.TenantSchedulingSettings.SingleOrDefaultAsync(ct);
        if (row is null)
        {
            row = new TenantSchedulingSettings { TravelBufferMinutes = (short)request.TravelBufferMinutes.Value };
            db.TenantSchedulingSettings.Add(row);
        }
        else
        {
            row.TravelBufferMinutes = (short)request.TravelBufferMinutes.Value;
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(new SchedulingSettingsDto(row.TravelBufferMinutes));
    }

    private static async Task<Results<Ok<MyDayDto>, ProblemHttpResult>> MyDayAsync(
        DateOnly? date, AppointmentsDbContext db, ITenantContext tenant, TimeProvider clock, IPatientSummaries patients, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.AppointmentsView))
        {
            return HmsProblems.Forbidden();
        }

        var day = date ?? BranchTime.Today(clock, tenant.TenantTimeZone);
        var practitioner = await db.Practitioners.AsNoTracking()
            .Where(p => p.UserId == tenant.UserId && p.IsActive)
            .OrderBy(p => p.DisplayName)
            .FirstOrDefaultAsync(ct);
        if (practitioner is null)
        {
            return TypedResults.Ok(new MyDayDto(null, null, day, []));
        }

        var weekday = (short)(((int)day.DayOfWeek + 6) % 7 + 1); // DateOnly Sunday=0 → ISO Monday=1
        var memberships = await db.PractitionerBranches.AsNoTracking()
            .Where(m => m.PractitionerId == practitioner.Id && m.IsActive)
            .ToListAsync(ct);
        var branchIds = memberships.Select(m => m.BranchId).ToHashSet();
        var schedules = await db.Schedules.AsNoTracking()
            .Where(s => s.PractitionerId == practitioner.Id && s.IsActive && s.Weekday == weekday
                && s.ValidFrom <= day && (s.ValidTo == null || s.ValidTo >= day)
                && branchIds.Contains(s.BranchId))
            .ToListAsync(ct);
        var overrides = await db.ScheduleOverrides.AsNoTracking()
            .Where(o => o.PractitionerId == practitioner.Id && o.IsActive && o.OverrideDate == day && branchIds.Contains(o.BranchId))
            .ToListAsync(ct);
        var overridden = overrides.Select(o => o.BranchId).ToHashSet();

        var from = new DateTimeOffset(day.AddDays(-1).ToDateTime(TimeOnly.MinValue), TimeSpan.Zero);
        var to = new DateTimeOffset(day.AddDays(2).ToDateTime(TimeOnly.MinValue), TimeSpan.Zero);
        var appointments = await db.Appointments.AsNoTracking()
            .Where(a => a.PractitionerId == practitioner.Id && a.Status != AppointmentStatus.Cancelled && a.StartsAt >= from && a.StartsAt < to)
            .ToListAsync(ct);
        var rows = appointments.Select(a => new AppointmentRow { Appointment = a }).ToList();
        await patients.AttachAsync(rows, ct);

        var items = new List<MyDayItemDto>();
        foreach (var o in overrides)
        {
            var zone = tenant.TimeZoneFor(o.BranchId);
            if (o.IsLeave)
            {
                var start = BranchTime.DayRangeUtc(day, zone).StartUtc;
                items.Add(new MyDayItemDto("leave", o.BranchId, start, start, null, "leave", null));
                continue;
            }

            if (o.StartTime is { } s && o.EndTime is { } e)
            {
                items.Add(new MyDayItemDto("hours", o.BranchId, AtLocal(day, s, zone), AtLocal(day, e, zone), null, null, null));
            }
        }

        foreach (var s in schedules.Where(s => !overridden.Contains(s.BranchId)))
        {
            var zone = tenant.TimeZoneFor(s.BranchId);
            items.Add(new MyDayItemDto("hours", s.BranchId, AtLocal(day, s.StartTime, zone), AtLocal(day, s.EndTime, zone), null, null, null));
        }

        foreach (var row in rows)
        {
            var zone = tenant.TimeZoneFor(row.Appointment.BranchId);
            if (BranchTime.LocalDate(row.Appointment.StartsAt, zone) != day)
            {
                continue;
            }

            items.Add(new MyDayItemDto(
                "appointment", row.Appointment.BranchId, row.Appointment.StartsAt, row.Appointment.EndsAt,
                row.Appointment.Id, row.Appointment.Status, PatientRefDto.From(row.Patient)));
        }

        items.Sort(static (a, b) =>
        {
            var byTime = a.StartsAt.CompareTo(b.StartsAt);
            return byTime != 0 ? byTime : string.Compare(a.Kind, b.Kind, StringComparison.Ordinal);
        });
        return TypedResults.Ok(new MyDayDto(practitioner.Id, practitioner.DisplayName, day, items));
    }

    private static DateTimeOffset AtLocal(DateOnly day, TimeOnly time, string zone)
    {
        var tz = BranchTime.Zone(zone);
        var local = day.ToDateTime(time);
        while (tz.IsInvalidTime(local))
        {
            local = local.AddMinutes(30);
        }

        return new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(local, DateTimeKind.Unspecified), tz), TimeSpan.Zero);
    }

    private static void ApplyOverride(ScheduleOverride row, bool leave, TimeOnly start, TimeOnly end, int slotMinutes, bool active)
    {
        row.IsLeave = leave;
        row.IsActive = active;
        if (leave)
        {
            row.StartTime = null;
            row.EndTime = null;
            row.SlotMinutes = null;
            return;
        }

        row.StartTime = start;
        row.EndTime = end;
        row.SlotMinutes = (short)slotMinutes;
    }

    private static Dictionary<string, string[]> MembershipErrors(string? room, int? fee)
    {
        var errors = new Dictionary<string, string[]>();
        if (room is { Length: > 80 })
        {
            errors["consultationRoom"] = ["Room must be at most 80 characters."];
        }

        if (fee is < 0)
        {
            errors["consultationFeeCents"] = ["Fee cannot be negative."];
        }

        return errors;
    }

    private static string? CleanRoom(string? room) => string.IsNullOrWhiteSpace(room) ? null : room.Trim();

    private static ProblemHttpResult? OverrideProblem(Exception ex) =>
        HmsProblems.FromDatabase(ex, exclusionCode: HmsProblems.Codes.ScheduleOverlap,
            exclusionDetail: "The practitioner is already scheduled at that time, including at another branch.",
            uniqueDetail: "That branch already has a note for that day.");
}
