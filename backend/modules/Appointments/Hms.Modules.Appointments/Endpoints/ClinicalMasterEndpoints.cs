using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Hms.SharedKernel.Time;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Appointments.Endpoints;

/// <summary>Department master, visit-type master and the booking suggestion. Tenant id comes from the session.</summary>
public static class ClinicalMasterEndpoints
{
    public static RouteGroupBuilder MapClinicalMasterEndpoints(this RouteGroupBuilder api)
    {
        var departments = api.MapGroup("/departments").WithTags("Practitioners").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        departments.MapGet("/", ListDepartmentsAsync).WithName("ListDepartments");
        departments.MapPost("/", CreateDepartmentAsync).WithName("CreateDepartment");
        departments.MapPatch("/{id:guid}", UpdateDepartmentAsync).WithName("UpdateDepartment");

        var types = api.MapGroup("/visit-types").WithTags("Visit types").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        types.MapGet("/", ListVisitTypesAsync).WithName("ListVisitTypes");
        types.MapGet("/suggestion", SuggestVisitTypeAsync).WithName("SuggestVisitType");
        types.MapPost("/", CreateVisitTypeAsync).WithName("CreateVisitType");
        types.MapPatch("/{id:guid}", UpdateVisitTypeAsync).WithName("UpdateVisitType");
        types.MapDelete("/{id:guid}", DeleteVisitTypeAsync).WithName("DeleteVisitType");
        types.MapGet("/{id:guid}/overrides", ListOverridesAsync).WithName("ListVisitTypeOverrides");
        types.MapPost("/{id:guid}/overrides", UpsertOverrideAsync).WithName("UpsertVisitTypeOverride");
        return api;
    }

    private static async Task<Ok<List<DepartmentDto>>> ListDepartmentsAsync(AppointmentsDbContext db, CancellationToken ct)
    {
        var rows = await db.Departments.AsNoTracking().OrderBy(d => d.Name).ThenBy(d => d.Id).ToListAsync(ct);
        return TypedResults.Ok(rows.Select(DepartmentDto.From).ToList());
    }

    private static async Task<Results<Created<DepartmentDto>, ValidationProblem, ProblemHttpResult>> CreateDepartmentAsync(
        CreateDepartmentRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can edit departments.");
        }

