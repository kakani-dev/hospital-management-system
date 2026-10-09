using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Functions;
using Hms.Modules.Appointments.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Appointments.Endpoints;

internal sealed class AppointmentRow
{
    public required Appointment Appointment { get; init; }
    public PatientRef? Patient { get; set; }

    public AppointmentDto ToDto() => AppointmentDto.From(Appointment, Patient);
}

internal sealed class QueueRow
{
    public required QueueEntry Entry { get; init; }
    public PatientRef? Patient { get; set; }

    public QueueEntryDto ToDto() => QueueEntryDto.From(Entry, Patient);
}

/// <summary>
/// Embeds the patient summary in appointment / queue responses. Microservices rule (DB review B4): the
/// scheduling query never joins <c>patient.*</c>; rows are read first, then the summaries for the whole
/// page come from <c>patient.patient_summary_v1</c> in ONE call (<see cref="IPatientSummaries"/>).
/// Soft-deleted patients are included with <c>isDeleted: true</c> (history keeps a name); a patient
/// the caller may not read yields <c>patient: null</c>.
/// </summary>
internal static class PatientEmbedding
{
    public static IQueryable<AppointmentRow> WithPatient(this IQueryable<Appointment> query, AppointmentsDbContext db) =>
        query.Select(a => new AppointmentRow { Appointment = a });

    public static IQueryable<QueueRow> WithPatient(this IQueryable<QueueEntry> query, AppointmentsDbContext db) =>
        query.Select(q => new QueueRow { Entry = q });

    public static async Task<AppointmentDto> LoadAppointmentAsync(AppointmentsDbContext db, IPatientSummaries patients, Guid id, CancellationToken ct)
    {
        var row = await db.Appointments.AsNoTracking().Where(a => a.Id == id).WithPatient(db).SingleAsync(ct);
        await patients.AttachAsync([row], ct);
        return row.ToDto();
    }

    public static async Task<QueueEntryDto> LoadQueueEntryAsync(AppointmentsDbContext db, IPatientSummaries patients, Guid id, CancellationToken ct)
    {
        var row = await db.QueueEntries.AsNoTracking().Where(q => q.Id == id).WithPatient(db).SingleAsync(ct);
        await patients.AttachAsync([row], ct);
        return row.ToDto();
    }
}
