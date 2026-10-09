using Hms.Modules.Patients.Endpoints;

namespace Hms.Modules.Patients.Registry;

/// <summary>
/// The patient registry RPCs owned by the database (SPRINT2-CONTRACT §1.3, §1.5). They run on the
/// request's DbContext transaction, i.e. as <c>authenticated</c> with the caller's claims, so RLS and
/// the functions' own authorization apply. Errors surface as PostgreSQL SQLSTATEs (see HmsProblems).
/// </summary>
public interface IPatientRegistryFunctions
{
    /// <summary><c>patient.find_duplicate_patients</c>: advisory, RLS-scoped, max 20 rows, both-reasons first.</summary>
    Task<IReadOnlyList<DuplicateCandidateDto>> FindDuplicatesAsync(
        Guid tenantId, string? firstName, string? lastName, DateOnly? dateOfBirth, string? phone, Guid? excludePatientId, CancellationToken ct);

    /// <summary><c>patient.soft_delete_patient</c>: P0002 not found/deleted, 42501, 55000 open appointments/queue, 22023 reason too long.</summary>
    Task SoftDeleteAsync(Guid patientId, string? reason, CancellationToken ct);

    /// <summary><c>patient.restore_patient</c>: tenant_admin only; P0002 when not found / not deleted.</summary>
    Task RestoreAsync(Guid patientId, CancellationToken ct);
}
