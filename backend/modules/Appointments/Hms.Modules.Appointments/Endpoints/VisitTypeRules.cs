using System.Globalization;
using Hms.Modules.Appointments.Domain;

namespace Hms.Modules.Appointments.Endpoints;

/// <summary>
/// Visit-type fee and duration. A follow-up booked with the same doctor inside the prior visit's
/// window uses that visit's follow-up fee (0 is free). Anything else uses the selected type's
/// effective fee at the booking branch.
/// </summary>
public static class VisitTypeRules
{
    public const string FollowUpCode = "follow_up";
    public const string NewConsultCode = "new_consult";
    public const long MaxFeePaise = 10_000_000_000;
    public const short DefaultFreeFollowUps = 1;
    public const short MaxFreeFollowUps = 50;

    public readonly record struct Snapshot(
        Guid Id, string Code, string Name, long DefaultFeePaise, short DurationMinutes, short? FollowUpValidDays, long? FollowUpFeePaise,
        short? FollowUpFreeLimit = null);

    public readonly record struct OverrideSnapshot(long? FeePaise, short? DurationMinutes, short? FollowUpValidDays, long? FollowUpFeePaise);

    public readonly record struct Effective(
        Guid Id, string Code, string Name, long FeePaise, short DurationMinutes, short? FollowUpValidDays, long? FollowUpFeePaise,
        short? FollowUpFreeLimit = null);

    /// <summary>Entitlement copied onto the earlier visit at booking. Later edits of the visit type do not change it.
    /// GrantedLimit null is no limit; UsedCount is live bookings that already used this visit's free or reduced fee.</summary>
    public readonly record struct Prior(
        Guid AppointmentId, DateOnly LocalDate, short? GrantedDays, long? GrantedFeePaise, short? GrantedLimit = null, int UsedCount = 0);

    /// <summary>Fee for one booking. EntitlementId is the earlier visit whose free or reduced follow-up it used; Note goes on the bill.</summary>
    public readonly record struct Quote(long FeePaise, Guid? EntitlementId, string? Note);

    public static Snapshot From(VisitType type) =>
        new(type.Id, type.Code, type.Name, type.DefaultFeePaise, type.DurationMinutes, type.FollowUpValidDays, type.FollowUpFeePaise, type.FollowUpFreeLimit);

    public static OverrideSnapshot From(VisitTypeOverride row) =>
        new(row.FeePaise, row.DurationMinutes, row.FollowUpValidDays, row.FollowUpFeePaise);

    public static Effective Apply(Snapshot type, OverrideSnapshot? branch) => new(
        type.Id,
        type.Code,
        type.Name,
        branch?.FeePaise ?? type.DefaultFeePaise,
        branch?.DurationMinutes ?? type.DurationMinutes,
        branch is { FollowUpValidDays: { } days } ? days : type.FollowUpValidDays,
        branch is { FollowUpFeePaise: { } fee } ? fee : type.FollowUpFeePaise,
        type.FollowUpFreeLimit);

    public static bool WithinWindow(Prior prior, DateOnly bookingDate)
    {
        if (prior.GrantedDays is not > 0)
        {
            return false;
        }

        var elapsed = bookingDate.DayNumber - prior.LocalDate.DayNumber;
        return elapsed >= 0 && elapsed <= prior.GrantedDays.Value;
    }

    /// <summary>Inside the window and the free or reduced follow-up count is not used up.</summary>
    public static bool Entitled(Prior prior, DateOnly bookingDate) =>
        WithinWindow(prior, bookingDate)
        && prior.GrantedLimit is not <= 0
        && (prior.GrantedLimit is null || prior.UsedCount < prior.GrantedLimit.Value);

    public static long FeeFor(Effective selected, Prior? prior, DateOnly bookingDate) =>
        QuoteFor(selected, prior, bookingDate).FeePaise;

