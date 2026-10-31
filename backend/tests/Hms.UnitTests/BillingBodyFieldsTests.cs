using System.Text.Json;
using Hms.Modules.Billing.Endpoints;
using Microsoft.AspNetCore.Http.HttpResults;
using Xunit;

namespace Hms.UnitTests;

public class BillingBodyFieldsTests
{
    private static JsonElement J(string s) => JsonDocument.Parse(s).RootElement;

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"appointmentId\":null}")]
    [InlineData("{\"appointmentId\":\"nope\"}")]
    [InlineData("{\"appointmentId\":42}")]
    [InlineData("[]")]
    public void TryGuid_rejects_missing_or_malformed(string body) =>
        Assert.False(BodyFields.TryGuid(J(body), "appointmentId", out _));

    [Fact]
    public void TryGuid_accepts_uuid()
    {
        var id = Guid.NewGuid();
        Assert.True(BodyFields.TryGuid(J($"{{\"appointmentId\":\"{id}\"}}"), "appointmentId", out var got));
        Assert.Equal(id, got);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"stateCode\":\"\"}")]
    [InlineData("{\"stateCode\":\"  \"}")]
    [InlineData("{\"stateCode\":29}")]
    public void TryString_rejects_missing_blank_or_non_string(string body) =>
        Assert.False(BodyFields.TryString(J(body), "stateCode", out _));

    [Fact]
    public void TryString_accepts_value() =>
        Assert.True(BodyFields.TryString(J("{\"stateCode\":\"29\"}"), "stateCode", out var v) && v == "29");

    [Theory]
    [InlineData("{}", false)]
    [InlineData("{\"payload\":\"x\"}", false)]
    [InlineData("{\"payload\":{\"tenant_id\":\"t\"}}", true)]
    public void TryObject_requires_json_object(string body, bool ok) =>
        Assert.Equal(ok, BodyFields.TryObject(J(body), "payload", out _));

    [Fact]
    public async Task Invalid_is_400_invalid_parameter()
    {
        var r = Assert.IsType<ProblemHttpResult>(await BodyFields.Invalid("branchId", "a UUID"));
        Assert.Equal(400, r.StatusCode);
        Assert.Contains("branchId", r.ProblemDetails.Detail);
    }
}
