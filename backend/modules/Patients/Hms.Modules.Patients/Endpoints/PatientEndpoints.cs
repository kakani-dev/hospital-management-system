using Hms.Platform.Http;
using System.Text.Json;
using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.Modules.Patients.Registry;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Time;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Patients.Endpoints;

public static class PatientEndpoints
{
    // Mirrors RLS policies in supabase/migrations/*_rls_policies_and_grants.sql
    // READ is tenant-wide for these roles (product decision); WRITE needs the role AT the patient's
    // branch (identity.has_branch_role in the DB, ITenantContext.HasRoleAtBranch here).

    /// <summary>Soft delete (D1): tenant_admin (tenant-wide) or receptionist AT the patient's branch.</summary>

    internal const int SearchMaxLength = 100;
    internal const int DeletionReasonMaxLength = 500;

    public static RouteGroupBuilder MapPatientEndpoints(this RouteGroupBuilder api)
    {
        var group = api.MapGroup("/patients").WithTags("Patients").RequireTenant().WithDbTransaction<PatientsDbContext>();

        group.MapGet("/", ListAsync).WithName("ListPatients")
            .WithSummary("Page through the registry (soft-deleted patients excluded). Searching is POST /patients/search (no PHI in URLs).");
        group.MapPost("/search", SearchAsync).WithName("SearchPatients")
            .WithSummary("Search by MRN / name, phone (normalized) and/or date of birth; terms are sent in the JSON body.");
        group.MapPost("/duplicates", DuplicatesAsync).WithName("FindDuplicatePatients")
            .WithSummary("Advisory duplicate check (name + DOB, or phone) before registering or editing a patient.");
        group.MapGet("/stats", StatsAsync).WithName("GetPatientStats")
            .WithSummary("Dashboard counts: live patients and those registered today (each branch's own local day). No PHI.");
        group.MapGet("/{id:guid}", GetAsync).WithName("GetPatient");
        group.MapPost("/", CreateAsync).WithName("CreatePatient");
        group.MapPatch("/{id:guid}", UpdateAsync).WithName("UpdatePatient")
            .WithSummary("Merge-patch edit. Needs a writer role at the patient's branch (and at the new branch when it changes).");
        group.MapDelete("/{id:guid}", DeleteAsync).WithName("DeletePatient")
            .WithSummary("Soft delete (patient.soft_delete_patient). tenant_admin, or receptionist at the patient's branch.");
        group.MapPost("/{id:guid}/restore", RestoreAsync).WithName("RestorePatient")
            .WithSummary("Restore a soft-deleted patient (tenant_admin only).");

        return api;
    }

