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

public class BillingEventTenantStampTests
{
    private static readonly Guid Session = Guid.NewGuid();

    [Fact]
    public void Missing_tenant_is_set_from_session()
    {
        Assert.True(BodyFields.TryStampTenant("{\"appointment_id\":\"a\"}", Session, out var s));
        Assert.Equal(Session.ToString(), JsonDocument.Parse(s).RootElement.GetProperty("tenant_id").GetString());
    }

    [Fact]
    public void Matching_tenant_is_kept() =>
        Assert.True(BodyFields.TryStampTenant($"{{\"tenant_id\":\"{Session}\"}}", Session, out _));

    [Theory]
    [InlineData("{\"tenant_id\":\"11111111-1111-4111-8111-111111111112\"}")]
    [InlineData("{\"tenant_id\":\"garbage\"}")]
    [InlineData("{\"tenant_id\":42}")]
    public void Other_or_malformed_tenant_is_rejected(string payload) =>
        Assert.False(BodyFields.TryStampTenant(payload, Session, out _));

    [Fact]
    public void Null_tenant_is_replaced_by_session()
    {
        Assert.True(BodyFields.TryStampTenant("{\"tenant_id\":null}", Session, out var s));
        Assert.Contains(Session.ToString(), s);
    }
}
