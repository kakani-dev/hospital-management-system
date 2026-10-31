using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Persistence;
using Hms.Modules.Appointments.Reminders;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Appointments.Endpoints;

public sealed record ReminderSettingsDto(
    bool Enabled, int LeadHours, int SameDayHours, int MinNoticeMinutes, bool EmailEnabled, bool WhatsappEnabled,
    string QuietStart, string QuietEnd, string DeliveryMode, bool EmailAvailable, bool WhatsappAvailable);

public sealed record UpdateReminderSettingsRequest(
    bool? Enabled, int? LeadHours, int? SameDayHours, int? MinNoticeMinutes, bool? EmailEnabled, bool? WhatsappEnabled,
    string? QuietStart, string? QuietEnd);

public sealed record ReminderLogDto(Guid Id, string Kind, string Channel, string Status, string? Detail, string? RecipientMasked,
    int Attempts, DateTimeOffset ScheduledStart, DateTimeOffset? SentAt, DateTimeOffset CreatedOn);

public sealed record AppointmentRemindersDto(Guid AppointmentId, Guid PatientId, bool OptedOut, string? OptOutReason, List<ReminderLogDto> Reminders);

public sealed record ReminderOptOutRequest(string? Reason);

/// <summary>#59: tenant reminder settings, per-appointment reminder history, and patient opt-outs.</summary>
public static class ReminderEndpoints
{
    public static RouteGroupBuilder MapReminderEndpoints(this RouteGroupBuilder api)
    {
        var g = api.MapGroup("/reminders").WithTags("Reminders").RequireTenant().WithDbTransaction<AppointmentsDbContext>();
        g.MapGet("/settings", GetSettingsAsync).WithName("GetReminderSettings");
        g.MapPut("/settings", PutSettingsAsync).WithName("PutReminderSettings");
        g.MapGet("/appointments/{id:guid}", ForAppointmentAsync).WithName("GetAppointmentReminders");
        g.MapPut("/opt-outs/{patientId:guid}", OptOutAsync).WithName("PutReminderOptOut");
        g.MapDelete("/opt-outs/{patientId:guid}", OptInAsync).WithName("DeleteReminderOptOut");
        return api;
    }

