using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>
/// #75 / REG-041: price list GST defaults and deactivating a service, through the real API.
/// Every service is created fresh with a unique Zz- name, so nothing depends on seed rows.
/// </summary>
[Trait("Category", "Database")]
public sealed class ServiceCatalogApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static string Name(string what) => $"Zz {what} {Guid.NewGuid():N}";

    [Fact]
    public async Task A_service_without_a_tax_gets_its_category_default_and_prefix()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var defaults = await Get(admin, "/api/v1/service-items/category-defaults");
        Assert.Equal(HttpStatusCode.OK, defaults.Status);
        Assert.True(defaults.Body.GetArrayLength() > 0);

        foreach (var d in defaults.Body.EnumerateArray())
        {
            var category = d.GetProperty("category").GetString()!;
            var name = Name(category);
            var created = await Post(admin, "/api/v1/service-items", new { name, category });
            Assert.True(created.Status == HttpStatusCode.OK, $"{category}: {(int)created.Status} {created.Body}");

            var row = await Find(admin, name);
            Assert.Equal(d.GetProperty("taxCodeId").GetGuid(), row.GetProperty("taxCodeId").GetGuid());
            Assert.Equal(d.GetProperty("rateBp").GetInt32(), row.GetProperty("taxRateBp").GetInt32());
            Assert.StartsWith(d.GetProperty("codePrefix").GetString()!, row.GetProperty("code").GetString());
        }
    }

    [Fact]
    public async Task An_explicit_tax_wins_and_a_category_change_without_tax_re_defaults()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var defaults = (await Get(admin, "/api/v1/service-items/category-defaults")).Body.EnumerateArray()
            .ToDictionary(d => d.GetProperty("category").GetString()!, d => d.GetProperty("taxCodeId").GetGuid());
        var taxes = (await Get(admin, "/api/v1/service-items/tax-codes")).Body.EnumerateArray().Select(t => t.GetProperty("id").GetGuid()).ToList();
        var other = taxes.First(t => t != defaults["procedure"]);

        var name = Name("explicit");
        var created = await Post(admin, "/api/v1/service-items", new { name, category = "procedure", taxCodeId = other });
        Assert.Equal(HttpStatusCode.OK, created.Status);
        var id = created.Body.GetProperty("id").GetGuid();
        Assert.Equal(other, (await Find(admin, name)).GetProperty("taxCodeId").GetGuid());

        // Renaming alone leaves the tax as it is.
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, "/api/v1/service-items", new { id, name = name + " v2" })).Status);
        Assert.Equal(other, (await Find(admin, name + " v2")).GetProperty("taxCodeId").GetGuid());

        // A new category with no tax takes that category's default.
        var target = defaults.Keys.First(c => c != "procedure");
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, "/api/v1/service-items", new { id, category = target })).Status);
        Assert.Equal(defaults[target], (await Find(admin, name + " v2")).GetProperty("taxCodeId").GetGuid());
    }

    [Fact]
    public async Task A_deactivated_service_leaves_the_active_list_and_can_come_back()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var name = Name("deactivate");
        var id = (await Post(admin, "/api/v1/service-items", new { name, category = "lab" })).Body.GetProperty("id").GetGuid();

        Assert.Equal(HttpStatusCode.OK, (await Post(admin, "/api/v1/service-items", new { id, isActive = false })).Status);
        Assert.Null(await TryFind(admin, name));
        var inactive = await Find(admin, name, includeInactive: true);
        Assert.False(inactive.GetProperty("isActive").GetBoolean());

        Assert.Equal(HttpStatusCode.OK, (await Post(admin, "/api/v1/service-items", new { id, isActive = true })).Status);
        Assert.True((await Find(admin, name)).GetProperty("isActive").GetBoolean());
    }

    [Fact]
    public async Task Bad_input_rbac_and_cross_tenant_are_refused()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.BadRequest, (await Post(admin, "/api/v1/service-items", new { name = Name("bad"), category = "unicorn" })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await Post(admin, "/api/v1/service-items", new { category = "lab" })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await Post(admin, "/api/v1/service-items", new { name = Name("bad"), category = "lab", code = "LAB-9999" })).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await Post(admin, "/api/v1/service-items", new { name = Name("bad"), category = "lab", taxCodeId = Guid.NewGuid() })).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await Post(admin, "/api/v1/service-items", new { id = Guid.NewGuid(), isActive = false })).Status);

        using var reception = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await Post(reception, "/api/v1/service-items", new { name = Name("rbac"), category = "lab" })).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await Get(reception, "/api/v1/service-items/category-defaults")).Status);

        var name = Name("tenant");
        var id = (await Post(admin, "/api/v1/service-items", new { name, category = "lab" })).Body.GetProperty("id").GetGuid();
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await Post(beta, "/api/v1/service-items", new { id, isActive = false })).Status);
        Assert.Null(await TryFind(beta, name, includeInactive: true));
        Assert.True((await Find(admin, name)).GetProperty("isActive").GetBoolean());
    }

    private static async Task<JsonElement> Find(HttpClient client, string name, bool includeInactive = false) =>
        await TryFind(client, name, includeInactive) ?? throw new Xunit.Sdk.XunitException($"{name} not listed");

    private static async Task<JsonElement?> TryFind(HttpClient client, string name, bool includeInactive = false)
    {
        var list = await Get(client, $"/api/v1/service-items?q={Uri.EscapeDataString(name)}&includeInactive={includeInactive.ToString().ToLowerInvariant()}");
        Assert.Equal(HttpStatusCode.OK, list.Status);
        foreach (var row in list.Body.EnumerateArray())
        {
            if (row.GetProperty("name").GetString() == name)
            {
                return row.Clone();
            }
        }

        return null;
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Get(HttpClient client, string path)
    {
        var response = await client.GetAsync(path);
        var text = await response.Content.ReadAsStringAsync();
        return (response.StatusCode, string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone());
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Post(HttpClient client, string path, object body)
    {
        var response = await client.PostAsJsonAsync(path, body);
        var text = await response.Content.ReadAsStringAsync();
        return (response.StatusCode, string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone());
    }
}
