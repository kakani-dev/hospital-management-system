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
    internal static readonly string[] ReadRoles = [HmsRoles.TenantAdmin, HmsRoles.Doctor, HmsRoles.Nurse, HmsRoles.Receptionist, HmsRoles.Billing];
    internal static readonly string[] WriteRoles = [HmsRoles.TenantAdmin, HmsRoles.Doctor, HmsRoles.Nurse, HmsRoles.Receptionist];

    public static RouteGroupBuilder MapPatientEndpoints(this RouteGroupBuilder api)
    {
        var group = api.MapGroup("/patients").WithTags("Patients").RequireTenant().WithDbTransaction<PatientsDbContext>();

        group.MapGet("/", ListAsync).WithName("ListPatients");
        group.MapGet("/{id:guid}", GetAsync).WithName("GetPatient");
        group.MapPost("/", CreateAsync).WithName("CreatePatient");

        return api;
    }

    private static async Task<Results<Ok<PagedResult<PatientSummaryDto>>, ProblemHttpResult>> ListAsync(
        PatientsDbContext db, ITenantContext tenant, string? search, int? page, int? pageSize, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(ReadRoles))
        {
            return Forbidden();
        }

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

        return TypedResults.Ok(new PagedResult<PatientSummaryDto>([.. items.Select(PatientSummaryDto.From)], p, size, total));
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
        CreatePatientRequest request, PatientsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.HasAnyRole(WriteRoles))
        {
            return Forbidden();
        }

        var errors = CreatePatientValidator.Validate(request);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!tenant.CanAccessBranch(request.RegisteredBranchId))
        {
            return Forbidden("You cannot register patients at this branch.");
        }

        var mrn = request.Mrn!.Trim();
        if (await db.Patients.AnyAsync(x => x.Mrn == mrn, ct))
        {
            return TypedResults.Problem(title: "Duplicate MRN", detail: "A patient with this MRN already exists in this hospital.", statusCode: StatusCodes.Status409Conflict);
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
        };
        db.Patients.Add(patient);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex) when (ex.InnerException is Npgsql.PostgresException { SqlState: Npgsql.PostgresErrorCodes.UniqueViolation })
        {
            return TypedResults.Problem(title: "Duplicate MRN", detail: "A patient with this MRN already exists in this hospital.", statusCode: StatusCodes.Status409Conflict);
        }
        catch (DbUpdateException ex) when (ex.InnerException is Npgsql.PostgresException { SqlState: Npgsql.PostgresErrorCodes.InsufficientPrivilege })
        {
            // RLS (defense in depth) rejected a write the API-level checks allowed.
            return Forbidden("The database rejected this write for your memberships.");
        }

        return TypedResults.Created($"/api/v1/patients/{patient.Id}", PatientSummaryDto.From(patient));
    }

    private static ProblemHttpResult Forbidden(string? detail = null) =>
        TypedResults.Problem(title: "Forbidden", detail: detail ?? "Your role does not permit this action.", statusCode: StatusCodes.Status403Forbidden);
}
