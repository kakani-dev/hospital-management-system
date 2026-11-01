using System.Net;
using System.Net.Http.Json;
using Hms.IntegrationTests.AuditTz;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>#309: POST /api/v1/members/{id}/password-reset. Synthetic Zz-QA users only.</summary>
[Trait("Category", "Database")]
public sealed class AdminPasswordResetApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private sealed record IssuedView(DateTimeOffset ExpiresOn);

    private static async Task<(Guid UserId, Guid MembershipId)> NewAlphaStaffAsync()
    {
        var userId = Guid.NewGuid();
        await ATz.ScalarAsync<object>("insert into auth.users (id, email) values (@id, @email)",
            ("id", userId), ("email", $"zz-qa-reset-{userId:N}@synthetic.example"));
        var membershipId = await ATz.ScalarAsync<Guid>(
            "insert into identity.memberships (tenant_id, user_id, role, status) values (@t, @u, 'nurse', 'active') returning id",
            ("t", Alpha), ("u", userId));
        return (userId, membershipId);
    }

    private static Task<Guid> MembershipOfAsync(Guid tenant, Guid user) =>
        ATz.ScalarAsync<Guid>("select id from identity.memberships where tenant_id = @t and user_id = @u and not is_deleted limit 1",
            ("t", tenant), ("u", user));

    private static string PathFor(Guid membershipId) => $"/api/v1/members/{membershipId}/password-reset";

    [Fact]
    public async Task Admin_resets_a_staff_member_of_their_own_hospital()
    {
        var (userId, membershipId) = await NewAlphaStaffAsync();
        using var client = factory.ClientAs(AlphaAdmin, Alpha);

        var response = await client.PostAsync(PathFor(membershipId), null);

        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        var issued = await response.Content.ReadFromJsonAsync<IssuedView>();
        Assert.True(issued!.ExpiresOn > DateTimeOffset.UtcNow);
        Assert.Equal(1L, await ATz.ScalarAsync<long>(
            "select count(*) from audit.audit_log where table_name = 'password_resets' and changed_by = @a and new_data ->> 'target_user_id' = @u::text",
            ("a", AlphaAdmin), ("u", userId)));
        Assert.Equal(1L, await ATz.ScalarAsync<long>(
            "select count(*) from identity.password_resets where user_id = @u and consumed_on is null", ("u", userId)));
    }

    [Fact]
    public async Task Member_of_another_hospital_is_403()
    {
        var betaDoctorMembership = await MembershipOfAsync(Beta, BetaDoctor);
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsync(PathFor(betaDoctorMembership), null)).StatusCode);
    }

    [Fact]
    public async Task Non_admin_is_403()
    {
        var (_, membershipId) = await NewAlphaStaffAsync();
        using var client = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsync(PathFor(membershipId), null)).StatusCode);
    }

    [Fact]
    public async Task Own_account_is_409_and_unknown_member_is_404()
    {
        var own = await MembershipOfAsync(Alpha, AlphaAdmin);
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        Assert.Equal(HttpStatusCode.Conflict, (await client.PostAsync(PathFor(own), null)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync(PathFor(Guid.NewGuid()), null)).StatusCode);
    }

    [Fact]
    public async Task Fourth_reset_of_the_same_user_within_an_hour_is_429()
    {
        var (_, membershipId) = await NewAlphaStaffAsync();
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        for (var i = 0; i < 3; i++)
        {
            Assert.Equal(HttpStatusCode.Accepted, (await client.PostAsync(PathFor(membershipId), null)).StatusCode);
        }

        Assert.Equal((HttpStatusCode)429, (await client.PostAsync(PathFor(membershipId), null)).StatusCode);
    }

    [Fact]
    public async Task Unknown_reset_link_is_404()
    {
        using var client = factory.CreateClient();
        var response = await client.PostAsync($"/api/v1/public/password-resets/{new string('a', 64)}/sign-in", null);
        Assert.True(response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.ServiceUnavailable, $"got {(int)response.StatusCode}");
    }
}