        var name = request.Name?.Trim();
        if (string.IsNullOrWhiteSpace(name) || name.Length > 80)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["name"] = ["Name is required (1-80 characters)."] });
        }

        var row = new Department { Name = name };
        db.Departments.Add(row);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "A department with that name already exists.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/departments/{row.Id}", DepartmentDto.From(row));
    }

    private static async Task<Results<Ok<DepartmentDto>, ValidationProblem, ProblemHttpResult>> UpdateDepartmentAsync(
        Guid id, UpdateDepartmentRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can edit departments.");
        }

        var row = await db.Departments.SingleOrDefaultAsync(d => d.Id == id, ct);
        if (row is null)
        {
            return HmsProblems.NotFound("Department not found.");
        }

        if (request.Name is not null)
        {
            var name = request.Name.Trim();
            if (name.Length is < 1 or > 80)
            {
                return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["name"] = ["Name is required (1-80 characters)."] });
            }

            row.Name = name;
        }

        if (request.IsActive is { } active)
        {
            row.IsActive = active;
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "A department with that name already exists.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(DepartmentDto.From(row));
    }

    private static async Task<Results<Ok<List<VisitTypeDto>>, ProblemHttpResult>> ListVisitTypesAsync(
        AppointmentsDbContext db, ITenantContext tenant, Guid? branchId, bool? activeOnly, CancellationToken ct)
    {
        if (branchId is { } branch && branch != Guid.Empty && !await BranchScope.ExistsInTenantAsync(db, tenant, branch, ct))
        {
            return HmsProblems.NotFound("Branch not found.");
        }

        await VisitTypeResolver.EnsureDefaultsAsync(db, tenant, ct);
        var rows = await VisitTypeResolver.LoadAsync(db, branchId is { } b && b != Guid.Empty ? b : null, activeOnly ?? true, ct);
        return TypedResults.Ok(rows.Select(ToDto).ToList());
    }

    private static async Task<Results<Ok<VisitSuggestionDto>, ValidationProblem, ProblemHttpResult>> SuggestVisitTypeAsync(
        AppointmentsDbContext db, ITenantContext tenant, TimeProvider clock, Guid? branchId, Guid? practitionerId, Guid? patientId, DateTimeOffset? startsAt, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.AppointmentsView) && !tenant.CanAtAnyBranch(HmsPermissions.AppointmentsBook)
            && !tenant.CanAtAnyBranch(HmsPermissions.AppointmentsBookFollowUpOwn) && !tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden();
        }

        var errors = new Dictionary<string, string[]>();
        if (branchId is null || branchId == Guid.Empty)
        {
            errors["branchId"] = ["Branch is required."];
        }

        if (practitionerId is null || practitionerId == Guid.Empty)
        {
            errors["practitionerId"] = ["Practitioner is required."];
        }

        if (patientId is null || patientId == Guid.Empty)
        {
            errors["patientId"] = ["Patient is required."];
        }

        if (startsAt is null)
        {
            errors["startsAt"] = ["Start is required (ISO-8601 instant with offset)."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!await BranchScope.ExistsInTenantAsync(db, tenant, branchId!.Value, ct))
        {
            return HmsProblems.NotFound("Branch not found.");
        }

        await VisitTypeResolver.EnsureDefaultsAsync(db, tenant, ct);
        var types = await VisitTypeResolver.LoadAsync(db, branchId, activeOnly: true, ct);
        var bookingDate = BranchTime.LocalDate(startsAt!.Value, tenant.TimeZoneFor(branchId.Value));
        var prior = await VisitTypeResolver.LatestPriorAsync(db, tenant, practitionerId!.Value, patientId!.Value, startsAt.Value, clock.GetUtcNow(), ct);
        var (chosen, suggested, priorId, reason) = VisitTypeRules.Suggest(types.Select(t => t.Effective).ToList(), prior, bookingDate);
        if (chosen.Id == Guid.Empty)
        {
            return TypedResults.Ok(new VisitSuggestionDto(null, null, null, null, null, false, null, null));
        }

        return TypedResults.Ok(new VisitSuggestionDto(
            chosen.Id, chosen.Code, chosen.Name, chosen.DurationMinutes, chosen.FeePaise, suggested, priorId, reason));
    }

    private static async Task<Results<Created<VisitTypeDto>, ValidationProblem, ProblemHttpResult>> CreateVisitTypeAsync(
        CreateVisitTypeRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can edit visit types.");
        }

        var errors = ValidateType(request.Code, request.Name, request.DefaultFeePaise, request.DurationMinutes, request.FollowUpValidDays, request.FollowUpFeePaise, creating: true, request.FollowUpFreeLimit);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var row = new VisitType
        {
            Code = request.Code!.Trim().ToLowerInvariant(),
            Name = request.Name!.Trim(),
            DefaultFeePaise = request.DefaultFeePaise!.Value,
            DurationMinutes = (short)request.DurationMinutes!.Value,
            FollowUpValidDays = request.FollowUpValidDays is { } d ? (short)d : null,
            FollowUpFeePaise = request.FollowUpFeePaise,
            FollowUpFreeLimit = request.FollowUpFreeLimit is { } n ? (short)n : VisitTypeRules.DefaultFreeFollowUps,
            SortOrder = (short)(request.SortOrder ?? 100),
        };
        db.VisitTypes.Add(row);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "A visit type with that code already exists.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Created($"/api/v1/visit-types/{row.Id}", ToDto(row));
    }

    private static async Task<Results<Ok<VisitTypeDto>, ValidationProblem, ProblemHttpResult>> UpdateVisitTypeAsync(
        Guid id, UpdateVisitTypeRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can edit visit types.");
        }

        var row = await db.VisitTypes.SingleOrDefaultAsync(t => t.Id == id, ct);
        if (row is null)
        {
            return HmsProblems.NotFound("Visit type not found.");
        }

        var errors = ValidateType(null, request.Name, request.DefaultFeePaise, request.DurationMinutes, request.FollowUpValidDays, request.FollowUpFeePaise, creating: false, request.FollowUpFreeLimit);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (request.Name is not null)
        {
            row.Name = request.Name.Trim();
        }

        if (request.DefaultFeePaise is { } fee)
        {
            row.DefaultFeePaise = fee;
        }

        if (request.DurationMinutes is { } minutes)
        {
            row.DurationMinutes = (short)minutes;
        }

        if (request.ClearFollowUpWindow == true)
        {
            row.FollowUpValidDays = null;
        }
        else if (request.FollowUpValidDays is { } days)
        {
            row.FollowUpValidDays = (short)days;
        }

        if (request.ClearFollowUpFee == true)
        {
            row.FollowUpFeePaise = null;
        }
        else if (request.FollowUpFeePaise is { } followFee)
        {
            row.FollowUpFeePaise = followFee;
        }

        if (request.ClearFollowUpFreeLimit == true)
        {
            row.FollowUpFreeLimit = null;
        }
        else if (request.FollowUpFreeLimit is { } limit)
        {
            row.FollowUpFreeLimit = (short)limit;
        }

        if (request.IsActive is { } active)
        {
            row.IsActive = active;
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(ToDto(row));
    }

    private static async Task<Results<NoContent, ProblemHttpResult>> DeleteVisitTypeAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can edit visit types.");
        }

        try
        {
            await RawSql.ScalarAsync(db, "select appointment.soft_delete_visit_type(@id)", ct, ("id", id));
            return TypedResults.NoContent();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<Results<Ok<List<VisitTypeOverrideDto>>, ProblemHttpResult>> ListOverridesAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can edit visit types.");
        }

        if (!await db.VisitTypes.AsNoTracking().AnyAsync(t => t.Id == id, ct))
        {
            return HmsProblems.NotFound("Visit type not found.");
        }

        var rows = await db.VisitTypeOverrides.AsNoTracking().Where(o => o.VisitTypeId == id).OrderBy(o => o.BranchId).ToListAsync(ct);
        return TypedResults.Ok(rows.Select(VisitTypeOverrideDto.From).ToList());
    }

    private static async Task<Results<Ok<VisitTypeOverrideDto>, ValidationProblem, ProblemHttpResult>> UpsertOverrideAsync(
        Guid id, UpsertVisitTypeOverrideRequest request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PractitionersManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can edit visit types.");
        }

        if (request.BranchId == Guid.Empty)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["branchId"] = ["Branch is required."] });
        }

        if (!tenant.CanAtBranch(request.BranchId, HmsPermissions.PractitionersManage))
        {
            return await BranchScope.DenyAsync(db, tenant, request.BranchId, "You cannot edit visit types at this branch.", ct);
        }

        var errors = new Dictionary<string, string[]>();
        if (!VisitTypeRules.ValidFee(request.FeePaise))
        {
            errors["feePaise"] = ["Fee must be zero or a positive number of paise."];
        }

        if (!VisitTypeRules.ValidDuration(request.DurationMinutes))
        {
            errors["durationMinutes"] = ["Duration must be 5 to 240 minutes."];
        }

        if (!VisitTypeRules.ValidWindow(request.FollowUpValidDays))
        {
            errors["followUpValidDays"] = ["Follow-up window must be 0 to 366 days."];
        }

        if (!VisitTypeRules.ValidFee(request.FollowUpFeePaise))
        {
            errors["followUpFeePaise"] = ["Follow-up fee must be zero or a positive number of paise."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!await db.VisitTypes.AsNoTracking().AnyAsync(t => t.Id == id, ct))
        {
            return HmsProblems.NotFound("Visit type not found.");
        }

        var row = await db.VisitTypeOverrides.SingleOrDefaultAsync(o => o.VisitTypeId == id && o.BranchId == request.BranchId, ct);
        if (row is null)
        {
            row = new VisitTypeOverride { VisitTypeId = id, BranchId = request.BranchId };
            db.VisitTypeOverrides.Add(row);
        }

        row.FeePaise = request.FeePaise;
        row.DurationMinutes = request.DurationMinutes is { } m ? (short)m : null;
        row.FollowUpValidDays = request.FollowUpValidDays is { } d ? (short)d : null;
        row.FollowUpFeePaise = request.FollowUpFeePaise;
        row.IsActive = true;
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "This branch already has an override for that visit type.") is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(VisitTypeOverrideDto.From(row));
    }

    private static Dictionary<string, string[]> ValidateType(
        string? code, string? name, long? fee, int? duration, int? window, long? followFee, bool creating, int? freeLimit = null)
    {
        var errors = new Dictionary<string, string[]>();
        if (creating && !VisitTypeRules.ValidCode(code?.Trim().ToLowerInvariant()))
        {
            errors["code"] = ["Code must be 2-32 lowercase letters, digits or underscores."];
        }

        if ((creating || name is not null) && (string.IsNullOrWhiteSpace(name) || name.Trim().Length > 80))
        {
            errors["name"] = ["Name is required (1-80 characters)."];
        }

        if ((creating || fee is not null) && !VisitTypeRules.ValidFee(fee))
        {
            errors["defaultFeePaise"] = ["Fee must be zero or a positive number of paise."];
        }

        if ((creating || duration is not null) && !VisitTypeRules.ValidDuration(duration))
        {
            errors["durationMinutes"] = ["Duration must be 5 to 240 minutes."];
        }

        if (!VisitTypeRules.ValidWindow(window))
        {
            errors["followUpValidDays"] = ["Follow-up window must be 0 to 366 days."];
        }

        if (!VisitTypeRules.ValidFee(followFee))
        {
            errors["followUpFeePaise"] = ["Follow-up fee must be zero or a positive number of paise."];
        }

        if (!VisitTypeRules.ValidFreeLimit(freeLimit))
        {
            errors["followUpFreeLimit"] = [$"Free follow-ups must be 0 to {VisitTypeRules.MaxFreeFollowUps}, or cleared for no limit."];
        }

        return errors;
    }

    private static VisitTypeDto ToDto(VisitTypeResolver.Loaded row) => new(
        row.Type.Id, row.Type.Code, row.Type.Name, row.Type.DefaultFeePaise, row.Type.DurationMinutes,
        row.Type.FollowUpValidDays, row.Type.FollowUpFeePaise, row.Type.SortOrder, row.Type.IsActive,
        row.Effective.FeePaise, row.Effective.DurationMinutes, row.Effective.FollowUpValidDays, row.Effective.FollowUpFeePaise,
        row.Type.FollowUpFreeLimit);

    private static VisitTypeDto ToDto(VisitType row)
    {
        var effective = VisitTypeRules.Apply(VisitTypeRules.From(row), null);
        return new(row.Id, row.Code, row.Name, row.DefaultFeePaise, row.DurationMinutes, row.FollowUpValidDays, row.FollowUpFeePaise,
            row.SortOrder, row.IsActive, effective.FeePaise, effective.DurationMinutes, effective.FollowUpValidDays, effective.FollowUpFeePaise,
            row.FollowUpFreeLimit);
    }
}

