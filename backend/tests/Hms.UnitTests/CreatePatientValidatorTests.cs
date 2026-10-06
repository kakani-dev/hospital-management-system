using Hms.Modules.Patients.Endpoints;

namespace Hms.UnitTests;

public class CreatePatientValidatorTests
{
    private static readonly DateOnly Today = new(2026, 10, 6);

    private static CreatePatientRequest Valid() =>
        new("ALP-1234", "Asha", "Synthetic", new DateOnly(1990, 1, 1), "female", Guid.NewGuid(), null, "asha@patients.example");

    private static Dictionary<string, string[]> Validate(CreatePatientRequest r) => CreatePatientValidator.Validate(r, Today);

    [Fact]
    public void Valid_request_has_no_errors() => Assert.Empty(Validate(Valid()));

    [Theory]
    [InlineData("")]
    [InlineData("has space")]
    [InlineData("THIS-MRN-IS-WAY-TOO-LONG-1234567890")]
    [InlineData("drop;table")]
    public void Invalid_mrn_is_rejected(string mrn) =>
        Assert.Contains("mrn", Validate(Valid() with { Mrn = mrn }).Keys);

    [Fact]
    public void Multiple_errors_are_reported_together()
    {
        var errors = Validate(Valid() with { FirstName = " ", Sex = "x", RegisteredBranchId = Guid.Empty, DateOfBirth = new DateOnly(1800, 1, 1) });
        Assert.Equal(["dateOfBirth", "firstName", "registeredBranchId", "sex"], errors.Keys.Order(StringComparer.Ordinal));
    }

    [Fact]
    public void Date_of_birth_today_is_valid_and_tomorrow_is_not()
    {
        Assert.Empty(Validate(Valid() with { DateOfBirth = Today }));
        Assert.Contains("dateOfBirth", Validate(Valid() with { DateOfBirth = Today.AddDays(1) }).Keys);
    }

    [Theory]
    [InlineData(32, true)]
    [InlineData(33, false)]
    public void Phone_length_is_capped(int length, bool valid) =>
        Assert.Equal(valid, !Validate(Valid() with { Phone = new string('9', length) }).ContainsKey("phone"));

    [Fact]
    public void Email_length_is_capped()
    {
        var local = new string('a', 64);
        var ok = $"{local}@{new string('b', CreatePatientValidator.EmailMaxLength - local.Length - 1)}";
        Assert.Equal(CreatePatientValidator.EmailMaxLength, ok.Length);
        Assert.False(Validate(Valid() with { Email = ok }).ContainsKey("email"));
        Assert.True(Validate(Valid() with { Email = ok + "c" }).ContainsKey("email"));
        Assert.True(Validate(Valid() with { Email = "no-at-sign" }).ContainsKey("email"));
    }

    [Theory]
    [InlineData("alp-0001", "ALP-0001")]
    [InlineData("  Alp-0001 ", "ALP-0001")]
    [InlineData("ALP-0001", "ALP-0001")]
    public void Mrn_is_normalized_to_upper_case(string input, string expected) =>
        Assert.Equal(expected, CreatePatientValidator.NormalizeMrn(input));

    [Fact]
    public void Today_is_computed_in_the_branch_time_zone()
    {
        // 2026-10-06 20:00 UTC = 2026-10-07 01:30 IST: a baby born "today" in Kolkata is born on the 7th.
        var clock = new FixedClock(new DateTimeOffset(2026, 10, 6, 20, 0, 0, TimeSpan.Zero));
        Assert.Equal(new DateOnly(2026, 10, 7), BranchClock.Today(clock, "Asia/Kolkata"));
        Assert.Equal(new DateOnly(2026, 10, 6), BranchClock.Today(clock, "UTC"));
        Assert.Equal(new DateOnly(2026, 10, 6), BranchClock.Today(clock, "America/New_York"));

        var newborn = Valid() with { DateOfBirth = new DateOnly(2026, 10, 7) };
        Assert.Empty(CreatePatientValidator.Validate(newborn, BranchClock.Today(clock, "Asia/Kolkata")));
        Assert.Contains("dateOfBirth", CreatePatientValidator.Validate(newborn, BranchClock.Today(clock, "UTC")).Keys);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Mars/Olympus")]
    public void Unknown_branch_time_zone_falls_back_to_utc(string? tz)
    {
        var clock = new FixedClock(new DateTimeOffset(2026, 10, 6, 20, 0, 0, TimeSpan.Zero));
        Assert.Equal(new DateOnly(2026, 10, 6), BranchClock.Today(clock, tz));
    }
}

/// <summary>Deterministic clock for tests.</summary>
internal sealed class FixedClock(DateTimeOffset utcNow) : TimeProvider
{
    public override DateTimeOffset GetUtcNow() => utcNow;
}
