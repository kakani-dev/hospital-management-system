using Hms.Modules.Billing;

namespace Hms.UnitTests;

public class BillingMathTests
{
    [Theory]
    [InlineData(1, 50000, 50000)]
    [InlineData(1.5, 10000, 15000)]
    [InlineData(0.5, 1, 1)]
    public void Line_net_rounds_half_away_from_zero(decimal quantity, long unit, long expected) =>
        Assert.Equal(expected, BillingMath.LineNet(quantity, unit));

    [Fact]
    public void Exempt_line_has_no_tax_and_a_taxable_line_rounds_the_rate()
    {
        Assert.Equal(0, BillingMath.LineTax(1, 50000, 0));
        Assert.Equal(900, BillingMath.LineTax(1, 50000, 180));
    }

    [Fact]
    public void Round_off_lands_on_a_rupee()
    {
        Assert.Equal(-10, BillingMath.RoundOff(5010));
        Assert.Equal(5000, BillingMath.Total(5010));
        Assert.Equal(0, BillingMath.RoundOff(50000));
        Assert.Equal(50, BillingMath.RoundOff(50));
    }

    [Fact]
    public void Cash_ceiling_refuses_the_rupee_that_reaches_two_lakh()
    {
        Assert.True(BillingMath.CashAllowed(0, 19_999_999));
        Assert.False(BillingMath.CashAllowed(0, BillingMath.CashCeilingPaise));
        Assert.False(BillingMath.CashAllowed(19_999_999, 1));
        Assert.True(BillingMath.CashAllowed(BillingMath.CashCeilingPaise, 0));
    }

    [Fact]
    public void Limit_passes_on_either_cap_and_null_caps_are_unlimited()
    {
        Assert.True(BillingMath.WithinLimit(20_000, 500, 20_000, 9_000));
        Assert.True(BillingMath.WithinLimit(20_000, 500, 50_000, 500));
        Assert.False(BillingMath.WithinLimit(20_000, 500, 20_001, 501));
        Assert.True(BillingMath.WithinLimit(null, null, 9_000_000, 10_000));
    }

    [Fact]
    public void Document_numbers_are_sixteen_characters()
    {
        var number = BillingMath.FormatDocNo("OP", 'B', "2627", 1);
        Assert.Equal(16, number.Length);
        Assert.Equal("OPB2627000000001", number);
        Assert.Throws<ArgumentOutOfRangeException>(() => BillingMath.FormatDocNo("ABCDEFGHIJKL", 'B', "2627", 1));
    }
}
