using Hms.Modules.Patients.Endpoints;
using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Persistence;

namespace Hms.Modules.Patients.Registry;

public sealed class PostgresPatientRegistryFunctions(PatientsDbContext db) : IPatientRegistryFunctions
{
    internal const string FindDuplicatesSql =
        "select patient_id, mrn, first_name, last_name, date_of_birth, phone, registered_branch_id, match_reasons " +
        "from patient.find_duplicate_patients(@tenant::uuid, @first::text, @last::text, @dob::date, @phone::text, @exclude::uuid, @email::text, @abha::text)";

    public async Task<IReadOnlyList<DuplicateCandidateDto>> FindDuplicatesAsync(
        Guid tenantId, string? firstName, string? lastName, DateOnly? dateOfBirth, string? phone, Guid? excludePatientId,
        string? email, string? abha, CancellationToken ct) =>
        await RawSql.QueryAsync(
            db,
            FindDuplicatesSql,
            r => new DuplicateCandidateDto(
                r.GetGuid(0),
                r.GetString(1),
                r.GetString(2),
                r.GetString(3),
                r.IsDBNull(4) ? null : r.GetFieldValue<DateOnly>(4),
                r.IsDBNull(5) ? null : r.GetString(5),
                r.GetGuid(6),
                r.IsDBNull(7) ? [] : r.GetFieldValue<string[]>(7)),
            ct,
            ("tenant", tenantId),
            ("first", firstName),
            ("last", lastName),
            ("dob", dateOfBirth),
            ("phone", phone),
            ("exclude", excludePatientId),
            ("email", email),
            ("abha", abha));

    public Task SoftDeleteAsync(Guid patientId, string? reason, CancellationToken ct) =>
        RawSql.ScalarAsync(db, "select patient.soft_delete_patient(@id::uuid, @reason::text)", ct, ("id", patientId), ("reason", reason));

    public Task RestoreAsync(Guid patientId, CancellationToken ct) =>
        RawSql.ScalarAsync(db, "select patient.restore_patient(@id::uuid)", ct, ("id", patientId));

    public async Task<string?> DefaultCountryCodeAsync(Guid tenantId, CancellationToken ct) =>
        await RawSql.ScalarAsync(db, "select identity.tenant_default_country_code_v1(@tenant::uuid)", ct, ("tenant", tenantId)) as string;

    public async Task<IReadOnlyList<(Guid PatientId, DateTimeOffset LastBookedAt)>> LastBookedAsync(Guid tenantId, int limit, CancellationToken ct) =>
        await RawSql.QueryAsync(
            db,
            "select patient_id, last_booked_at from appointment.patient_last_booked_v1(@tenant::uuid, @limit::integer)",
            r => (r.GetGuid(0), r.GetFieldValue<DateTimeOffset>(1)),
            ct,
            ("tenant", tenantId),
            ("limit", limit));

    public Task SetPhonesAsync(Guid patientId, string? phone, bool whatsappSameAsPhone, string? whatsapp, CancellationToken ct) =>
        RawSql.ScalarAsync(
            db,
            "select patient.set_patient_phones(@id::uuid, @phone::text, @same::boolean, @whatsapp::text)",
            ct,
            ("id", patientId),
            ("phone", phone),
            ("same", whatsappSameAsPhone),
            ("whatsapp", whatsapp));
}
