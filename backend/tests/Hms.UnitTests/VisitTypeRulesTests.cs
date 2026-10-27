using Hms.Modules.Appointments.Endpoints;

namespace Hms.UnitTests;

public sealed class VisitTypeRulesTests
{
    private static VisitTypeRules.Prior Prior(DateOnly day, short? days, long? fee) =>
        new(Guid.NewGuid(), day, days, fee);

    private static VisitTypeRules.Effective FollowUp(long fee = 20_000) =>
        new(Guid.NewGuid(), VisitTypeRules.FollowUpCode, "Follow-up", fee, 15, null, null);

    [Fact]
    public void Last_day_of_the_window_is_inside_and_the_next_day_is_outside()
    {
        var prior = Prior(new DateOnly(2026, 10, 1), 7, 0);
        Assert.True(VisitTypeRules.WithinWindow(prior, new DateOnly(2026, 10, 8)));
        Assert.False(VisitTypeRules.WithinWindow(prior, new DateOnly(2026, 10, 9)));
        Assert.False(VisitTypeRules.WithinWindow(prior with { GrantedDays = 0 }, new DateOnly(2026, 10, 1)));
        Assert.False(VisitTypeRules.WithinWindow(prior with { GrantedDays = null }, new DateOnly(2026, 10, 2)));
    }

    [Fact]
    public void Snapshotted_free_follow_up_fee_stays_zero_when_the_type_fee_changes()
    {
        var prior = Prior(new DateOnly(2026, 10, 1), 7, 0);
        Assert.Equal(0, VisitTypeRules.FeeFor(FollowUp(99_000), prior, new DateOnly(2026, 10, 8)));
        Assert.Equal(99_000, VisitTypeRules.FeeFor(FollowUp(99_000), prior, new DateOnly(2026, 10, 9)));
    }

    [Fact]
    public void Free_follow_up_count_is_enforced_and_noted_for_the_bill()
    {
        var prior = Prior(new DateOnly(2026, 10, 1), 7, 0) with { GrantedLimit = 1 };
        var first = VisitTypeRules.QuoteFor(FollowUp(), prior, new DateOnly(2026, 10, 4));
        Assert.Equal(0, first.FeePaise);
        Assert.Equal(prior.AppointmentId, first.EntitlementId);
        Assert.Equal("Free follow-up (within 7 days of 1 Oct 2026)", first.Note);

        var second = VisitTypeRules.QuoteFor(FollowUp(), prior with { UsedCount = 1 }, new DateOnly(2026, 10, 5));
        Assert.Equal(new VisitTypeRules.Quote(20_000, null, null), second);
        Assert.Equal(0, VisitTypeRules.QuoteFor(FollowUp(), prior with { GrantedLimit = null, UsedCount = 9 }, new DateOnly(2026, 10, 5)).FeePaise);
        Assert.Equal(20_000, VisitTypeRules.QuoteFor(FollowUp(), prior with { GrantedLimit = 0 }, new DateOnly(2026, 10, 2)).FeePaise);
    }

    [Fact]
    public void Reduced_follow_up_fee_is_noted_and_the_window_end_uses_the_normal_fee()
    {
        var review = Prior(new DateOnly(2026, 10, 1), 14, 10_000);
        var inside = VisitTypeRules.QuoteFor(FollowUp(), review, new DateOnly(2026, 10, 15));
        Assert.Equal(10_000, inside.FeePaise);
        Assert.Equal("Reduced follow-up fee (within 14 days of 1 Oct 2026)", inside.Note);
        Assert.Equal(new VisitTypeRules.Quote(20_000, null, null), VisitTypeRules.QuoteFor(FollowUp(), review, new DateOnly(2026, 10, 16)));
        // A window with no special fee (null) records no entitlement, so it does not use up the count.
        Assert.Equal(new VisitTypeRules.Quote(20_000, null, null), VisitTypeRules.QuoteFor(FollowUp(), review with { GrantedFeePaise = null }, new DateOnly(2026, 10, 2)));
    }

    [Fact]
    public void Registration_collapses_case_and_whitespace_and_rejects_empty_or_short_values()
    {
        Assert.True(NmcRegistration.TryNormalize("  kmc/2018/12345 ", out var normalized));
        Assert.Equal("KMC/2018/12345", normalized);
        Assert.True(NmcRegistration.TryNormalize("   ", out var empty));
        Assert.Null(empty);
        Assert.False(NmcRegistration.TryNormalize("AB", out _));
        Assert.False(NmcRegistration.TryNormalize("NO-DIGITS-HERE", out _));
        Assert.True(NmcRegistration.TryNormalizePhone("9800000201", out var phone));
        Assert.Equal("+919800000201", phone);
        Assert.True(NmcRegistration.TryNormalizePhone("  ", out var noPhone));
        Assert.Null(noPhone);
        Assert.False(NmcRegistration.TryNormalizeEmail("not an email", out _));
    }
}
