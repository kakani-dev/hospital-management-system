namespace Hms.Modules.Billing;

/// <summary>
/// Paise arithmetic mirrored by the SQL functions (half away from zero, rupee round-off,
/// s.269ST cash ceiling, discount OR-limit, 16-character document numbers).
/// The database is the authority on a request; this is the same rule for tests and the UPI amount.
/// </summary>
public static class BillingMath
{
    public const long CashCeilingPaise = 20_000_000;

    public static long LineNet(decimal quantity, long unitPricePaise) =>
        Round(quantity * unitPricePaise);

    public static long LineTax(decimal quantity, long unitPricePaise, int taxRateBp) =>
        Round(LineNet(quantity, unitPricePaise) * taxRateBp / 10000m);

    public static long RoundOff(long exactPaise) => Total(exactPaise) - exactPaise;

    public static long Total(long exactPaise) => Round(exactPaise / 100m) * 100;

    public static bool CashAllowed(long alreadyPaise, long addingPaise) =>
        addingPaise <= 0 || alreadyPaise + addingPaise < CashCeilingPaise;

    /// <summary>True when the amount is inside the rupee cap or the percent is inside the percent cap. Both null means unlimited.</summary>
    public static bool WithinLimit(long? maxAmountPaise, int? maxPercentBp, long amountPaise, int? percentBp) =>
        (maxAmountPaise is null && maxPercentBp is null)
        || (maxAmountPaise is not null && amountPaise <= maxAmountPaise)
        || (maxPercentBp is not null && percentBp is not null && percentBp <= maxPercentBp);

    public static string FormatDocNo(string prefix, char letter, string fiscalYear, long serial)
    {
        var body = prefix + letter + fiscalYear;
        var width = 16 - body.Length;
        if (width < 1 || serial < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(serial), "Document number does not fit in 16 characters.");
        }

        var text = serial.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (text.Length > width)
        {
            throw new ArgumentOutOfRangeException(nameof(serial), "Document number does not fit in 16 characters.");
        }

        return body + text.PadLeft(width, '0');
    }

    private static long Round(decimal value) =>
        (long)decimal.Round(value, 0, MidpointRounding.AwayFromZero);
}