    internal static ReminderSettingsDto ToDto(ReminderSettings? s, ReminderOptions options, ReminderSmtpOptions smtp)
    {
        s ??= new ReminderSettings();
        return new ReminderSettingsDto(
            s.Enabled, s.LeadHours, s.SameDayHours, s.MinNoticeMinutes, s.EmailEnabled, s.WhatsappEnabled,
            s.QuietStart.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture), s.QuietEnd.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture),
            options.DeliveryMode.ToString(), smtp.IsConfigured, options.WhatsApp.IsConfigured);
    }

    private static async Task<Results<Ok<ReminderSettingsDto>, ProblemHttpResult>> GetSettingsAsync(
        AppointmentsDbContext db, ITenantContext tenant, IOptions<ReminderOptions> options, IOptions<ReminderSmtpOptions> smtp, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.SettingsView) && !tenant.Can(HmsPermissions.AppointmentsView))
        {
            return HmsProblems.Forbidden("You cannot view reminder settings.");
        }

        var row = await db.ReminderSettings.AsNoTracking().SingleOrDefaultAsync(ct);
        return TypedResults.Ok(ToDto(row, options.Value, smtp.Value));
    }

    internal static Dictionary<string, string[]> Validate(UpdateReminderSettingsRequest r, out TimeOnly quietStart, out TimeOnly quietEnd)
    {
        var errors = new Dictionary<string, string[]>();
        quietStart = default;
        quietEnd = default;
        if (r.Enabled is null || r.EmailEnabled is null || r.WhatsappEnabled is null)
        {
            errors["enabled"] = ["Enabled, email and WhatsApp flags are required."];
        }

        if (r.LeadHours is null or < 1 or > 72)
        {
            errors["leadHours"] = ["Reminder lead time must be 1-72 hours."];
        }

        if (r.SameDayHours is null or < 0 or > 12 || (r.LeadHours is { } lead && r.SameDayHours >= lead))
        {
            errors["sameDayHours"] = ["Same-day nudge must be 0-12 hours and less than the lead time."];
        }

        if (r.MinNoticeMinutes is null or < 0 or > 1440)
        {
            errors["minNoticeMinutes"] = ["Minimum notice must be 0-1440 minutes."];
        }

        if (!TimeOnly.TryParseExact(r.QuietStart, "HH:mm", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out quietStart)
            || !TimeOnly.TryParseExact(r.QuietEnd, "HH:mm", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out quietEnd))
        {
            errors["quietStart"] = ["Quiet hours must be HH:mm."];
        }

        return errors;
    }

    private static async Task<Results<Ok<ReminderSettingsDto>, ValidationProblem, ProblemHttpResult>> PutSettingsAsync(
        UpdateReminderSettingsRequest request, AppointmentsDbContext db, ITenantContext tenant,
        IOptions<ReminderOptions> options, IOptions<ReminderSmtpOptions> smtp, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.SettingsManage))
        {
            return HmsProblems.Forbidden("Only tenant admins can change reminder settings.");
        }

        var errors = Validate(request, out var quietStart, out var quietEnd);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        var row = await db.ReminderSettings.SingleOrDefaultAsync(ct);
        if (row is null)
        {
            row = new ReminderSettings();
            db.ReminderSettings.Add(row);
        }

        row.Enabled = request.Enabled!.Value;
        row.LeadHours = (short)request.LeadHours!.Value;
        row.SameDayHours = (short)request.SameDayHours!.Value;
        row.MinNoticeMinutes = (short)request.MinNoticeMinutes!.Value;
        row.EmailEnabled = request.EmailEnabled!.Value;
        row.WhatsappEnabled = request.WhatsappEnabled!.Value;
        row.QuietStart = quietStart;
        row.QuietEnd = quietEnd;
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Ok(ToDto(row, options.Value, smtp.Value));
    }

    private static async Task<Results<Ok<AppointmentRemindersDto>, ProblemHttpResult>> ForAppointmentAsync(
        Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.AppointmentsView))
        {
            return HmsProblems.Forbidden("You cannot view appointments.");
        }

        var appt = await db.Appointments.AsNoTracking().Where(a => a.Id == id).Select(a => new { a.Id, a.PatientId }).SingleOrDefaultAsync(ct);
        if (appt is null)
        {
            return HmsProblems.NotFound("Appointment not found.");
        }

        var optOut = await db.ReminderOptOuts.AsNoTracking().SingleOrDefaultAsync(o => o.PatientId == appt.PatientId, ct);
        var logs = await db.AppointmentReminders.AsNoTracking().Where(r => r.AppointmentId == id)
            .OrderByDescending(r => r.CreatedOn).Take(20)
            .Select(r => new ReminderLogDto(r.Id, r.Kind, r.Channel, r.Status, r.Detail, r.RecipientMasked, r.Attempts, r.ScheduledStart, r.SentAt, r.CreatedOn))
            .ToListAsync(ct);
        return TypedResults.Ok(new AppointmentRemindersDto(appt.Id, appt.PatientId, optOut is not null, optOut?.Reason, logs));
    }

    private static async Task<Results<NoContent, ValidationProblem, ProblemHttpResult>> OptOutAsync(
        Guid patientId, ReminderOptOutRequest? request, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.AppointmentsBook))
        {
            return HmsProblems.Forbidden("You cannot change reminder preferences.");
        }

        var reason = request?.Reason?.Trim();
        if (reason is { Length: > 200 })
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["reason"] = ["Reason must be 200 characters or fewer."] });
        }

        if (!await db.Appointments.AnyAsync(a => a.PatientId == patientId, ct))
        {
            return HmsProblems.NotFound("No appointments for this patient.");
        }

        var row = await db.ReminderOptOuts.SingleOrDefaultAsync(o => o.PatientId == patientId, ct);
        if (row is null)
        {
            db.ReminderOptOuts.Add(new ReminderOptOut { PatientId = patientId, Reason = string.IsNullOrEmpty(reason) ? null : reason });
        }
        else
        {
            row.Reason = string.IsNullOrEmpty(reason) ? null : reason;
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.NoContent();
    }

    private static async Task<Results<NoContent, ProblemHttpResult>> OptInAsync(
        Guid patientId, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.AppointmentsBook))
        {
            return HmsProblems.Forbidden("You cannot change reminder preferences.");
        }

        await db.ReminderOptOuts.Where(o => o.PatientId == patientId).ExecuteDeleteAsync(ct);
        return TypedResults.NoContent();
    }
}
