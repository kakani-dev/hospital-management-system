using Hms.Platform.Http;
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

    /// <summary><c>identity.tenant_default_country_code_v1</c>: the caller's own tenant calling code (e.g. +91); null if not a member.</summary>
    Task<string?> DefaultCountryCodeAsync(Guid tenantId, CancellationToken ct);

    /// <summary>
    /// <c>patient.set_patient_phones</c>: sets the DESIRED numbers (E.164 or null). whatsappSameAsPhone
    /// flags the phone row; otherwise whatsapp is a separate number (equal to phone = same row).
    /// 22023 invalid, P0002 not found, 42501 no writer role at the patient's branch.
    /// </summary>
    Task SetPhonesAsync(Guid patientId, string? phone, bool whatsappSameAsPhone, string? whatsapp, CancellationToken ct);
}