/// <summary>Loads effective visit types and the prior same-doctor visit used for the follow-up window.</summary>
internal static class VisitTypeResolver
{
    internal sealed record Loaded(VisitType Type, VisitTypeOverride? Branch, VisitTypeRules.Effective Effective);

    public static async Task EnsureDefaultsAsync(AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        // A custom type created before the first list must not block the five defaults. A soft-deleted
        // default stays deleted: IgnoreQueryFilters sees it, so it is not inserted again.
        var existing = await db.VisitTypes.IgnoreQueryFilters().AsNoTracking()
            .Where(t => t.TenantId == tenant.TenantId)
            .Select(t => t.Code)
            .ToListAsync(ct);
        if (existing.Count == 0 && db.Database.IsRelational())
        {
            await RawSql.ScalarAsync(db, "select appointment.ensure_default_visit_types(@tenant)", ct, ("tenant", tenant.TenantId));
            return;
        }

        var missing = VisitTypeRules.Defaults().Where(t => !existing.Contains(t.Code)).ToList();
        if (missing.Count == 0 || db.Database.IsRelational())
        {
            return;
        }

        db.VisitTypes.AddRange(missing);
        await db.SaveChangesAsync(ct);
    }

    public static async Task<List<Loaded>> LoadAsync(AppointmentsDbContext db, Guid? branchId, bool activeOnly, CancellationToken ct)
    {
        var types = await db.VisitTypes.AsNoTracking()
            .Where(t => !activeOnly || t.IsActive)
            .OrderBy(t => t.SortOrder).ThenBy(t => t.Name)
            .ToListAsync(ct);
        var ids = types.Select(t => t.Id).ToList();
        var overrides = branchId is { } branch
            ? await db.VisitTypeOverrides.AsNoTracking()
                .Where(o => o.BranchId == branch && o.IsActive && ids.Contains(o.VisitTypeId))
                .ToListAsync(ct)
            : [];
        return types.Select(type =>
        {
            var over = overrides.FirstOrDefault(o => o.VisitTypeId == type.Id);
            var effective = VisitTypeRules.Apply(VisitTypeRules.From(type), over is null ? null : VisitTypeRules.From(over));
            return new Loaded(type, over, effective);
        }).ToList();
    }