    /// <summary>
    /// A Follow-up inside the prior visit's window, with a free or reduced fee left, uses that fee and records the
    /// earlier visit so the count can be enforced. After the window (or once used up) the Follow-up type fee applies.
    /// Only the consultation line changes; labs and medicines are billed as usual.
    /// </summary>
    public static Quote QuoteFor(Effective selected, Prior? prior, DateOnly bookingDate)
    {
        if (selected.Code == FollowUpCode && prior is { GrantedFeePaise: { } granted } earlier && Entitled(earlier, bookingDate))
        {
            var day = earlier.LocalDate.ToString("d MMM yyyy", CultureInfo.InvariantCulture);
            var note = granted == 0
                ? $"Free follow-up (within {earlier.GrantedDays} days of {day})"
                : $"Reduced follow-up fee (within {earlier.GrantedDays} days of {day})";
            return new Quote(granted, earlier.AppointmentId, note);
        }

        return new Quote(selected.FeePaise, null, null);
    }

    /// <summary>Follow-up when the same doctor was seen inside the prior visit's window; otherwise New consult.</summary>
    public static (Effective Type, bool Suggested, Guid? PriorAppointmentId, string? Reason) Suggest(
        IReadOnlyList<Effective> types, Prior? prior, DateOnly bookingDate)
    {
        var followUp = Find(types, FollowUpCode);
        var fresh = Find(types, NewConsultCode);
        if (fresh.Id == Guid.Empty)
        {
            fresh = Find(types, null);
        }

        if (followUp.Id != Guid.Empty && prior is { } earlier && WithinWindow(earlier, bookingDate))
        {
            var quote = QuoteFor(followUp, earlier, bookingDate);
            var suggested = followUp with { FeePaise = quote.FeePaise };
            var reason = quote.Note is { } note
                ? $"Saw this doctor within {earlier.GrantedDays} days, so Follow-up is suggested. {note}."
                : earlier.GrantedFeePaise is not null
                    ? $"Saw this doctor within {earlier.GrantedDays} days, but the free follow-up was already used, so the Follow-up fee applies."
                    : $"Saw this doctor within {earlier.GrantedDays} days, so Follow-up is suggested.";
            return (suggested, true, earlier.AppointmentId, reason);
        }

        return (fresh, false, null, null);
    }

    private static Effective Find(IReadOnlyList<Effective> types, string? code)
    {
        foreach (var type in types)
        {
            if (code is null || type.Code == code)
            {
                return type;
            }
        }

        return default;
    }

    public static IReadOnlyList<VisitType> Defaults() =>
    [
        Row(NewConsultCode, "New consult", 50_000, 30, 7, 0, 1),
        Row(FollowUpCode, "Follow-up", 20_000, 15, null, null, 2),
        Row("review", "Review", 30_000, 20, 14, 10_000, 3),
        Row("emergency", "Emergency", 80_000, 20, null, null, 4),
        Row("teleconsult", "Teleconsult", 40_000, 15, 3, 0, 5),
    ];

    public static bool ValidFee(long? paise) => paise is null or >= 0 and <= MaxFeePaise;

    public static bool ValidDuration(int? minutes) => minutes is null || minutes is >= 5 and <= 240;

    public static bool ValidFreeLimit(int? count) => count is null || count is >= 0 and <= MaxFreeFollowUps;

    public static bool ValidWindow(int? days) => days is null || days is >= 0 and <= 366;

    public static bool ValidCode(string? code) =>
        code is not null && CodePattern().IsMatch(code);

    private static VisitType Row(string code, string name, long fee, short duration, short? window, long? followFee, short sort) =>
        new()
        {
            Code = code,
            Name = name,
            DefaultFeePaise = fee,
            DurationMinutes = duration,
            FollowUpValidDays = window,
            FollowUpFeePaise = followFee,
            SortOrder = sort,
            IsActive = true,
        };

    private static System.Text.RegularExpressions.Regex CodePattern() => CodeRegex.Pattern;

    private static partial class CodeRegex
    {
        public static readonly System.Text.RegularExpressions.Regex Pattern =
            new("^[a-z][a-z0-9_]{1,31}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
    }
}
