using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.IntegrationTests.AuditTz;
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

    private const string InviteMessage = "If an account exists for that email, an invitation has been sent.";

    private static async Task AssertUniformAcceptedAsync(HttpResponseMessage response)
    {
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        Assert.Null(response.Headers.Location);
        var body = await response.Content.ReadFromJsonAsync<AcceptedView>();
        Assert.Equal(InviteMessage, body!.Message);
    }

    [Fact]
    public async Task Admin_invites_member_who_must_accept_before_gaining_access()
    {
        var user = await CreateUserAsync("newhire");
        var email = await EmailOfAsync(user);
        using var client = factory.ClientAs(AlphaAdmin, Alpha);

        await AssertUniformAcceptedAsync(await client.PostAsJsonAsync("/api/v1/members", new { email, role = "nurse", branchId = AlphaEast }));
        // Already invited / already a member: same answer, no conflict signal.
        await AssertUniformAcceptedAsync(await client.PostAsJsonAsync("/api/v1/members", new { email, role = "nurse", branchId = AlphaEast }));

        // Invited grants nothing and is not listed to the admin (listing would reveal the account).
        using var invitee = factory.ClientAs(user, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await invitee.GetAsync("/api/v1/patients")).StatusCode);
        Assert.DoesNotContain((await client.GetFromJsonAsync<List<MemberView>>("/api/v1/members"))!, m => m.UserId == user);

        // The invitee sees the invitation (no tenant needed).
        using var inviteeNoTenant = factory.ClientAs(user);
        var invitations = await inviteeNoTenant.GetFromJsonAsync<List<InvitationView>>("/api/v1/me/invitations");
        var invitation = Assert.Single(invitations!, i => i.TenantId == Alpha);
        Assert.Equal("nurse", invitation.Role);
        Assert.Equal(AlphaEast, invitation.BranchId);
        Assert.False(string.IsNullOrWhiteSpace(invitation.TenantName));

        // The admin cannot activate it on the invitee's behalf; nobody else can accept it.
        var forced = await client.PatchAsJsonAsync($"/api/v1/members/{invitation.MembershipId}", new { status = "active" });
        Assert.Equal(HttpStatusCode.NotFound, forced.StatusCode);
        using var other = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.NotFound, (await other.PostAsync($"/api/v1/me/invitations/{invitation.MembershipId}/accept", null)).StatusCode);

        // Accept -> 204, then it is no longer pending.
        Assert.Equal(HttpStatusCode.NoContent, (await inviteeNoTenant.PostAsync($"/api/v1/me/invitations/{invitation.MembershipId}/accept", null)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await inviteeNoTenant.PostAsync($"/api/v1/me/invitations/{invitation.MembershipId}/accept", null)).StatusCode);
        Assert.DoesNotContain((await inviteeNoTenant.GetFromJsonAsync<List<InvitationView>>("/api/v1/me/invitations"))!, i => i.MembershipId == invitation.MembershipId);
        Assert.Equal(HttpStatusCode.OK, (await invitee.GetAsync("/api/v1/patients")).StatusCode);

        var members = await client.GetFromJsonAsync<List<MemberView>>("/api/v1/members");
        var member = Assert.Single(members!, m => m.UserId == user);
        var patched = await client.PatchAsJsonAsync($"/api/v1/members/{member.Id}", new { role = "doctor", status = "suspended" });
        Assert.Equal(HttpStatusCode.OK, patched.StatusCode);
        var after = await patched.Content.ReadFromJsonAsync<MemberView>();
        Assert.Equal("doctor", after!.Role);
        Assert.Equal("suspended", after.Status);

        members = await client.GetFromJsonAsync<List<MemberView>>("/api/v1/members");
        // Suspended members stay listed WITH their email so the admin can reactivate them.
        Assert.Contains(members!, m => m.Id == member.Id && m.Email == email && m.Status == "suspended");
        Assert.DoesNotContain(members!, m => m.UserId == BetaAdmin);

        // Suspended membership grants nothing.
        Assert.Equal(HttpStatusCode.Forbidden, (await invitee.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task Unknown_email_gets_the_same_202_as_a_real_invite()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var unknown = await client.PostAsJsonAsync("/api/v1/members", new { email = $"nobody-{Guid.NewGuid():N}@synthetic.example", role = "doctor" });
        var known = await client.PostAsJsonAsync("/api/v1/members", new { email = await EmailOfAsync(await CreateUserAsync("known")), role = "doctor" });
        await AssertUniformAcceptedAsync(unknown);
        await AssertUniformAcceptedAsync(known);
        Assert.Equal(await known.Content.ReadAsStringAsync(), await unknown.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Inviting_another_tenants_user_does_not_change_their_default_context()
    {
        // Review B1 / PoC P1.
        var victim = await CreateUserAsync("victim", (Beta, null, "doctor"));
        using var victimClient = factory.ClientAs(victim); // no tenant claim => server-side default
        Assert.Equal(Beta, (await victimClient.GetFromJsonAsync<TenantView>("/api/v1/tenants/current"))!.Id);

        using var alphaAdmin = factory.ClientAs(AlphaAdmin, Alpha);
        await AssertUniformAcceptedAsync(await alphaAdmin.PostAsJsonAsync("/api/v1/members", new { email = await EmailOfAsync(victim), role = "doctor" }));

        Assert.Equal(Beta, (await victimClient.GetFromJsonAsync<TenantView>("/api/v1/tenants/current"))!.Id);
        using var victimInAlpha = factory.ClientAs(victim, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await victimInAlpha.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task User_without_any_membership_can_list_invitations()
    {
        var loner = await CreateUserAsync("loner");
        using var client = factory.ClientAs(loner);
        var response = await client.GetAsync("/api/v1/me/invitations");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Empty((await response.Content.ReadFromJsonAsync<List<InvitationView>>())!);
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync($"/api/v1/me/invitations/{Guid.NewGuid()}/accept", null)).StatusCode);
    }

    [Fact]
    public async Task Tenant_admin_cannot_be_branch_scoped()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.PostAsJsonAsync("/api/v1/members", new { email = await EmailOfAsync(await CreateUserAsync("scopedadmin")), role = "tenant_admin", branchId = AlphaMain });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
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

    [Fact]
    public async Task The_last_active_admin_cannot_be_removed()
    {
        var hospital = await ATz.NewTenantAsync(factory);
        var peer = await CreateUserAsync("last-admin-peer", (hospital.TenantId, null, "tenant_admin"));
        using var admin = factory.ClientAs(peer, hospital.TenantId);
        var members = (await admin.GetFromJsonAsync<List<MemberView>>("/api/v1/members"))!;
        var original = Assert.Single(members, m => m.UserId == hospital.AdminId);
        var demoted = await admin.PatchAsJsonAsync($"/api/v1/members/{original.Id}", new { role = "doctor" });
        Assert.Equal(HttpStatusCode.OK, demoted.StatusCode);

        var self = Assert.Single(members, m => m.UserId == peer);
        var removed = await admin.DeleteAsync($"/api/v1/members/{self.Id}");
        Assert.Equal(HttpStatusCode.Conflict, removed.StatusCode);
        using var doc = JsonDocument.Parse(await removed.Content.ReadAsStringAsync());
        Assert.Equal("last_admin", doc.RootElement.GetProperty("code").GetString());
        Assert.Contains("last active admin", doc.RootElement.GetProperty("detail").GetString(), StringComparison.OrdinalIgnoreCase);
    }
}