    public static async Task<VisitTypeRules.Prior?> LatestPriorAsync(
        AppointmentsDbContext db, ITenantContext tenant, Guid practitionerId, Guid patientId, DateTimeOffset startsAt, DateTimeOffset now, CancellationToken ct)
    {
        // Snapshots only. A deleted or edited visit type cannot change this. Cancelled and no-show do not count.
        // A booked visit counts only once its start is in the past. Null granted days (this visit opened no
        // window) are skipped so an older grant still applies; 0 is explicit and closes that older window.
        var prior = await db.Appointments.AsNoTracking()
            .Where(a => a.PractitionerId == practitionerId && a.PatientId == patientId && a.StartsAt < startsAt
                && a.GrantedFollowUpDays != null
                && (a.Status == AppointmentStatus.CheckedIn || a.Status == AppointmentStatus.InConsultation
                    || a.Status == AppointmentStatus.Completed
                    || (a.Status == AppointmentStatus.Booked && a.StartsAt < now)))
            .OrderByDescending(a => a.StartsAt)
            .Select(a => new { a.Id, a.StartsAt, a.BranchId, a.GrantedFollowUpDays, a.GrantedFollowUpFeePaise, a.GrantedFollowUpLimit })
            .FirstOrDefaultAsync(ct);
        if (prior is null)
        {
            return null;
        }

        // Cancelled and no-show follow-ups give the free follow-up back.
        var used = await db.Appointments.AsNoTracking()
            .CountAsync(a => a.FollowUpEntitlementId == prior.Id
                && a.Status != AppointmentStatus.Cancelled && a.Status != AppointmentStatus.NoShow, ct);

        return new VisitTypeRules.Prior(
            prior.Id,
            BranchTime.LocalDate(prior.StartsAt, tenant.TimeZoneFor(prior.BranchId)),
            prior.GrantedFollowUpDays,
            prior.GrantedFollowUpFeePaise,
            prior.GrantedFollowUpLimit,
            used);
    }

