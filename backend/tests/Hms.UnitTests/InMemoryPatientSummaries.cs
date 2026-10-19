using System.Collections.Concurrent;
using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Functions;

namespace Hms.UnitTests;

/// <summary>In-process stand-in for patient.patient_summary_v1 (tenant-scoped, includes soft-deleted patients).</summary>
internal sealed class InMemoryPatientSummaries : IPatientSummaries
{
    private readonly ConcurrentDictionary<Guid, PatientRef> _patients = new();

    public int Calls;

    public void Add(PatientRef patient) => _patients[patient.Id] = patient;

    public Task<IReadOnlyDictionary<Guid, PatientRef>> GetAsync(Guid tenantId, IReadOnlyCollection<Guid> patientIds, CancellationToken ct)
    {
        Interlocked.Increment(ref Calls);
        IReadOnlyDictionary<Guid, PatientRef> found = patientIds
            .Select(id => _patients.GetValueOrDefault(id))
            .Where(p => p is not null && p.TenantId == tenantId)
            .ToDictionary(p => p!.Id, p => p!);
        return Task.FromResult(found);
    }
}