    private static async Task<Results<Ok<PagedResult<PatientSummaryDto>>, ValidationProblem, ProblemHttpResult>> ListAsync(
        HttpRequest http, PatientsDbContext db, ITenantContext tenant, IPatientRegistryFunctions registry, int? page, int? pageSize, string? sort, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PatientsView))
        {
            return HmsProblems.Forbidden();
        }

        // ?search= was removed (PHI in URLs ends up in access logs). Fail loudly instead of silently
        // returning the unfiltered list to an old client.
        if (http.Query.ContainsKey("search"))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]>
            {
                ["search"] = ["The search query parameter is no longer supported. Use POST /api/v1/patients/search with a JSON body."],
            });
        }

        return sort switch
        {
            null or "" or "name" => TypedResults.Ok(await PageAsync(db.Patients.AsNoTracking(), page, pageSize, ct)),
            "recent" => TypedResults.Ok(await RecentPageAsync(db, tenant, registry, page, pageSize, ct)),
            _ => TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["sort"] = ["sort must be 'name' (default) or 'recent'."] }),
        };
    }

    /// <summary>
    /// ?sort=recent: newest first by the later of registration (created_on) and the latest booking
    /// (appointment.patient_last_booked_v1). The page is the top of the union of the newest
    /// registrations and the latest bookings, each fetched page×size deep, so it is exact. Patient rows
    /// come from this service's own RLS-scoped query (soft-deleted and other tenants never appear).
    /// </summary>
    private static async Task<PagedResult<PatientSummaryDto>> RecentPageAsync(
        PatientsDbContext db, ITenantContext tenant, IPatientRegistryFunctions registry, int? page, int? pageSize, CancellationToken ct)
    {
        var p = Math.Max(page ?? 1, 1);
        var size = Math.Clamp(pageSize ?? 25, 1, 100);
        var depth = Math.Min(p * size, 500);
        var booked = await registry.LastBookedAsync(tenant.TenantId, depth, ct);
        var lastBooked = booked.ToDictionary(b => b.PatientId, b => b.LastBookedAt);
        var bookedIds = lastBooked.Keys.ToList();

        var live = db.Patients.AsNoTracking();
        var newest = await live.OrderByDescending(x => x.CreatedOn).ThenBy(x => x.Id).Take(depth).ToListAsync(ct);
        var withBookings = bookedIds.Count == 0 ? [] : await live.Where(x => bookedIds.Contains(x.Id)).ToListAsync(ct);
        var items = newest.Concat(withBookings)
            .DistinctBy(x => x.Id)
            .Select(x => (Patient: x, At: lastBooked.TryGetValue(x.Id, out var at) && at > x.CreatedOn ? at : x.CreatedOn))
            .OrderByDescending(x => x.At).ThenBy(x => x.Patient.Id)
            .Skip((p - 1) * size).Take(size)
            .Select(x => PatientSummaryDto.From(x.Patient))
            .ToList();

        return new PagedResult<PatientSummaryDto>(items, p, size, await live.CountAsync(ct));
    }

    private static async Task<Results<Ok<PagedResult<PatientSummaryDto>>, ValidationProblem, ProblemHttpResult>> SearchAsync(
        PatientSearchRequest request, PatientsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PatientsView))
        {
            return HmsProblems.Forbidden();
        }

        // Deleted rows are visible to tenant_admin only (D1; RLS enforces the same).
        if (request.IncludeDeleted == true && !tenant.Can(HmsPermissions.PatientsRestore))
        {
            return HmsProblems.Forbidden("Only tenant admins can search deleted patients.");
        }

        var errors = new Dictionary<string, string[]>();
        if (request.Search is { Length: > SearchMaxLength })
        {
            errors["search"] = [$"Search term must be at most {SearchMaxLength} characters."];
        }

        string? phone = null;
        if (!string.IsNullOrWhiteSpace(request.Phone))
        {
            phone = request.Phone.Length > CreatePatientValidator.PhoneMaxLength ? null : PatientPhone.Normalize(request.Phone);
            if (phone is null)
            {
                errors["phone"] = [$"Phone must contain at least {PatientPhone.MinDigits} digits (max {CreatePatientValidator.PhoneMaxLength} characters)."];
            }
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        IQueryable<Patient> query = request.IncludeDeleted == true
            ? db.Patients.IgnoreQueryFilters().AsNoTracking().Where(x => x.TenantId == tenant.TenantId)
            : db.Patients.AsNoTracking();

        if (!string.IsNullOrWhiteSpace(request.Search))
        {
            var term = request.Search.Trim().ToLowerInvariant();
#pragma warning disable CA1862 // must stay an EF-translatable expression (lower(x) LIKE %term%) across providers
            query = query.Where(x =>
                x.Mrn.ToLower().Contains(term) || x.FirstName.ToLower().Contains(term) || x.LastName.ToLower().Contains(term));
#pragma warning restore CA1862
        }

        if (phone is not null)
        {
            // Any live number (phone or WhatsApp) in patient.patient_phones; normalize_phone(phone_e164)
            // = @normalized hits patient_phones_tenant_norm_idx.
            var phones = db.PatientPhones.AsNoTracking();
            query = query.Where(x => phones.Any(ph => ph.PatientId == x.Id && PatientsDbContext.NormalizePhone(ph.PhoneE164) == phone));
        }

        if (request.DateOfBirth is { } dob)
        {
            query = query.Where(x => x.DateOfBirth == dob);
        }

        return TypedResults.Ok(await PageAsync(query, request.Page, request.PageSize, ct));
    }

    /// <summary>
    /// GET /patients/stats[?branchId=]. Counts only (no PHI), read roles, RLS + tenant filter as for the
    /// list. "Today" is the local day of each patient's registered branch (else the tenant zone), so a
    /// branch-scoped dashboard and the hospital-wide one agree. Another tenant's or unknown branch: 404.
    /// </summary>
    private static async Task<Results<Ok<PatientStatsDto>, ProblemHttpResult>> StatsAsync(
        PatientsDbContext db, ITenantContext tenant, TimeProvider timeProvider, Guid? branchId, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PatientsView))
        {
            return HmsProblems.Forbidden();
        }

        var live = db.Patients.AsNoTracking();
        if (branchId is { } only)
        {
            // Branches of the tenant the caller can see come from the token's resolved context; the
            // patients service never reads identity tables directly.
            if (!tenant.BranchTimeZones.ContainsKey(only))
            {
                return HmsProblems.NotFound("Branch not found.");
            }

            live = live.Where(p => p.RegisteredBranchId == only);
        }

        var total = await live.LongCountAsync(ct);
        long today = 0;
        var known = branchId is { } b ? [b] : tenant.BranchTimeZones.Keys.ToList();
        foreach (var branch in known)
        {
            var (start, end) = DayRange(timeProvider, tenant.TimeZoneFor(branch));
            today += await live.LongCountAsync(p => p.RegisteredBranchId == branch && p.CreatedOn >= start && p.CreatedOn < end, ct);
        }

        if (branchId is null)
        {
            // Patients of branches outside the caller's context (reads are tenant-wide): the tenant's day.
            var (start, end) = DayRange(timeProvider, tenant.TenantTimeZone);
            today += await live.LongCountAsync(p => !known.Contains(p.RegisteredBranchId) && p.CreatedOn >= start && p.CreatedOn < end, ct);
        }

        return TypedResults.Ok(new PatientStatsDto(total, today));
    }

    private static (DateTimeOffset Start, DateTimeOffset End) DayRange(TimeProvider clock, string zone) =>
        BranchTime.DayRangeUtc(BranchTime.Today(clock, zone), zone);

    private static async Task<PagedResult<PatientSummaryDto>> PageAsync(IQueryable<Patient> query, int? page, int? pageSize, CancellationToken ct)
    {
        var p = Math.Max(page ?? 1, 1);
        var size = Math.Clamp(pageSize ?? 25, 1, 100);

        var total = await query.CountAsync(ct);
        var items = await query
            .OrderBy(x => x.LastName).ThenBy(x => x.FirstName).ThenBy(x => x.Id)
            .Skip((p - 1) * size).Take(size)
            .ToListAsync(ct);

        return new PagedResult<PatientSummaryDto>([.. items.Select(PatientSummaryDto.From)], p, size, total);
    }

    private static async Task<Results<Ok<DuplicateCheckResponse>, ValidationProblem, ProblemHttpResult>> DuplicatesAsync(
        DuplicateCheckRequest request, ITenantContext tenant, IPatientRegistryFunctions registry, CancellationToken ct)
    {
        if (!tenant.CanAtAnyBranch(HmsPermissions.PatientsCreate))
        {
            return HmsProblems.Forbidden();
        }

        var errors = new Dictionary<string, string[]>();
        if (request.FirstName is { Length: > 100 })
        {
            errors["firstName"] = ["First name must be at most 100 characters."];
        }

        if (request.LastName is { Length: > 100 })
        {
            errors["lastName"] = ["Last name must be at most 100 characters."];
        }

        if (request.Phone is { Length: > CreatePatientValidator.PhoneMaxLength })
        {
            errors["phone"] = [$"Phone must be at most {CreatePatientValidator.PhoneMaxLength} characters."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        try
        {
            var candidates = await FindDuplicatesAsync(
                registry, tenant, request.FirstName, request.LastName, request.DateOfBirth, request.Phone, request.ExcludePatientId, ct);
            return TypedResults.Ok(new DuplicateCheckResponse(candidates));
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            // contract v4: foreign tenant -> P0002 (404), member without registry read -> 42501 (403)
            return problem;
        }
    }

    private static async Task<Results<Ok<PatientDetailDto>, ProblemHttpResult>> GetAsync(
        Guid id, PatientsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PatientsView))
        {
            return HmsProblems.Forbidden();
        }

        // Another tenant's id / a soft-deleted patient is indistinguishable from a non-existent one.
        var patient = await db.Patients.AsNoTracking().SingleOrDefaultAsync(x => x.Id == id, ct);
        return patient is null
            ? HmsProblems.NotFound("Patient not found.")
            : TypedResults.Ok(PatientDetailDto.From(patient, await PatientPhones.LoadAsync(db, patient.Id, ct)));
    }

    private static async Task<Results<Created<PatientCreatedDto>, ValidationProblem, ProblemHttpResult>> CreateAsync(
        CreatePatientRequest request, PatientsDbContext db, ITenantContext tenant, TimeProvider timeProvider,
        IPatientRegistryFunctions registry, CancellationToken ct)
    {
        // Cheap early 403 for users who cannot write anywhere; the authoritative check is per branch below.
        if (!tenant.CanAtAnyBranch(HmsPermissions.PatientsCreate))
        {
            return HmsProblems.Forbidden();
        }

        var branchTimeZone = tenant.TimeZoneFor(request.RegisteredBranchId);
        var errors = CreatePatientValidator.Validate(request, BranchClock.Today(timeProvider, branchTimeZone));

        // Phones (Level 1): normalized to E.164 with the tenant's calling code (tenant from the token only).
        var countryCode = await registry.DefaultCountryCodeAsync(tenant.TenantId, ct) ?? PhoneE164.FallbackCountryCode;
        var phoneE164 = PatientPhones.NormalizePhone(request.Phone, countryCode, errors);
        var (whatsappSame, whatsappE164) = PatientPhones.ResolveWhatsapp(request.Whatsapp, request.Phone, phoneE164, countryCode, errors);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        // M1: the writer role must be held AT the registering branch (not "some role somewhere" +
        // "some branch somewhere"). Branches of other tenants are never in the map.
        if (!tenant.CanAtBranch(request.RegisteredBranchId, HmsPermissions.PatientsCreate))
        {
            // 404-not-403: another tenant's branch is 404; a same-tenant branch without the role stays 403.
            return await BranchScope.DenyAsync(db, tenant, request.RegisteredBranchId, "You cannot register patients at this branch.", ct);
        }

        // The MRN is server-generated (Level 1): any client-supplied "mrn" is ignored. The DB trigger
        // patient.assign_mrn() takes the next number from the tenant's counter and EF reads it back.
        // Advisory duplicate detection (D3). Runs before the insert so the new row never matches itself.
        var warnings = await FindDuplicatesAsync(
            registry, tenant, request.FirstName, request.LastName, request.DateOfBirth, phoneE164 ?? whatsappE164, null, ct);

        var patient = new Patient
        {
            FirstName = request.FirstName!.Trim(),
            LastName = request.LastName!.Trim(),
            DateOfBirth = request.DateOfBirth,
            Sex = request.Sex ?? PatientSex.Unknown,
            RegisteredBranchId = request.RegisteredBranchId,
            Email = request.Email,
            AbhaNumber = CreatePatientValidator.NormalizeAbha(request.AbhaNumber),
            // TenantId is assigned by TenantSaveChangesInterceptor from the resolved context.
            // Audit columns are DB-managed and never sent (see AuditColumnConventions).
        };
        db.Patients.Add(patient);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (IsDuplicateAbha(ex))
        {
            return DuplicateAbha();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, HmsProblems.Codes.DuplicateMrn, uniqueDetail: DuplicateMrnDetail) is { } problem)
        {
            return problem;
        }

        if (phoneE164 is not null || whatsappE164 is not null)
        {
            try
            {
                await registry.SetPhonesAsync(patient.Id, phoneE164, whatsappSame, whatsappE164, ct);
                patient.Phone = phoneE164; // the DB function rewrote the deprecated mirror
            }
            catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
            {
                return problem;
            }
        }

        var phones = await PatientPhones.LoadAsync(db, patient.Id, ct);
        return TypedResults.Created($"/api/v1/patients/{patient.Id}", PatientCreatedDto.From(patient, warnings, phones));
    }

    private static async Task<Results<Ok<PatientDetailDto>, ValidationProblem, ProblemHttpResult>> UpdateAsync(
        Guid id, JsonElement body, PatientsDbContext db, ITenantContext tenant, TimeProvider timeProvider,
        IPatientRegistryFunctions registry, CancellationToken ct)
    {
        if (!tenant.CanAtAnyBranch(HmsPermissions.PatientsEdit))
        {
            return HmsProblems.Forbidden();
        }

        var errors = new Dictionary<string, string[]>();
        var patch = PatientPatch.Parse(body, errors);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var patient = await db.Patients.SingleOrDefaultAsync(x => x.Id == id, ct);
        if (patient is null)
        {
            return HmsProblems.NotFound("Patient not found.");
        }

        // Authorize against the CURRENT branch, and the NEW branch when it moves (mirrors RLS USING / WITH CHECK).
        if (!tenant.CanAtBranch(patient.RegisteredBranchId, HmsPermissions.PatientsEdit))
        {
            return HmsProblems.Forbidden("You cannot edit patients registered at this branch.");
        }

        var targetBranch = patch.RegisteredBranchId.Or(patient.RegisteredBranchId) ?? patient.RegisteredBranchId;
        if (targetBranch != patient.RegisteredBranchId && !tenant.CanAtBranch(targetBranch, HmsPermissions.PatientsEdit))
        {
            return await BranchScope.DenyAsync(db, tenant, targetBranch, "You cannot move patients to that branch.", ct);
        }

        // The MRN is server-generated and immutable: sending the current value (any case) is a no-op,
        // anything else is rejected (the DB also refuses UPDATE of mrn).
        if (patch.Mrn.IsSet && (patch.Mrn.Value is null
            || !string.Equals(CreatePatientValidator.NormalizeMrn(patch.Mrn.Value), patient.Mrn.ToUpperInvariant(), StringComparison.Ordinal)))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["mrn"] = ["The MRN is generated by the system and cannot be changed."] });
        }

        var merged = new CreatePatientRequest(
            patch.FirstName.Or(patient.FirstName),
            patch.LastName.Or(patient.LastName),
            patch.DateOfBirth.Or(patient.DateOfBirth),
            patch.Sex.IsSet && patch.Sex.Value is null ? "\0" : patch.Sex.Or(patient.Sex), // explicit null sex is invalid
            targetBranch,
            patch.Phone.Or(patient.Phone),
            patch.Email.Or(patient.Email),
            AbhaNumber: patch.AbhaNumber.Or(patient.AbhaNumber));

        var branchTimeZone = tenant.TimeZoneFor(targetBranch);
        errors = CreatePatientValidator.Validate(merged, BranchClock.Today(timeProvider, branchTimeZone));

        // Phones: only touched when the patch names phone and/or whatsapp.
        var phonesChange = patch.Phone.IsSet || patch.Whatsapp.IsSet;
        var current = await PatientPhones.LoadRowsAsync(db, patient.Id, ct);
        string? phoneE164 = null;
        bool whatsappSame = false;
        string? whatsappE164 = null;
        if (phonesChange)
        {
            var countryCode = await registry.DefaultCountryCodeAsync(tenant.TenantId, ct) ?? PhoneE164.FallbackCountryCode;
            var currentPrimary = current.FirstOrDefault(x => x.IsPrimary);
            var currentWhatsapp = current.FirstOrDefault(x => x.IsWhatsapp);
            phoneE164 = patch.Phone.IsSet
                ? PatientPhones.NormalizePhone(patch.Phone.Value, countryCode, errors)
                : currentPrimary?.PhoneE164 ?? PhoneE164.Normalize(patient.Phone, countryCode);
            if (patch.Whatsapp.IsSet)
            {
                (whatsappSame, whatsappE164) = PatientPhones.ResolveWhatsapp(
                    patch.Whatsapp.Value ?? new WhatsappInput(false, null), patch.Phone.IsSet ? patch.Phone.Value : phoneE164, phoneE164, countryCode, errors);
            }
            else if (currentWhatsapp is not null && currentWhatsapp.IsPrimary)
            {
                // WhatsApp followed the phone: it keeps following it; if the phone is removed, the
                // old number stays as the WhatsApp number.
                (whatsappSame, whatsappE164) = phoneE164 is not null ? (true, null) : (false, currentWhatsapp.PhoneE164);
            }
            else
            {
                whatsappE164 = currentWhatsapp?.PhoneE164;
                whatsappSame = whatsappE164 is not null && whatsappE164 == phoneE164;
            }
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        patient.FirstName = merged.FirstName!.Trim();
        patient.LastName = merged.LastName!.Trim();
        patient.DateOfBirth = merged.DateOfBirth;
        patient.Sex = merged.Sex!;
        patient.RegisteredBranchId = targetBranch;
        patient.Email = merged.Email;
        patient.AbhaNumber = CreatePatientValidator.NormalizeAbha(merged.AbhaNumber);

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            // 0 rows: deleted concurrently, or RLS USING hid it (deleted_at is not null).
            return HmsProblems.NotFound("Patient not found.");
        }
        catch (Exception ex) when (IsDuplicateAbha(ex))
        {
            return DuplicateAbha();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        if (phonesChange)
        {
            try
            {
                await registry.SetPhonesAsync(patient.Id, phoneE164, whatsappSame, whatsappE164, ct);
                patient.Phone = phoneE164; // the DB function rewrote the deprecated mirror
            }
            catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
            {
                return problem;
            }
        }

        return TypedResults.Ok(PatientDetailDto.From(patient, await PatientPhones.LoadAsync(db, patient.Id, ct)));
    }

    private static async Task<Results<NoContent, ValidationProblem, ProblemHttpResult>> DeleteAsync(
        Guid id, [FromBody(EmptyBodyBehavior = EmptyBodyBehavior.Allow)] DeletePatientRequest? request, PatientsDbContext db, ITenantContext tenant, IPatientRegistryFunctions registry, CancellationToken ct)
    {
        if (!tenant.CanAtAnyBranch(HmsPermissions.PatientsDelete))
        {
            return HmsProblems.Forbidden();
        }

        if (request?.Reason is { Length: > DeletionReasonMaxLength })
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]>
            {
                ["reason"] = [$"Reason must be at most {DeletionReasonMaxLength} characters."],
            });
        }

        var patient = await db.Patients.AsNoTracking().SingleOrDefaultAsync(x => x.Id == id, ct);
        if (patient is null)
        {
            return HmsProblems.NotFound("Patient not found.");
        }

        if (!tenant.CanAtBranch(patient.RegisteredBranchId, HmsPermissions.PatientsDelete))
        {
            return HmsProblems.Forbidden("You cannot delete patients registered at this branch.");
        }

        try
        {
            await registry.SoftDeleteAsync(id, string.IsNullOrWhiteSpace(request?.Reason) ? null : request.Reason.Trim(), ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.NoContent();
    }

    private static async Task<Results<NoContent, ProblemHttpResult>> RestoreAsync(
        Guid id, ITenantContext tenant, IPatientRegistryFunctions registry, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PatientsRestore))
        {
            return HmsProblems.Forbidden("Only tenant admins can restore patients.");
        }

        try
        {
            await registry.RestoreAsync(id, ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.NoContent();
    }

    private static async Task<IReadOnlyList<DuplicateCandidateDto>> FindDuplicatesAsync(
        IPatientRegistryFunctions registry, ITenantContext tenant, string? firstName, string? lastName, DateOnly? dob, string? phone,
        Guid? excludeId, CancellationToken ct)
    {
        var byNameDob = !string.IsNullOrWhiteSpace(firstName) && !string.IsNullOrWhiteSpace(lastName) && dob is not null;
        var byPhone = PatientPhone.Normalize(phone) is not null;
        if (!byNameDob && !byPhone)
        {
            return [];
        }

        return await registry.FindDuplicatesAsync(tenant.TenantId, firstName, lastName, dob, phone, excludeId, ct);
    }

    /// <summary>
    /// Authorization for creating OR updating a patient registered at <paramref name="branchId"/>.
    /// Update endpoints call this with the patient's CURRENT branch and, when the branch changes,
    /// the NEW branch too (mirrors the RLS USING/WITH CHECK pair).
    /// </summary>

    private const string DuplicateMrnDetail = "A patient with this MRN already exists in this hospital.";


    private static bool IsDuplicateAbha(Exception ex) =>
        HmsProblems.FindDbError(ex) is Npgsql.PostgresException { SqlState: "23505", ConstraintName: "patients_tenant_abha_key" };

    private static ProblemHttpResult DuplicateAbha() =>
        HmsProblems.Conflict("duplicate_abha", "Another patient in this hospital already has this ABHA number.");
}
