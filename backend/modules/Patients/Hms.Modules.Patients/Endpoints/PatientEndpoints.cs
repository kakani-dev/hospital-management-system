using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Patients.Endpoints;

public static class PatientEndpoints
{
    // Mirrors RLS policies in supabase/migrations/*_rls_policies_and_grants.sql
    // READ is tenant-wide for these roles (product decision); WRITE needs the role AT the patient's
    // branch (identity.has_branch_role in the DB, ITenantContext.HasRoleAtBranch here).
    internal static readonly string[] ReadRoles = [HmsRoles.TenantAdmin, HmsRoles.Doctor, HmsRoles.Nurse, HmsRoles.Receptionist, HmsRoles.Billing];
    internal static readonly string[] WriteRoles = [HmsRoles.TenantAdmin, HmsRoles.Doctor, HmsRoles.Nurse, HmsRoles.Receptionist];

    internal const int SearchMaxLength = 100;

    public static RouteGroupBuilder MapPatientEndpoints(this RouteGroupBuilder api)
    {
        var group = api.MapGroup("/patients").WithTags("Patients").RequireTenant().WithDbTransaction<PatientsDbContext>();

        group.MapGet("/", ListAsync).WithName("ListPatients")
            .WithSummary("Page through the registry. Searching moved to POST /patients/search (no PHI in URLs).");
        group.MapPost("/search", SearchAsync).WithName("SearchPatients")
            .WithSummary("Search by MRN / first / last name; the term is sent in the JSON body.");
        group.MapGet("/{id:guid}", GetAsync).WithName("GetPatient");
        group.MapPost("/", CreateAsync).WithName("CreatePatient");

        return api;
    }

    private static async Task<Results<Ok<PagedResult<PatientSummaryDto>>, ValidationProblem, ProblemHttpResult>> ListAsync(
        HttpRequest http, PatientsDbContext db, ITenantContext tenant, int? page, int? pageSize, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(ReadRoles))
        {
            return Forbidden();
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

        return TypedResults.Ok(await PageAsync(db, null, page, pageSize, ct));
    }

    private static async Task<Results<Ok<PagedResult<PatientSummaryDto>>, ValidationProblem, ProblemHttpResult>> SearchAsync(
        PatientSearchRequest request, PatientsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(ReadRoles))
        {
            return Forbidden();
        }

