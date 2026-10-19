using System.Net;
using System.Net.Http.Json;
using Hms.IntegrationTests.AuditTz;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Level1;

public sealed record L1Member(Guid Id, Guid UserId, string Role, Guid? BranchId, string Status);

/// <summary>Level 1: tenant admins move staff between branches or make them tenant-wide (PATCH /members/{id}).</summary>
[Trait("Category", "Database")]
public sealed class MemberBranchScopeApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Admin_moves_a_member_between_branches_within_the_tenant_only()
    {
        var userId = await CreateUserAsync("l1-scope", (Alpha, AlphaMain, "nurse"));
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var member = (await admin.GetFromJsonAsync<List<L1Member>>("/api/v1/members"))!.Single(m => m.UserId == userId);
        Assert.Equal(AlphaMain, member.BranchId);

        var moved = await ATz.ReadAsync<L1Member>(await admin.PatchAsJsonAsync($"/api/v1/members/{member.Id}", new { branchId = AlphaEast }), HttpStatusCode.OK);
        Assert.Equal(AlphaEast, moved.BranchId);
        using (var nurse = factory.ClientAs(userId, Alpha))
        {
            var me = (await nurse.GetFromJsonAsync<L1Me>("/api/v1/me"))!;
            Assert.Equal(Alpha, me.ActiveTenantId);
        }

        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync($"/api/v1/members/{member.Id}", new { branchId = BetaMain })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync($"/api/v1/members/{member.Id}", new { role = "tenant_admin" })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync($"/api/v1/members/{member.Id}", new { branchId = AlphaMain, allBranches = true })).StatusCode);
        var wide = await ATz.ReadAsync<L1Member>(await admin.PatchAsJsonAsync($"/api/v1/members/{member.Id}", new { allBranches = true }), HttpStatusCode.OK);
        Assert.Null(wide.BranchId);
        Assert.Null(await ATz.ScalarAsync<Guid?>("select branch_id from identity.memberships where id = @id", ("id", member.Id)));

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PatchAsJsonAsync($"/api/v1/members/{member.Id}", new { branchId = BetaMain })).StatusCode);
    }
}
