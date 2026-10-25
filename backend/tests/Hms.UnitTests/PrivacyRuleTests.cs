using System.Text.Json;
using Hms.Modules.Privacy.Endpoints;

namespace Hms.UnitTests;

public class PrivacyRuleTests
{
    [Fact]
    public void Client_supplied_codes_use_the_design_sentence()
    {
        using var doc = JsonDocument.Parse("{\"version\":1}");
        Assert.True(PrivacyCodeRules.HasClientSuppliedCode(doc.RootElement));
        Assert.Equal("Codes are generated automatically; leave this field empty.", PrivacyCodeRules.ClientSuppliedCodeDetail);
    }

    [Fact]
    public void An_empty_body_does_not_count_as_a_supplied_code()
    {
        using var doc = JsonDocument.Parse("{}");
        Assert.False(PrivacyCodeRules.HasClientSuppliedCode(doc.RootElement));
        Assert.False(PrivacyCodeRules.HasPublicTenant(doc.RootElement));
    }

    [Theory]
    [InlineData("guardian_required|A parent or guardian must give consent for a child.", 422)]
    [InlineData("notice_not_current|This notice is not the current one. Reload and try again.", 422)]
    [InlineData("identity_not_verified|Verify who is asking before you fulfil the request.", 422)]
    [InlineData("no_published_notice|Publish a privacy notice in Admin › Privacy first.", 404)]
    [InlineData("link_expired|This link has expired. Ask the hospital for a new one.", 410)]
    [InlineData("not_granted|That purpose is not currently granted.", 409)]
    [InlineData("published_immutable|A published privacy notice cannot be changed.", 409)]
    [InlineData("second_approver_required|Erasure needs a second person to approve it first.", 409)]
    [InlineData("invalid_parameter|Codes are generated automatically; leave this field empty.", 400)]
    public void Privacy_failures_keep_their_own_status(string message, int status)
    {
        var problem = PrivacyProblems.FromMessage(message);
        Assert.NotNull(problem);
        Assert.Equal(status, problem.StatusCode);
    }
}