        if (request.Search is { Length: > SearchMaxLength })
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]>
            {
                ["search"] = [$"Search term must be at most {SearchMaxLength} characters."],
            });
        }

        return TypedResults.Ok(await PageAsync(db, request.Search, request.Page, request.PageSize, ct));
    }

    private static async Task<PagedResult<PatientSummaryDto>> PageAsync(
        PatientsDbContext db, string? search, int? page, int? pageSize, CancellationToken ct)
    {
        var p = Math.Max(page ?? 1, 1);
        var size = Math.Clamp(pageSize ?? 25, 1, 100);

        var query = db.Patients.AsNoTracking();
        if (!string.IsNullOrWhiteSpace(search))
        {
            var term = search.Trim().ToLowerInvariant();
#pragma warning disable CA1862 // must stay an EF-translatable expression (lower(x) LIKE %term%) across providers
            query = query.Where(x =>
                x.Mrn.ToLower().Contains(term) || x.FirstName.ToLower().Contains(term) || x.LastName.ToLower().Contains(term));
#pragma warning restore CA1862
        }

        var total = await query.CountAsync(ct);
        var items = await query
            .OrderBy(x => x.LastName).ThenBy(x => x.FirstName).ThenBy(x => x.Id)
            .Skip((p - 1) * size).Take(size)
            .ToListAsync(ct);

        return new PagedResult<PatientSummaryDto>([.. items.Select(PatientSummaryDto.From)], p, size, total);
    }

    private static async Task<Results<Ok<PatientSummaryDto>, NotFound, ProblemHttpResult>> GetAsync(
        Guid id, PatientsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(ReadRoles))
        {
            return Forbidden();
        }

        // Another tenant's id is indistinguishable from a non-existent one (404, no existence leak).
        var patient = await db.Patients.AsNoTracking().SingleOrDefaultAsync(x => x.Id == id, ct);
        return patient is null ? TypedResults.NotFound() : TypedResults.Ok(PatientSummaryDto.From(patient));
    }

    private static async Task<Results<Created<PatientSummaryDto>, ValidationProblem, ProblemHttpResult>> CreateAsync(
        CreatePatientRequest request, PatientsDbContext db, ITenantContext tenant, TimeProvider timeProvider, CancellationToken ct)
    {
        // Cheap early 403 for users who cannot write anywhere; the authoritative check is per branch below.
        if (!CanWriteAtAnyBranch(tenant))
        {
            return Forbidden();
        }

        tenant.BranchTimeZones.TryGetValue(request.RegisteredBranchId, out var branchTimeZone);
        var errors = CreatePatientValidator.Validate(request, BranchClock.Today(timeProvider, branchTimeZone));
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        // M1: the writer role must be held AT the registering branch (not "some role somewhere" +
        // "some branch somewhere"). Branches of other tenants are never in the map.
        if (!CanWritePatientAt(tenant, request.RegisteredBranchId))
        {
            return Forbidden("You cannot register patients at this branch.");
        }

        var mrn = CreatePatientValidator.NormalizeMrn(request.Mrn!);
#pragma warning disable CA1862 // must translate to upper(mrn) = @mrn (matches the unique upper(mrn) index; catches legacy mixed-case rows)
        if (await db.Patients.AnyAsync(x => x.Mrn.ToUpper() == mrn, ct))
#pragma warning restore CA1862
        {
            return DuplicateMrn();
        }

        var patient = new Patient
        {
            Mrn = mrn,
            FirstName = request.FirstName!.Trim(),
            LastName = request.LastName!.Trim(),
            DateOfBirth = request.DateOfBirth,
            Sex = request.Sex ?? PatientSex.Unknown,
            RegisteredBranchId = request.RegisteredBranchId,
            Phone = request.Phone,
            Email = request.Email,
            // TenantId is assigned by TenantSaveChangesInterceptor from the resolved context.
            // Audit columns are DB-managed and never sent (see AuditColumnConventions).
        };
        db.Patients.Add(patient);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex) when (ex.InnerException is Npgsql.PostgresException { SqlState: Npgsql.PostgresErrorCodes.UniqueViolation })
        {
            return DuplicateMrn();
        }
        catch (DbUpdateException ex) when (ex.InnerException is Npgsql.PostgresException { SqlState: Npgsql.PostgresErrorCodes.InsufficientPrivilege })
        {
            // RLS (defense in depth) rejected a write the API-level checks allowed.
            return Forbidden("The database rejected this write for your memberships.");
        }

        return TypedResults.Created($"/api/v1/patients/{patient.Id}", PatientSummaryDto.From(patient));
    }

    /// <summary>
    /// Authorization for creating OR updating a patient registered at <paramref name="branchId"/>.
    /// Any future update endpoint must call this with the patient's CURRENT branch and, when the
    /// branch changes, the NEW branch too (mirrors the RLS USING/WITH CHECK pair).
    /// </summary>
    internal static bool CanWritePatientAt(ITenantContext tenant, Guid branchId) => tenant.HasRoleAtBranch(branchId, WriteRoles);

    private static bool CanWriteAtAnyBranch(ITenantContext tenant) =>
        tenant.IsResolved && tenant.RolesByBranch.Keys.Any(branch => tenant.HasRoleAtBranch(branch, WriteRoles));

    private static ProblemHttpResult DuplicateMrn() =>
        TypedResults.Problem(title: "Duplicate MRN", detail: "A patient with this MRN already exists in this hospital.", statusCode: StatusCodes.Status409Conflict);

    private static ProblemHttpResult Forbidden(string? detail = null) =>
        TypedResults.Problem(title: "Forbidden", detail: detail ?? "Your role does not permit this action.", statusCode: StatusCodes.Status403Forbidden);
}
