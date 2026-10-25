using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>DPDP notices, consent, and rights requests through the edge.</summary>
[Trait("Category", "Database")]
public sealed class PrivacyApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid Ravi = Guid.Parse("aa000000-0000-4000-8000-000000000002");
    private static readonly string[] Reminders = ["reminders"];
    private static readonly string[] RemindersAndMarketing = ["reminders", "marketing"];
    private const string NoticeBody =
        "Alpha Hospital tells you what it uses your health information for. Treatment and billing do not need a separate tick.";

    [Fact]
    public async Task Admin_publishes_a_notice_records_consent_and_a_stranger_cannot_see_it()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var coded = await Post(admin, "/api/v1/privacy/consent-notices", new { code = "N-1", language = "en", title = "T", body = NoticeBody, purposes = Reminders }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.BadRequest, coded.Status);
        Assert.Contains("Codes are generated automatically", coded.Body.GetProperty("detail").GetString(), StringComparison.Ordinal);

        var key = Guid.NewGuid();
        var draft = await Post(admin, "/api/v1/privacy/consent-notices", new
        {
            language = "en",
            title = "How this hospital uses health information",
            body = NoticeBody,
            purposes = RemindersAndMarketing,
        }, key);
        Assert.Equal(HttpStatusCode.OK, draft.Status);
        Assert.True(draft.Body.GetProperty("version").GetInt32() >= 1);
        var noticeId = draft.Body.GetProperty("noticeId").GetString();

        var replay = await Post(admin, "/api/v1/privacy/consent-notices", new
        {
            language = "en",
            title = "How this hospital uses health information",
            body = NoticeBody,
            purposes = RemindersAndMarketing,
        }, key);
        Assert.Equal(noticeId, replay.Body.GetProperty("noticeId").GetString());

        var published = await Post(admin, $"/api/v1/privacy/consent-notices/{noticeId}/publish", new { }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.OK, published.Status);
        Assert.False(published.Body.GetProperty("publishedAt").ValueKind == JsonValueKind.Null);

        using var desk = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        var denied = await Post(desk, "/api/v1/privacy/consent-notices", new
        {
            language = "en",
            title = "Reception must not draft this",
            body = NoticeBody,
            purposes = Reminders,
        }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.Forbidden, denied.Status);

        var recorded = await Post(desk, $"/api/v1/privacy/patients/{Ravi}/consents", new
        {
            noticeId,
            channel = "tablet",
            givenBy = "self",
            subjectIsMinor = false,
            choices = new[] { new { purposeCode = "reminders", granted = true }, new { purposeCode = "marketing", granted = false } },
        }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.OK, recorded.Status);
        Assert.True(recorded.Body.GetProperty("receiptQueued").GetBoolean());

        var consents = await Get(admin, $"/api/v1/privacy/patients/{Ravi}/consents");
        Assert.Equal(HttpStatusCode.OK, consents.Status);
        Assert.Contains(consents.Body.GetProperty("current").EnumerateArray(), row =>
            row.GetProperty("purposeCode").GetString() == "reminders" && row.GetProperty("granted").GetBoolean());

        var minor = await Post(desk, $"/api/v1/privacy/patients/{Ravi}/consents", new
        {
            noticeId,
            channel = "tablet",
            givenBy = "self",
            subjectIsMinor = true,
            choices = new[] { new { purposeCode = "reminders", granted = true } },
        }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.UnprocessableEntity, minor.Status);
        Assert.Equal("guardian_required", minor.Body.GetProperty("code").GetString());

        var link = await Post(desk, $"/api/v1/privacy/patients/{Ravi}/consent-links", new { });
        Assert.Equal(HttpStatusCode.OK, link.Status);
        var path = link.Body.GetProperty("path").GetString()!;
        Assert.StartsWith("/privacy/consent/", path, StringComparison.Ordinal);
        Assert.False(link.Body.TryGetProperty("token", out _));
        var token = path["/privacy/consent/".Length..];

        using var anon = factory.CreateClient();
        var preview = await Get(anon, $"/api/v1/privacy/public/consents/{token}");
        Assert.Equal(HttpStatusCode.OK, preview.Status);
        Assert.False(preview.Body.TryGetProperty("patientId", out _));
        Assert.DoesNotContain("ALP-", preview.Body.GetRawText(), StringComparison.Ordinal);

        var leaked = await Post(anon, $"/api/v1/privacy/public/consents/{token}", new { tenantId = Alpha, choices = new[] { new { purposeCode = "marketing", granted = true } } });
        Assert.Equal(HttpStatusCode.BadRequest, leaked.Status);

        var submitted = await Post(anon, $"/api/v1/privacy/public/consents/{token}", new { choices = new[] { new { purposeCode = "marketing", granted = true } } });
        Assert.Equal(HttpStatusCode.OK, submitted.Status);
        var again = await Get(anon, $"/api/v1/privacy/public/consents/{token}");
        Assert.Equal(HttpStatusCode.Gone, again.Status);
        Assert.Equal("link_expired", again.Body.GetProperty("code").GetString());

        using var beta = factory.ClientAs(BetaAdmin, Beta, BetaMain);
        var hidden = await Get(beta, $"/api/v1/privacy/patients/{Ravi}/consents");
        Assert.Equal(HttpStatusCode.NotFound, hidden.Status);
        Assert.Equal("not_found", hidden.Body.GetProperty("code").GetString());
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Post(HttpClient client, string path, object body, Guid? idempotencyKey = null)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(body) };
        if (idempotencyKey is { } key)
        {
            request.Headers.TryAddWithoutValidation("Idempotency-Key", key.ToString());
        }

        var response = await client.SendAsync(request);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Get(HttpClient client, string path)
    {
        var response = await client.GetAsync(path);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<JsonElement> Read(HttpResponseMessage response)
    {
        var text = await response.Content.ReadAsStringAsync();
        return text.Length == 0 ? default : JsonDocument.Parse(text).RootElement.Clone();
    }
}
