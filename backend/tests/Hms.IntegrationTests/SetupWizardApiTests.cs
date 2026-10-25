using System.Net;
using System.Net.Http.Json;
using Hms.IntegrationTests.AuditTz;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>
/// New-tenant setup wizard. The tenant is the JWT's tenant: a tenant id in the body is ignored.
/// </summary>
[Trait("Category", "Database")]
public sealed class SetupWizardApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private sealed record SetupState(string Step, DateTimeOffset? CompletedOn, Guid? BranchId, string? DocumentPrefix);

    [Fact]
    public async Task Seeded_admin_is_done_and_a_non_admin_is_forbidden()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var state = (await admin.GetFromJsonAsync<SetupState>("/api/v1/setup"))!;
        Assert.Equal("done", state.Step);
        Assert.NotNull(state.CompletedOn);
        Assert.Equal("DEMO", state.DocumentPrefix);
        Assert.Equal(AlphaMain, state.BranchId);

        using var reception = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.GetAsync("/api/v1/setup")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsJsonAsync("/api/v1/setup/step", new { step = "profile" })).StatusCode);
    }

    [Fact]
    public async Task A_new_hospital_walks_the_wizard_and_new_branches_inherit_the_prefix()
    {
        var tenant = await ATz.NewTenantAsync(factory, "Asia/Kolkata");
        using var admin = factory.ClientAs(tenant.AdminId, tenant.TenantId);
        var prefix = PrefixOf(tenant.Code);

        var open = (await admin.GetFromJsonAsync<SetupState>("/api/v1/setup"))!;
        Assert.Equal(("profile", (DateTimeOffset?)null, tenant.MainBranchId, prefix), (open.Step, open.CompletedOn, open.BranchId, open.DocumentPrefix));

        // A client-supplied tenant id cannot retarget the call, and a step cannot be skipped.
        var skipped = await admin.PostAsJsonAsync("/api/v1/setup/step", new { step = "done", tenantId = Alpha });
        Assert.Equal(HttpStatusCode.BadRequest, skipped.StatusCode);
        Assert.Equal("done", await ATz.ScalarAsync<string>("select setup_step from identity.tenants where id = @t", ("t", Alpha)));
        Assert.Equal("profile", await ATz.ScalarAsync<string>("select setup_step from identity.tenants where id = @t", ("t", tenant.TenantId)));

        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { defaultCountryCode = "91" })).StatusCode);
        var hospital = await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { defaultCountryCode = "+971" });
        Assert.Equal(HttpStatusCode.OK, hospital.StatusCode);
        Assert.Equal("+971", await ATz.ScalarAsync<string>("select default_country_code from identity.tenants where id = @t", ("t", tenant.TenantId)));

        var branch = await ATz.ReadAsync<SetupState>(await admin.PostAsJsonAsync("/api/v1/setup/step", new { step = "branch" }), HttpStatusCode.OK);
        Assert.Equal("branch", branch.Step);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync($"/api/v1/branches/{tenant.MainBranchId}", new { address = "  " })).StatusCode);
        var saved = await admin.PatchAsJsonAsync($"/api/v1/branches/{tenant.MainBranchId}", new { name = "Main Campus", address = "1 Synthetic Road" });
        Assert.Equal(HttpStatusCode.OK, saved.StatusCode);
        Assert.Equal("1 Synthetic Road", await ATz.ScalarAsync<string>("select address from identity.branches where id = @b", ("b", tenant.MainBranchId)));

        Assert.Equal("staff", (await ATz.ReadAsync<SetupState>(await admin.PostAsJsonAsync("/api/v1/setup/step", new { step = "staff" }), HttpStatusCode.OK)).Step);
        Assert.Equal("schedule", (await ATz.ReadAsync<SetupState>(await admin.PostAsJsonAsync("/api/v1/setup/step", new { step = "schedule" }), HttpStatusCode.OK)).Step);
        var done = await ATz.ReadAsync<SetupState>(await admin.PostAsJsonAsync("/api/v1/setup/step", new { step = "done" }), HttpStatusCode.OK);
        Assert.Equal("done", done.Step);
        Assert.NotNull(done.CompletedOn);
        Assert.Equal(done.Step, (await ATz.ReadAsync<SetupState>(await admin.PostAsJsonAsync("/api/v1/setup/step", new { step = "done" }), HttpStatusCode.OK)).Step);
        Assert.Equal(HttpStatusCode.Conflict, (await admin.PostAsJsonAsync("/api/v1/setup/step", new { step = "profile" })).StatusCode);

        var code = ATz.Code("px");
        var created = await ATz.ReadAsync<ATzBranch>(
            await admin.PostAsJsonAsync("/api/v1/branches", new { code, name = "Second " + code }),
            HttpStatusCode.Created);
        Assert.Equal(prefix, await ATz.ScalarAsync<string>("select doc_prefix from billing.branch_profile where branch_id = @b", ("b", created.Id)));
        Assert.Equal(prefix, await ATz.ScalarAsync<string>("select doc_prefix from billing.branch_profile where branch_id = @b", ("b", tenant.MainBranchId)));
    }

    private static string PrefixOf(string code)
    {
        var alnum = new string(code.ToUpperInvariant().Where(char.IsLetterOrDigit).Take(4).ToArray());
        return alnum.Length == 0 ? "OP" : alnum;
    }
}