    public static async Task<(ResolvedVisit? Visit, ValidationProblem? Problem)> TryResolveAsync(
        AppointmentsDbContext db, ITenantContext tenant, Guid visitTypeId, Guid branchId, Guid practitionerId, Guid patientId, DateTimeOffset startsAt, DateTimeOffset now, CancellationToken ct)
    {
        await EnsureDefaultsAsync(db, tenant, ct);
        var loaded = await LoadAsync(db, branchId, activeOnly: true, ct);
        var selected = loaded.FirstOrDefault(t => t.Type.Id == visitTypeId);
        if (selected is null)
        {
            return (null, TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["visitTypeId"] = ["Visit type was not found."] }));
        }

        var prior = await LatestPriorAsync(db, tenant, practitionerId, patientId, startsAt, now, ct);
        var bookingDate = BranchTime.LocalDate(startsAt, tenant.TimeZoneFor(branchId));
        var quote = VisitTypeRules.QuoteFor(selected.Effective, prior, bookingDate);
        return (new ResolvedVisit(
            selected.Type.Id,
            startsAt.AddMinutes(selected.Effective.DurationMinutes),
            quote.FeePaise,
            selected.Effective.FollowUpValidDays,
            selected.Effective.FollowUpFeePaise,
            selected.Effective.FollowUpFreeLimit,
            quote.EntitlementId,
            quote.Note), null);
    }
}

internal readonly record struct ResolvedVisit(
    Guid VisitTypeId, DateTimeOffset EndsAt, long FeePaise, short? GrantedFollowUpDays, long? GrantedFollowUpFeePaise,
    short? GrantedFollowUpLimit, Guid? FollowUpEntitlementId, string? FeeNote);
