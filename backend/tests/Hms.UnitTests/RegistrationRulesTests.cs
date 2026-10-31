using Hms.Modules.Patients.Endpoints;

namespace Hms.UnitTests;

/// <summary>#58: registration rules with relative dates and tenant settings (no fixed values).</summary>
public sealed class RegistrationRulesTests
{
    private static readonly DateOnly Today = DateOnly.FromDateTime(DateTime.UtcNow);

    private static Dictionary<string, string[]> Run(RegistrationDetails d, RegistrationSettings s, int? age, string? own = null)
    {
        var errors = new Dictionary<string, string[]>();
        RegistrationRules.Normalize(d, s, age, own, "+91", enforceRequired: true, errors);
        return errors;
    }

    [Fact]
    public void Age_turns_on_the_birthday_not_before()
    {
        Assert.Equal(17, RegistrationRules.AgeYears(Today.AddYears(-18).AddDays(1), Today));
        Assert.Equal(18, RegistrationRules.AgeYears(Today.AddYears(-18), Today));
        Assert.Null(RegistrationRules.AgeYears(null, Today));
    }

    [Theory]
    [InlineData(18, 17, true)]
    [InlineData(18, 18, false)]
    [InlineData(0, 2, false)]
    [InlineData(21, 20, true)]
    public void Guardian_requirement_follows_the_tenant_age(int limit, int age, bool required)
    {
        var errors = Run(new RegistrationDetails(), new RegistrationSettings(GuardianRequiredBelowAgeYears: limit), age);
        Assert.Equal(required, errors.ContainsKey("details.guardianName"));
    }

    [Fact]
    public void Unknown_age_does_not_block_an_unidentified_emergency_patient()
    {
        Assert.Empty(Run(new RegistrationDetails(), RegistrationSettings.Defaults, null));
    }

    [Fact]
    public void Emergency_contact_needs_name_and_phone_and_not_the_patients_own_number()
    {
        Assert.Contains("details.emergencyContactName", Run(new RegistrationDetails(EmergencyContactName: "Zz-QA Kin"), RegistrationSettings.Defaults, 40).Keys);
        Assert.Contains("details.emergencyContactPhone",
            Run(new RegistrationDetails(EmergencyContactName: "Zz-QA Kin", EmergencyContactPhone: "9845000001"), RegistrationSettings.Defaults, 40, "+919845000001").Keys);
        Assert.Contains("details.emergencyContactPhone",
            Run(new RegistrationDetails(EmergencyContactName: "Zz-QA Kin", EmergencyContactPhone: "12"), RegistrationSettings.Defaults, 40).Keys);
        Assert.Contains("details.emergencyContactName", Run(new RegistrationDetails(), new RegistrationSettings(EmergencyContactRequired: true), 40).Keys);
    }

    [Theory]
    [InlineData("560001", true)]
    [InlineData("560 001", true)]
    [InlineData("060001", false)]
    [InlineData("56001", false)]
    public void Pin_code_is_six_digits_not_starting_with_zero(string pin, bool ok)
    {
        Assert.Equal(ok, !Run(new RegistrationDetails(PinCode: pin), RegistrationSettings.Defaults, 40).ContainsKey("details.pinCode"));
    }

    [Theory]
    [InlineData("o+", "O+")]
    [InlineData("AB -ve", "AB-")]
    [InlineData("B positive", "B+")]
    public void Blood_group_spellings_used_at_the_desk_are_normalized(string typed, string stored)
    {
        var errors = new Dictionary<string, string[]>();
        var d = RegistrationRules.Normalize(new RegistrationDetails(BloodGroup: typed), RegistrationSettings.Defaults, 40, null, "+91", true, errors);
        Assert.Empty(errors);
        Assert.Equal(stored, d.BloodGroup);
    }

    [Fact]
    public void Walk_in_needs_no_referrer_but_a_doctor_referral_does_unless_the_tenant_turns_it_off()
    {
        Assert.Empty(Run(new RegistrationDetails(ReferralSource: "walk_in"), RegistrationSettings.Defaults, 40));
        Assert.Contains("details.referredBy", Run(new RegistrationDetails(ReferralSource: "doctor"), RegistrationSettings.Defaults, 40).Keys);
        Assert.Empty(Run(new RegistrationDetails(ReferralSource: "doctor"), new RegistrationSettings(ReferredByRequiredForReferrals: false), 40));
        Assert.Contains("details.referralSource", Run(new RegistrationDetails(ReferralSource: "friend"), RegistrationSettings.Defaults, 40).Keys);
    }

    [Fact]
    public void Address_requirement_needs_address_and_pin()
    {
        var s = new RegistrationSettings(AddressRequired: true);
        Assert.Contains("details.addressLine", Run(new RegistrationDetails(AddressLine: "Zz-QA Street"), s, 40).Keys);
        Assert.Empty(Run(new RegistrationDetails(AddressLine: "Zz-QA Street", PinCode: "560001"), s, 40));
    }
}
