using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Appointments.Endpoints;

internal sealed class AppointmentRow
{
    public required Appointment Appointment { get; init; }
    public PatientRef? Patient { get; init; }

    public AppointmentDto ToDto() => AppointmentDto.From(Appointment, Patient);
}

internal sealed class QueueRow
{
    public required QueueEntry Entry { get; init; }
    public PatientRef? Patient { get; init; }

    public QueueEntryDto ToDto() => QueueEntryDto.From(Entry, Patient);
}

/// <summary>
/// Embeds the patient summary with a LEFT JOIN in the same SQL statement (no per-row lookups).
/// Rows the caller cannot read (RLS on patient.patients) or soft-deleted patients yield <c>patient: null</c>.
/// </summary>
internal static class PatientEmbedding
{
    public static IQueryable<AppointmentRow> WithPatient(this IQueryable<Appointment> query, AppointmentsDbContext db) =>
        from a in query
        join p in db.PatientRefs on a.PatientId equals p.Id into patients
        from p in patients.DefaultIfEmpty()
        select new AppointmentRow { Appointment = a, Patient = p };

    public static IQueryable<QueueRow> WithPatient(this IQueryable<QueueEntry> query, AppointmentsDbContext db) =>
        from q in query
        join p in db.PatientRefs on q.PatientId equals p.Id into patients
        from p in patients.DefaultIfEmpty()
        select new QueueRow { Entry = q, Patient = p };

    public static async Task<AppointmentDto> LoadAppointmentAsync(AppointmentsDbContext db, Guid id, CancellationToken ct) =>
        (await db.Appointments.AsNoTracking().Where(a => a.Id == id).WithPatient(db).SingleAsync(ct)).ToDto();

    public static async Task<QueueEntryDto> LoadQueueEntryAsync(AppointmentsDbContext db, Guid id, CancellationToken ct) =>
        (await db.QueueEntries.AsNoTracking().Where(q => q.Id == id).WithPatient(db).SingleAsync(ct)).ToDto();
}
