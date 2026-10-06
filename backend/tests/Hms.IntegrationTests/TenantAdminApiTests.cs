using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

[Trait("Category", "Database")]
public sealed class TenantAdminApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static string NewCode() => $"br-{Guid.NewGuid():N}"[..12];

    [Fact]
    public async Task Admin_creates_lists_and_updates_branches()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var code = NewCode();
        var created = await client.PostAsJsonAsync("/api/v1/branches", new { code, name = "Alpha North", timezone = "Asia/Kolkata" });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var branch = await created.Content.ReadFromJsonAsync<BranchView>();
        Assert.Equal(code, branch!.Code);

        var duplicate = await client.PostAsJsonAsync("/api/v1/branches", new { code, name = "Again", timezone = "UTC" });
        Assert.Equal(HttpStatusCode.Conflict, duplicate.StatusCode);

        var updated = await client.PatchAsJsonAsync($"/api/v1/branches/{branch.Id}", new { name = "Alpha North Wing", isActive = false });
        Assert.Equal(HttpStatusCode.OK, updated.StatusCode);
        var after = await updated.Content.ReadFromJsonAsync<BranchView>();
        Assert.Equal("Alpha North Wing", after!.Name);
        Assert.False(after.IsActive);

        var list = await client.GetFromJsonAsync<List<BranchView>>("/api/v1/branches");
        Assert.Contains(list!, b => b.Id == branch.Id);
        Assert.DoesNotContain(list!, b => b.Id == BetaMain);
    }

    [Fact]
    public async Task Invalid_branch_payload_is_400()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.PostAsJsonAsync("/api/v1/branches", new { code = "BAD CODE!", name = "", timezone = "Mars/Olympus" });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Admin_cannot_update_another_tenants_branch()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.PatchAsJsonAsync($"/api/v1/branches/{BetaMain}", new { name = "Hijacked" });
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Theory]
    [InlineData("/api/v1/members")]
    public async Task Non_admin_cannot_manage_members(string path)
    {
        using var client = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync(path)).StatusCode);
        var post = await client.PostAsJsonAsync(path, new { email = "x@synthetic.example", role = "doctor" });
        Assert.Equal(HttpStatusCode.Forbidden, post.StatusCode);
    }

    [Fact]
    public async Task Non_admin_cannot_create_branches_but_can_list_active_ones()
    {
        using var client = factory.ClientAs(AlphaReception, Alpha);
        var post = await client.PostAsJsonAsync("/api/v1/branches", new { code = NewCode(), name = "Nope", timezone = "UTC" });
        Assert.Equal(HttpStatusCode.Forbidden, post.StatusCode);
        var list = await client.GetFromJsonAsync<List<BranchView>>("/api/v1/branches");
        Assert.All(list!, b => Assert.True(b.IsActive));
    }

    [Fact]
    public async Task Admin_adds_member_with_branch_scope_then_updates_role_and_status()
    {
        var user = await CreateUserAsync("newhire");
        var email = await EmailOfAsync(user);
        using var client = factory.ClientAs(AlphaAdmin, Alpha);

        var added = await client.PostAsJsonAsync("/api/v1/members", new { email, role = "nurse", branchId = AlphaEast });
        Assert.Equal(HttpStatusCode.Created, added.StatusCode);
        var member = await added.Content.ReadFromJsonAsync<MemberView>();
        Assert.Equal(user, member!.UserId);
        Assert.Equal("nurse", member.Role);
        Assert.Equal(AlphaEast, member.BranchId);

        var again = await client.PostAsJsonAsync("/api/v1/members", new { email, role = "nurse", branchId = AlphaEast });
        Assert.Equal(HttpStatusCode.Conflict, again.StatusCode);

        var patched = await client.PatchAsJsonAsync($"/api/v1/members/{member.Id}", new { role = "doctor", status = "suspended" });
        Assert.Equal(HttpStatusCode.OK, patched.StatusCode);
        var after = await patched.Content.ReadFromJsonAsync<MemberView>();
        Assert.Equal("doctor", after!.Role);
        Assert.Equal("suspended", after.Status);

        var members = await client.GetFromJsonAsync<List<MemberView>>("/api/v1/members");
        // Suspended members stay listed WITH their email so the admin can reactivate them.
        Assert.Contains(members!, m => m.Id == member.Id && m.Email == email && m.Status == "suspended");
        Assert.DoesNotContain(members!, m => m.UserId == BetaAdmin);

        // Suspended membership grants nothing.
        using var suspended = factory.ClientAs(user, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await suspended.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task Adding_unknown_email_is_404()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.PostAsJsonAsync("/api/v1/members", new { email = $"nobody-{Guid.NewGuid():N}@synthetic.example", role = "doctor" });
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Member_branch_must_belong_to_the_tenant()
    {
        var user = await CreateUserAsync("crossbranch");
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.PostAsJsonAsync("/api/v1/members", new { email = await EmailOfAsync(user), role = "doctor", branchId = BetaMain });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Invalid_role_is_400()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.PostAsJsonAsync("/api/v1/members", new { email = "a@synthetic.example", role = "superuser" });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Admin_cannot_edit_own_membership_or_another_tenants()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var members = await client.GetFromJsonAsync<List<MemberView>>("/api/v1/members");
        var mine = members!.First(m => m.UserId == AlphaAdmin);
        var self = await client.PatchAsJsonAsync($"/api/v1/members/{mine.Id}", new { status = "suspended" });
        Assert.Equal(HttpStatusCode.Conflict, self.StatusCode);

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var betaMembers = await beta.GetFromJsonAsync<List<MemberView>>("/api/v1/members");
        var betaDoctor = betaMembers!.First(m => m.UserId == BetaDoctor);
        var cross = await client.PatchAsJsonAsync($"/api/v1/members/{betaDoctor.Id}", new { role = "nurse" });
        Assert.Equal(HttpStatusCode.NotFound, cross.StatusCode);
    }
}
