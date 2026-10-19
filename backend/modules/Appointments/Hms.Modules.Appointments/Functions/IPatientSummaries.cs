using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Endpoints;
using Hms.Modules.Appointments.Persistence;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Appointments.Functions;

/// <summary>
/// Patient summaries for embedding in appointment / queue responses. Scheduling never reads
/// <c>patient.patients</c>: it calls the patients service's PUBLISHED, tenant-checked definer function
/// <c>patient.patient_summary_v1(tenant, ids[])</c> (docs/contracts/db.md, DB review B4), once per
/// response (one round trip for a whole page), inside the request's RLS transaction.
/// </summary>
public interface IPatientSummaries
{
    Task<IReadOnlyDictionary<Guid, PatientRef>> GetAsync(Guid tenantId, IReadOnlyCollection<Guid> patientIds, CancellationToken ct);
}

public sealed class PostgresPatientSummaries(AppointmentsDbContext db) : IPatientSummaries
{
    public const string Sql =
        "select id, tenant_id, mrn, first_name, last_name, is_deleted from patient.patient_summary_v1(@t::uuid, @ids::uuid[])";

    public async Task<IReadOnlyDictionary<Guid, PatientRef>> GetAsync(Guid tenantId, IReadOnlyCollection<Guid> patientIds, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(patientIds);
        if (patientIds.Count == 0)
        {
            return new Dictionary<Guid, PatientRef>();
        }

        var rows = await RawSql.QueryAsync(
            db,
            Sql,
            r => new PatientRef
            {
                Id = r.GetGuid(0),
                TenantId = r.GetGuid(1),
                Mrn = r.GetString(2),
                FirstName = r.GetString(3),
                LastName = r.GetString(4),
                IsDeleted = r.GetBoolean(5),
            },
            ct,
            ("t", tenantId), ("ids", patientIds.Distinct().ToArray())).ConfigureAwait(false);
        return rows.ToDictionary(p => p.Id);
    }
}

internal static class PatientSummaryAttachment
{
    /// <summary>
    /// Fills <c>Patient</c> on every row: null when the patient is not visible to the caller OR soft-deleted.
    /// patient_summary_v1 returns deleted patients too (is_deleted = true); the public API contract
    /// (docs/sprint2-api-contract.md, CTO-accepted) keeps <c>patient: null</c> for them.
    /// </summary>
    public static async Task AttachAsync(this IPatientSummaries summaries, IReadOnlyList<AppointmentRow> rows, CancellationToken ct)
    {
        var map = await Load(summaries, rows.Select(r => (r.Appointment.TenantId, r.Appointment.PatientId)), ct).ConfigureAwait(false);
        foreach (var row in rows)
        {
            row.Patient = Visible(map.GetValueOrDefault(row.Appointment.PatientId));
        }
    }

    public static async Task AttachAsync(this IPatientSummaries summaries, IReadOnlyList<QueueRow> rows, CancellationToken ct)
    {
        var map = await Load(summaries, rows.Select(r => (r.Entry.TenantId, r.Entry.PatientId)), ct).ConfigureAwait(false);
        foreach (var row in rows)
        {
            row.Patient = Visible(map.GetValueOrDefault(row.Entry.PatientId));
        }
    }

    private static PatientRef? Visible(PatientRef? patient) => patient is { IsDeleted: false } ? patient : null;

    private static async Task<Dictionary<Guid, PatientRef>> Load(
        IPatientSummaries summaries, IEnumerable<(Guid Tenant, Guid Patient)> keys, CancellationToken ct)
    {
        var result = new Dictionary<Guid, PatientRef>();
        foreach (var group in keys.GroupBy(k => k.Tenant))
        {
            var ids = group.Select(k => k.Patient).Distinct().ToList();
            for (var i = 0; i < ids.Count; i += 500)
            {
                var found = await summaries.GetAsync(group.Key, ids.Skip(i).Take(500).ToList(), ct).ConfigureAwait(false);
                foreach (var (id, patient) in found)
                {
                    result[id] = patient;
                }
            }
        }

        return result;
    }
}
