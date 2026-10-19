using System.Net;
using System.Net.Http.Json;
using Hms.IntegrationTests.AuditTz;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Level1;

public sealed record L1Invite(Guid Id, string Token, string Path, DateTimeOffset ExpiresOn);

public sealed record L1Approved(Guid TenantId, L1Invite Invite);

public sealed record L1Tenant(Guid Id, string Code, string Name, string Status, string TimeZone, long BranchCount, long UserCount, long PendingInvites, string? StatusReason);

public sealed record L1TenantDetail(L1Tenant Tenant, List<L1History> History);

public sealed record L1History(string FromStatus, string ToStatus, string Reason);

public sealed record L1Request(Guid Id, string HospitalName, string TimeZone, string ContactEmail, string Status, string? DecisionReason, Guid? TenantId);

public sealed record L1Claimed(Guid TenantId, string TenantName, string Role, Guid? BranchId);

public sealed record L1Me(Guid? ActiveTenantId, List<string> Roles, bool IsPlatformAdmin);

public sealed record L1Link(Guid Id, string Email, string Role, Guid? BranchId, string Status);

/// <summary>
/// Level 1 platform console + approval-based onboarding (identity service only; the monolith has none,
/// code review MIN-5). The synthetic operator comes from supabase/scripts/local-platform-operator-seed.sql.
/// </summary>
[Trait("Category", "Database")]
public sealed class PlatformConsoleApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    public static readonly Guid Operator = Guid.Parse("0e900000-0000-4000-8000-000000000001");

    private static bool Skip => Target == SystemTarget.Monolith;

    [Fact]
    public async Task The_monolith_serves_no_platform_or_public_endpoints()
    {
        if (!Skip)
        {
            return;
        }

        using var op = factory.ClientAs(Operator);
        Assert.Equal(HttpStatusCode.NotFound, (await op.GetAsync("/api/v1/platform/tenants")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await factory.CreateClient().PostAsJsonAsync("/api/v1/public/hospital-signups", new { })).StatusCode);
    }

    [Fact]
    public async Task Platform_endpoints_need_a_platform_admin()
    {
        if (Skip)
        {
            return;
        }

        Assert.Equal(HttpStatusCode.Unauthorized, (await factory.CreateClient().GetAsync("/api/v1/platform/tenants")).StatusCode);
        foreach (var (user, tenant) in new[] { (AlphaAdmin, (Guid?)Alpha), (BetaDoctor, Beta), (AlphaReception, Alpha) })
        {
            using var client = factory.ClientAs(user, tenant);
            Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/platform/tenants")).StatusCode);
            Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/platform/hospital-requests")).StatusCode);
            Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsJsonAsync($"/api/v1/platform/tenants/{Beta}/suspend", new { reason = "cross-tenant attack" })).StatusCode);
            Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsJsonAsync("/api/v1/platform/tenants", new { code = ATz.Code("l1x"), name = "Evil", timeZone = "UTC", adminEmail = "x@evil.example" })).StatusCode);
        }

        Assert.Equal("active", await ATz.ScalarAsync<string>("select status from identity.tenants where id = @t", ("t", Beta)));
        using var me = factory.ClientAs(AlphaAdmin, Alpha);
        Assert.False((await me.GetFromJsonAsync<L1Me>("/api/v1/me"))!.IsPlatformAdmin);
    }

    [Fact]
    public async Task A_platform_admin_has_no_implicit_tenant_access()
    {
        if (Skip)
        {
            return;
        }

        using var op = factory.ClientAs(Operator);
        var me = (await op.GetFromJsonAsync<L1Me>("/api/v1/me"))!;
        Assert.True(me.IsPlatformAdmin);
        Assert.Null(me.ActiveTenantId);
        var tenants = (await op.GetFromJsonAsync<List<L1Tenant>>("/api/v1/platform/tenants?search=demo-alpha"))!;
        Assert.Contains(tenants, t => t.Id == Alpha && t.BranchCount >= 2 && t.UserCount >= 1);

        // even with a forged tenant claim the operator resolves no tenant: patient / scheduling / admin data stay closed
        using var forged = factory.ClientAs(Operator, Alpha);
        foreach (var path in new[] { "/api/v1/patients", $"/api/v1/patients/{AlphaPatientId}", "/api/v1/patients/stats", "/api/v1/appointments?branchId=" + AlphaMain,
                     "/api/v1/queue?branchId=" + AlphaMain, "/api/v1/members", "/api/v1/tenants/current", "/api/v1/practitioners" })
        {
            Assert.Equal(HttpStatusCode.Forbidden, (await op.GetAsync(path)).StatusCode);
            Assert.Equal(HttpStatusCode.Forbidden, (await forged.GetAsync(path)).StatusCode);
        }
    }

    [Fact]
    public async Task Public_signup_is_pending_only_then_approval_issues_a_claimable_admin_invite()
    {
        if (Skip)
        {
            return;
        }

        var anon = factory.CreateClient();
        var applicantId = await CreateUserAsync("l1-applicant");
        var email = await EmailOfAsync(applicantId);
        var name = $"L1 Hospital {Guid.NewGuid():N}"[..28];

        Assert.Equal(HttpStatusCode.BadRequest, (await anon.PostAsJsonAsync("/api/v1/public/hospital-signups",
            new { hospitalName = name, timeZone = "IST", contactName = "Asha", contactEmail = email, phone = "+91 555 0100", city = "Pune" })).StatusCode);
        var honeypot = await anon.PostAsJsonAsync("/api/v1/public/hospital-signups",
            new { hospitalName = name + " bot", timeZone = "Asia/Kolkata", contactName = "Bot", contactEmail = "bot@spam.example", phone = "+91 555 0100", city = "Pune", website = "http://spam.example" });
        Assert.Equal(HttpStatusCode.Accepted, honeypot.StatusCode);
        var accepted = await anon.PostAsJsonAsync("/api/v1/public/hospital-signups",
            new { hospitalName = name, timeZone = "Asia/Calcutta", contactName = "Asha Synthetic", contactEmail = email.ToUpperInvariant(), phone = "+91 555 0100 200", city = "Pune" });
        Assert.Equal(HttpStatusCode.Accepted, accepted.StatusCode);
        Assert.Equal(await honeypot.Content.ReadAsStringAsync(), await accepted.Content.ReadAsStringAsync());
        Assert.Equal(0L, await ATz.ScalarAsync<long>("select count(*) from identity.tenant_signup_requests where hospital_name = @n", ("n", name + " bot")));

        // pending: zero access for the applicant, and no tenant
        Assert.Equal(0L, await ATz.ScalarAsync<long>("select count(*) from identity.tenants where name = @n", ("n", name)));
        using (var applicant = factory.ClientAs(applicantId))
        {
            var me = (await applicant.GetFromJsonAsync<L1Me>("/api/v1/me"))!;
            Assert.Null(me.ActiveTenantId);
            Assert.Empty(me.Roles);
            Assert.Equal(HttpStatusCode.Forbidden, (await applicant.GetAsync("/api/v1/patients")).StatusCode);
            Assert.Equal(HttpStatusCode.Forbidden, (await applicant.GetAsync("/api/v1/platform/hospital-requests")).StatusCode);
        }

        using var op = factory.ClientAs(Operator);
        var request = (await op.GetFromJsonAsync<List<L1Request>>("/api/v1/platform/hospital-requests?status=pending"))!.Single(r => r.HospitalName == name);
        Assert.Equal("Asia/Kolkata", request.TimeZone);
        Assert.Equal(email, request.ContactEmail);
        Assert.Equal(HttpStatusCode.BadRequest, (await op.PostAsJsonAsync($"/api/v1/platform/hospital-requests/{request.Id}/approve", new { tenantCode = "Bad Code" })).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await op.PostAsJsonAsync($"/api/v1/platform/hospital-requests/{request.Id}/approve", new { tenantCode = "demo-alpha" })).StatusCode);
        var code = ATz.Code("l1");
        var approved = await ATz.ReadAsync<L1Approved>(await op.PostAsJsonAsync($"/api/v1/platform/hospital-requests/{request.Id}/approve", new { tenantCode = code }), HttpStatusCode.OK);
        Assert.Equal($"/invite/{approved.Invite.Token}", approved.Invite.Path);
        Assert.Equal(HttpStatusCode.Conflict, (await op.PostAsJsonAsync($"/api/v1/platform/hospital-requests/{request.Id}/reject", new { reason = "too late" })).StatusCode);
        Assert.Equal("Asia/Kolkata", await ATz.ScalarAsync<string>("select time_zone from identity.tenants where id = @t", ("t", approved.TenantId)));

        // the invite page preview (anonymous), a wrong-email claim, then the real claim
        Assert.Equal(HttpStatusCode.OK, (await anon.GetAsync($"/api/v1/public/invites/{approved.Invite.Token}")).StatusCode);
        using (var other = factory.ClientAs(BetaDoctor, Beta))
        {
            var wrong = await other.PostAsJsonAsync("/api/v1/me/invite-links/claim", new { token = approved.Invite.Token });
            Assert.Equal(HttpStatusCode.Forbidden, wrong.StatusCode);
            Assert.Equal("invite_email_mismatch", await ATz.CodeAsync(wrong));
        }

        using var admin = factory.ClientAs(applicantId, approved.TenantId);
        Assert.Equal(HttpStatusCode.Forbidden, (await admin.GetAsync("/api/v1/tenants/current")).StatusCode); // approved but unclaimed: still nothing
        var claimed = await ATz.ReadAsync<L1Claimed>(await admin.PostAsJsonAsync("/api/v1/me/invite-links/claim", new { token = approved.Invite.Token }), HttpStatusCode.OK);
        Assert.Equal(("tenant_admin", approved.TenantId), (claimed.Role, claimed.TenantId));
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsJsonAsync("/api/v1/me/invite-links/claim", new { token = approved.Invite.Token })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync("/api/v1/tenants/current")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync("/api/v1/branches")).StatusCode);

        // suspended tenant: its users are blocked at grant time; reactivation restores access
        Assert.Equal(HttpStatusCode.BadRequest, (await op.PostAsJsonAsync($"/api/v1/platform/tenants/{approved.TenantId}/suspend", new { reason = "" })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await op.PostAsJsonAsync($"/api/v1/platform/tenants/{approved.TenantId}/suspend", new { reason = "Synthetic suspension" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await admin.GetAsync("/api/v1/tenants/current")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await admin.PostAsJsonAsync("/api/v1/me/context", new { tenantId = approved.TenantId })).StatusCode);
        Assert.Null((await admin.GetFromJsonAsync<L1Me>("/api/v1/me"))!.ActiveTenantId);
        Assert.Equal(HttpStatusCode.Conflict, (await op.PostAsJsonAsync($"/api/v1/platform/tenants/{approved.TenantId}/suspend", new { reason = "again" })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await op.PostAsJsonAsync($"/api/v1/platform/tenants/{approved.TenantId}/reactivate", new { reason = "Synthetic reinstatement" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync("/api/v1/tenants/current")).StatusCode);

        var detail = (await op.GetFromJsonAsync<L1TenantDetail>($"/api/v1/platform/tenants/{approved.TenantId}"))!;
        Assert.Equal(("active", 1L, 1L, 0L), (detail.Tenant.Status, detail.Tenant.BranchCount, detail.Tenant.UserCount, detail.Tenant.PendingInvites));
        Assert.Equal(["active", "suspended"], detail.History.Select(h => h.ToStatus));
    }

    [Fact]
    public async Task Operator_creates_a_tenant_directly_and_rejects_requests_with_a_reason()
    {
        if (Skip)
        {
            return;
        }

        using var op = factory.ClientAs(Operator);
        var bad = await op.PostAsJsonAsync("/api/v1/platform/tenants", new { code = "x", name = "", timeZone = "Mars/Base", adminEmail = "nope" });
        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
        var body = await bad.Content.ReadAsStringAsync();
        foreach (var field in new[] { "code", "name", "timeZone", "adminEmail" })
        {
            Assert.Contains($"\"{field}\"", body, StringComparison.Ordinal);
        }

        var code = ATz.Code("l1d");
        var created = await ATz.ReadAsync<L1Approved>(await op.PostAsJsonAsync("/api/v1/platform/tenants",
            new { code, name = "L1 Direct (synthetic)", timeZone = "Europe/London", adminEmail = "boss@l1-direct.example" }), HttpStatusCode.Created);
        var tenant = (await op.GetFromJsonAsync<List<L1Tenant>>($"/api/v1/platform/tenants?search={code}"))!.Single();
        Assert.Equal(("Europe/London", 1L, 0L, 1L), (tenant.TimeZone, tenant.BranchCount, tenant.UserCount, tenant.PendingInvites));
        var reissued = await ATz.ReadAsync<L1Invite>(await op.PostAsJsonAsync($"/api/v1/platform/tenants/{created.TenantId}/admin-invite", new { email = "boss@l1-direct.example" }), HttpStatusCode.OK);
        Assert.NotEqual(created.Invite.Token, reissued.Token);
        Assert.Equal(HttpStatusCode.NotFound, (await factory.CreateClient().GetAsync($"/api/v1/public/invites/{created.Invite.Token}")).StatusCode); // superseded

        var anon = factory.CreateClient();
        var name = $"L1 Reject {Guid.NewGuid():N}"[..26];
        Assert.Equal(HttpStatusCode.Accepted, (await anon.PostAsJsonAsync("/api/v1/public/hospital-signups",
            new { hospitalName = name, timeZone = "UTC", contactName = "Spam Synthetic", contactEmail = $"{Guid.NewGuid():N}@reject.example", phone = "+1 555 0100", city = "Nowhere" })).StatusCode);
        var request = (await op.GetFromJsonAsync<List<L1Request>>("/api/v1/platform/hospital-requests"))!.Single(r => r.HospitalName == name);
        Assert.Equal(HttpStatusCode.BadRequest, (await op.PostAsJsonAsync($"/api/v1/platform/hospital-requests/{request.Id}/reject", new { reason = "x" })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await op.PostAsJsonAsync($"/api/v1/platform/hospital-requests/{request.Id}/reject", new { reason = "Not a hospital (synthetic)" })).StatusCode);
        var rejected = (await op.GetFromJsonAsync<List<L1Request>>("/api/v1/platform/hospital-requests?status=rejected"))!.Single(r => r.Id == request.Id);
        Assert.Equal(("rejected", "Not a hospital (synthetic)", (Guid?)null), (rejected.Status, rejected.DecisionReason, rejected.TenantId));
    }

    [Fact]
    public async Task Tenant_admins_issue_list_and_revoke_staff_invite_links_within_their_tenant_only()
    {
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        var email = $"l1-staff-{Guid.NewGuid():N}@synthetic.example";
        Assert.Equal(HttpStatusCode.BadRequest, (await alpha.PostAsJsonAsync("/api/v1/members/invite-links", new { email, role = "tenant_admin", branchId = AlphaEast })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await alpha.PostAsJsonAsync("/api/v1/members/invite-links", new { email, role = "nurse", branchId = BetaMain })).StatusCode);
        var link = await ATz.ReadAsync<L1Invite>(await alpha.PostAsJsonAsync("/api/v1/members/invite-links", new { email, role = "nurse", branchId = AlphaEast }), HttpStatusCode.Created);
        Assert.Contains((await alpha.GetFromJsonAsync<List<L1Link>>("/api/v1/members/invite-links"))!, l => l.Id == link.Id && l.Status == "pending" && l.BranchId == AlphaEast);

        using var reception = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.GetAsync("/api/v1/members/invite-links")).StatusCode);
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.DoesNotContain((await beta.GetFromJsonAsync<List<L1Link>>("/api/v1/members/invite-links"))!, l => l.Id == link.Id);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.DeleteAsync($"/api/v1/members/invite-links/{link.Id}")).StatusCode);

        // the invitee (account created later, like a GoTrue sign-up) claims it and lands branch-scoped
        var staffId = await CreateUserWithEmailAsync(email);
        using var staff = factory.ClientAs(staffId);
        var claimed = await ATz.ReadAsync<L1Claimed>(await staff.PostAsJsonAsync("/api/v1/me/invite-links/claim", new { token = link.Token }), HttpStatusCode.OK);
        Assert.Equal(("nurse", (Guid?)AlphaEast, Alpha), (claimed.Role, claimed.BranchId, claimed.TenantId));
        Assert.Equal(HttpStatusCode.NotFound, (await alpha.DeleteAsync($"/api/v1/members/invite-links/{link.Id}")).StatusCode); // already used

        var second = await ATz.ReadAsync<L1Invite>(await alpha.PostAsJsonAsync("/api/v1/members/invite-links", new { email = $"l1-x-{Guid.NewGuid():N}@synthetic.example", role = "viewer" }), HttpStatusCode.Created);
        Assert.Equal(HttpStatusCode.NoContent, (await alpha.DeleteAsync($"/api/v1/members/invite-links/{second.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await factory.CreateClient().GetAsync($"/api/v1/public/invites/{second.Token}")).StatusCode);
    }

    private static async Task<Guid> CreateUserWithEmailAsync(string email)
    {
        var id = Guid.NewGuid();
        await ATz.ScalarAsync<object>("insert into auth.users (id, email) values (@id, @email)", ("id", id), ("email", email));
        return id;
    }
}
