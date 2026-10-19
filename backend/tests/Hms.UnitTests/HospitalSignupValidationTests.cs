using Hms.Modules.Identity.Endpoints;

namespace Hms.UnitTests;

/// <summary>Level 1 public "Register your hospital" form: API validation mirrors the DB CHECKs.</summary>
public sealed class HospitalSignupValidationTests
{
    private static HospitalSignupRequest Valid() => new("Synthetic Care Hospital", "Asia/Kolkata", "Asha Synthetic", "asha@synthetic.example", "+91 555 0100 200", "Pune");

    [Fact]
    public void A_complete_request_is_valid() => Assert.Empty(PlatformEndpoints.Validate(Valid()));

    [Theory]
    [InlineData("hospitalName")]
    [InlineData("timeZone")]
    [InlineData("contactName")]
    [InlineData("contactEmail")]
    [InlineData("phone")]
    [InlineData("city")]
    public void Every_field_is_required(string field)
    {
        var r = field switch
        {
            "hospitalName" => Valid() with { HospitalName = " " },
            "timeZone" => Valid() with { TimeZone = null },
            "contactName" => Valid() with { ContactName = "" },
            "contactEmail" => Valid() with { ContactEmail = "asha" },
            "phone" => Valid() with { Phone = "call me" },
            _ => Valid() with { City = null },
        };
        Assert.Equal([field], PlatformEndpoints.Validate(r).Keys);
    }

    [Theory]
    [InlineData("IST")]
    [InlineData("Asia/Kolkata+5")]
    [InlineData("Mars/Olympus")]
    public void Pseudo_or_unknown_zones_are_rejected(string zone) =>
        Assert.True(PlatformEndpoints.Validate(Valid() with { TimeZone = zone }).ContainsKey("timeZone"));

    [Fact]
    public void A_legacy_alias_is_accepted() => Assert.Empty(PlatformEndpoints.Validate(Valid() with { TimeZone = "Asia/Calcutta" }));
}
