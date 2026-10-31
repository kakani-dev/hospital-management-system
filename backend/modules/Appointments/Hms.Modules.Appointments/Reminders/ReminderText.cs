using System.Globalization;

namespace Hms.Modules.Appointments.Reminders;

/// <summary>One leased reminder returned by <c>appointment.claim_due_reminders</c>.</summary>
public sealed record DueReminder(
    Guid ReminderId, Guid TenantId, Guid AppointmentId, string Kind, string Channel, string? Recipient,
    string? PatientFirstName, string? PractitionerLabel, string? BranchName, DateTimeOffset StartsAt, string? TimeZone, int Attempts);

/// <summary>Pure helpers: message text, recipient masking and the test-recipient guard.</summary>
public static class ReminderText
{
    private static readonly CultureInfo Fmt = CultureInfo.InvariantCulture;

    public static DateTimeOffset Local(DateTimeOffset at, string? timeZone)
    {
        try
        {
            return TimeZoneInfo.ConvertTime(at, TimeZoneInfo.FindSystemTimeZoneById(string.IsNullOrWhiteSpace(timeZone) ? "Asia/Kolkata" : timeZone));
        }
        catch (TimeZoneNotFoundException)
        {
            return at;
        }
    }

    public static string Body(DueReminder r)
    {
        var local = Local(r.StartsAt, r.TimeZone);
        var name = string.IsNullOrWhiteSpace(r.PatientFirstName) ? "there" : r.PatientFirstName.Trim();
        var who = string.IsNullOrWhiteSpace(r.PractitionerLabel) ? "your doctor" : r.PractitionerLabel.Trim();
        var where = string.IsNullOrWhiteSpace(r.BranchName) ? string.Empty : $" at {r.BranchName.Trim()}";
        var time = local.ToString("h:mm tt", Fmt).ToUpperInvariant();
        return r.Kind == "same_day"
            ? $"Hello {name}, your appointment with {who}{where} is today at {time}. Please carry your previous prescriptions and reports."
            : $"Hello {name}, this is a reminder of your appointment with {who}{where} on {local.ToString("ddd d MMM", Fmt)} at {time}. "
              + "If you cannot come, please call the hospital to reschedule.";
    }

    public static string Mask(string? recipient)
    {
        if (string.IsNullOrWhiteSpace(recipient))
        {
            return string.Empty;
        }

        var value = recipient.Trim();
        var at = value.IndexOf('@', StringComparison.Ordinal);
        if (at > 0)
        {
            return string.Concat(value.AsSpan(0, Math.Min(2, at)), "***", value.AsSpan(at));
        }

        return value.Length <= 4 ? "****" : string.Concat(value.AsSpan(0, Math.Min(3, value.Length - 4)), new string('*', Math.Max(0, value.Length - 7)), value.AsSpan(value.Length - 4));
    }

    public static string Normalize(string? recipient)
    {
        if (string.IsNullOrWhiteSpace(recipient))
        {
            return string.Empty;
        }

        var value = recipient.Trim();
        return value.Contains('@', StringComparison.Ordinal)
            ? value.ToLowerInvariant()
            : new string(value.Where(char.IsDigit).ToArray());
    }

    /// <summary>True only when the recipient is on the configured allowlist (never true for an empty list).</summary>
    public static bool IsTestRecipient(string? recipient, IEnumerable<string> allowlist)
    {
        var normalized = Normalize(recipient);
        return normalized.Length > 0 && allowlist.Any(a => Normalize(a) == normalized);
    }
}
