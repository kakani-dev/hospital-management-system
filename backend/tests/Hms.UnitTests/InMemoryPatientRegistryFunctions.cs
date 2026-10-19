using Hms.Modules.Patients.Endpoints;
using Hms.Modules.Patients.Persistence;
using Hms.Modules.Patients.Registry;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;

namespace Hms.UnitTests;

/// <summary>
/// Unit-test stand-in for the DB registry RPCs (SPRINT2-CONTRACT §1.3/§1.5) over EF InMemory. It
/// mirrors the documented rules closely enough to exercise the endpoints; the real functions are
/// covered by Hms.IntegrationTests and the SQL tests.
/// </summary>
internal sealed class InMemoryPatientRegistryFunctions(PatientsDbContext db, ITenantContext tenant, TimeProvider clock) : IPatientRegistryFunctions
{
    public async Task<IReadOnlyList<DuplicateCandidateDto>> FindDuplicatesAsync(
        Guid tenantId, string? firstName, string? lastName, DateOnly? dateOfBirth, string? phone, Guid? excludePatientId, CancellationToken ct)
    {
        var first = firstName?.Trim();
        var last = lastName?.Trim();
        var normalized = PatientPhone.Normalize(phone);
        var rows = await db.Patients.AsNoTracking().Where(p => p.TenantId == tenantId && p.Id != excludePatientId).ToListAsync(ct);
        return rows
            .Select(p =>
            {
                var reasons = new List<string>();
                if (dateOfBirth is not null && p.DateOfBirth == dateOfBirth
                    && string.Equals(p.FirstName.Trim(), first, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(p.LastName.Trim(), last, StringComparison.OrdinalIgnoreCase))
                {
                    reasons.Add("name_dob");
                }

                if (normalized is not null && PatientPhone.Normalize(p.Phone) == normalized)
                {
                    reasons.Add("phone");
                }

                return new DuplicateCandidateDto(p.Id, p.Mrn, p.FirstName, p.LastName, p.DateOfBirth, p.Phone, p.RegisteredBranchId, reasons);
            })
            .Where(c => c.MatchReasons.Count > 0)
            .OrderByDescending(c => c.MatchReasons.Count).ThenBy(c => c.LastName).ThenBy(c => c.FirstName).ThenBy(c => c.Mrn)
            .Take(20)
            .ToList();
    }

    public async Task SoftDeleteAsync(Guid patientId, string? reason, CancellationToken ct)
    {
        var patient = await db.Patients.SingleOrDefaultAsync(p => p.Id == patientId, ct) ?? throw new FakeDbException("P0002");
        if (!tenant.HasRoleAtBranch(patient.RegisteredBranchId, HmsRoles.TenantAdmin, HmsRoles.Receptionist))
        {
            throw new FakeDbException("42501");
        }

        patient.DeletedAt = clock.GetUtcNow();
        patient.IsDeleted = true; // generated from deleted_at in PostgreSQL
        await db.SaveChangesAsync(ct);
    }

    public async Task RestoreAsync(Guid patientId, CancellationToken ct)
    {
        var patient = await db.Patients.IgnoreQueryFilters()
            .SingleOrDefaultAsync(p => p.Id == patientId && p.TenantId == tenant.TenantId && p.DeletedAt != null, ct)
            ?? throw new FakeDbException("P0002");
        patient.DeletedAt = null;
        patient.IsDeleted = false;
        await db.SaveChangesAsync(ct);
    }
}

internal sealed class FakeDbException(string sqlState, string message = "fake") : System.Data.Common.DbException(message)
{
    public override string SqlState { get; } = sqlState;
}
