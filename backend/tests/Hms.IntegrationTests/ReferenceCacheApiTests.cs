using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Server-side reference cache (identity branch list) and edge conditional GETs, end to end.</summary>
[Trait("Category", "Database")]
public sealed class ReferenceCacheApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static string NewCode() => $"rc-{Guid.NewGuid():N}"[..12];

    [Fact]
    public async Task Cached_branch_lists_never_cross_tenants()
    {
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        // Warm both tenants' entries (same kind and variant: admin view) several times.
        for (var i = 0; i < 2; i++)
        {
            var a = await alpha.GetFromJsonAsync<List<BranchView>>("/api/v1/branches");
            var b = await beta.GetFromJsonAsync<List<BranchView>>("/api/v1/branches");
            Assert.Contains(a!, x => x.Id == AlphaMain);
            Assert.DoesNotContain(a!, x => x.Id == BetaMain);
            Assert.Contains(b!, x => x.Id == BetaMain);
            Assert.DoesNotContain(b!, x => x.Id == AlphaMain || x.Id == AlphaEast);
        }

        // A client-supplied tenant header cannot select another tenant's cache entry.
        using var spoof = factory.ClientAs(BetaAdmin, Beta);
        spoof.DefaultRequestHeaders.Add("X-Hms-Tenant", Alpha.ToString());
        var spoofed = await spoof.GetFromJsonAsync<List<BranchView>>("/api/v1/branches");
        Assert.DoesNotContain(spoofed!, x => x.Id == AlphaMain);
    }

    [Fact]
    public async Task A_branch_write_is_visible_on_the_next_read_for_that_tenant_only()
    {
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        _ = await alpha.GetFromJsonAsync<List<BranchView>>("/api/v1/branches"); // cached
        _ = await reception.GetFromJsonAsync<List<BranchView>>("/api/v1/branches"); // cached (member view)
        var betaBefore = await beta.GetFromJsonAsync<List<BranchView>>("/api/v1/branches");

        var created = await alpha.PostAsJsonAsync("/api/v1/branches", new { code = NewCode(), name = "Alpha Cache Wing", timezone = "Asia/Kolkata" });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var branch = (await created.Content.ReadFromJsonAsync<BranchView>())!;

        Assert.Contains(await alpha.GetFromJsonAsync<List<BranchView>>("/api/v1/branches") ?? [], x => x.Id == branch.Id);
        Assert.Contains(await reception.GetFromJsonAsync<List<BranchView>>("/api/v1/branches") ?? [], x => x.Id == branch.Id);

        var renamed = await alpha.PatchAsJsonAsync($"/api/v1/branches/{branch.Id}", new { name = "Alpha Cache Wing 2", isActive = false });
        Assert.Equal(HttpStatusCode.OK, renamed.StatusCode);
        var adminView = await alpha.GetFromJsonAsync<List<BranchView>>("/api/v1/branches");
        Assert.Equal("Alpha Cache Wing 2", adminView!.Single(x => x.Id == branch.Id).Name);
        // members only see active branches: the deactivated one is gone from their (re-read) view
        Assert.DoesNotContain(await reception.GetFromJsonAsync<List<BranchView>>("/api/v1/branches") ?? [], x => x.Id == branch.Id);
        Assert.Equal(betaBefore!.Select(x => x.Id).Order(), (await beta.GetFromJsonAsync<List<BranchView>>("/api/v1/branches"))!.Select(x => x.Id).Order());
    }

    [Fact]
    public async Task Edge_answers_revalidation_with_304_and_keeps_phi_no_store()
    {
        if (Target != SystemTarget.Edge)
        {
            return;
        }

        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var first = await client.GetAsync("/api/v1/branches");
        Assert.Equal(HttpStatusCode.OK, first.StatusCode);
        var etag = first.Headers.ETag;
        Assert.NotNull(etag);
        Assert.True(first.Headers.CacheControl!.Private);
        Assert.True(first.Headers.CacheControl.NoCache);

        using var conditional = new HttpRequestMessage(HttpMethod.Get, "/api/v1/branches");
        conditional.Headers.IfNoneMatch.Add(etag!);
        var second = await client.SendAsync(conditional);
        Assert.Equal(HttpStatusCode.NotModified, second.StatusCode);
        Assert.Empty(await second.Content.ReadAsByteArrayAsync());

        var patients = await client.GetAsync("/api/v1/patients");
        Assert.Null(patients.Headers.ETag);
        Assert.True(patients.Headers.CacheControl!.NoStore);

        // Same URL, other tenant: its own body and tag; Alpha's tag does not validate Beta's data.
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        using var crossed = new HttpRequestMessage(HttpMethod.Get, "/api/v1/branches");
        crossed.Headers.IfNoneMatch.Add(etag!);
        var betaResponse = await beta.SendAsync(crossed);
        Assert.Equal(HttpStatusCode.OK, betaResponse.StatusCode);
        Assert.NotEqual(etag, betaResponse.Headers.ETag);
    }
}
