using Hms.Modules.Patients.Endpoints;

namespace Hms.UnitTests;

/// <summary>#190: what a NEW registration must provide (edits of existing charts are not affected).</summary>
public class PatientRegistrationRulesTests
{
    private static readonly DateOnly Today = new(2026, 10, 30);

    private static CreatePatientRequest Valid() =>
        new("Asha", "Synthetic", new DateOnly(1990, 1, 1), "female", Guid.NewGuid(), "9876543210", null);

    private static Dictionary<string, string[]> Check(CreatePatientRequest r)
    {
        var errors = CreatePatientValidator.Validate(r, Today);
        CreatePatientValidator.ValidateRegistration(r, errors);
        return errors;
    }

    [Fact]
    public void Complete_registration_is_valid() => Assert.Empty(Check(Valid()));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void Single_name_patient_needs_no_last_name(string? lastName) =>
        Assert.Empty(Check(Valid() with { LastName = lastName }));

    [Fact]
    public void Last_name_is_still_capped_at_100() =>
        Assert.Contains("lastName", Check(Valid() with { LastName = new string('x', 101) }).Keys);

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public void Sex_must_be_chosen(string? sex) =>
        Assert.Contains("sex", Check(Valid() with { Sex = sex }).Keys);

    [Fact]
    public void Unknown_sex_is_an_explicit_choice() => Assert.Empty(Check(Valid() with { Sex = "unknown" }));

    [Fact]
    public void Date_of_birth_or_age_is_required()
    {
        Assert.Contains("dateOfBirth", Check(Valid() with { DateOfBirth = null }).Keys);
        Assert.Empty(Check(Valid() with { DateOfBirth = null, AgeYears = 45 }));
        Assert.Empty(Check(Valid() with { DateOfBirth = null, AgeYears = 0 }));
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(121)]
    public void Age_out_of_range_is_rejected(int age) =>
        Assert.Contains("ageYears", Check(Valid() with { DateOfBirth = null, AgeYears = age }).Keys);

    [Fact]
    public void Estimated_dob_is_the_same_day_age_years_ago()
    {
        Assert.Equal(new DateOnly(1981, 10, 30), CreatePatientValidator.EstimateDateOfBirth(45, Today));
        Assert.Equal(Today, CreatePatientValidator.EstimateDateOfBirth(0, Today));
    }

    [Fact]
    public void Mobile_or_a_no_phone_reason_is_required()
    {
        Assert.Contains("phone", Check(Valid() with { Phone = null }).Keys);
        Assert.Contains("phone", Check(Valid() with { Phone = " ", NoPhoneReason = "  " }).Keys);
        Assert.Contains("noPhoneReason", Check(Valid() with { Phone = null, NoPhoneReason = "no" }).Keys);
        Assert.Contains("noPhoneReason", Check(Valid() with { Phone = null, NoPhoneReason = new string('x', 201) }).Keys);
        Assert.Empty(Check(Valid() with { Phone = null, NoPhoneReason = "Patient does not own a phone" }));
    }

    [Fact]
    public void Edits_do_not_apply_registration_rules() =>
        Assert.Empty(CreatePatientValidator.Validate(Valid() with { Sex = "male", DateOfBirth = null, Phone = null, LastName = "" }, Today));
}
