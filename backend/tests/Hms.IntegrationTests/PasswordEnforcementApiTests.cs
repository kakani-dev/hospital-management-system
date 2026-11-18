using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.IntegrationTests.AuditTz;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Server-enforced must-change-password and token revocation after an admin reset. Synthetic Zz-QA users only.</summary>
[Trait("Category", "Database")]
public sealed class PasswordEnforcementApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static async Task<(Guid UserId, Guid MembershipId)> NewAlphaStaffAsync()
    {
        var userId = Guid.NewGuid();
        await ATz.ScalarAsync<object>("insert into auth.users (id, email) values (@id, @email)",
            ("id", userId), ("email", $"zz-qa-enforce-{userId:N}@synthetic.example"));
        var membershipId = await ATz.ScalarAsync<Guid>(
            "insert into identity.memberships (tenant_id, user_id, role, status) values (@t, @u, 'nurse', 'active') returning id",
            ("t", Alpha), ("u", userId));
        return (userId, membershipId);
    }

    [Fact]
    public async Task After_an_admin_set_password_only_change_password_works_until_it_is_changed()
    {
        var (userId, membershipId) = await NewAlphaStaffAsync();
        using (var admin = factory.ClientAs(AlphaAdmin, Alpha))
        {
            Assert.Equal(HttpStatusCode.NoContent,
                (await admin.PostAsJsonAsync($"/api/v1/members/{membershipId}/password", new { password = "Synthetic123x" })).StatusCode);
        }

        await Task.Delay(1100); // a token issued after the reset (iat is in whole seconds)
        using var user = factory.ClientAs(userId, Alpha);
        var blocked = await user.GetAsync("/api/v1/me");
        Assert.Equal(HttpStatusCode.Forbidden, blocked.StatusCode);
        Assert.Contains("password_change_required", await blocked.Content.ReadAsStringAsync());

        Assert.Equal(HttpStatusCode.BadRequest,
            (await user.PostAsJsonAsync("/api/v1/me/password", new { password = "short1" })).StatusCode);
        var changed = await user.PostAsJsonAsync("/api/v1/me/password", new { password = "ZzOwnChoice2026" });
        Assert.Equal(HttpStatusCode.OK, changed.StatusCode);
        var tokens = await ReadSessionAsync(changed);
        Assert.False(string.IsNullOrWhiteSpace(tokens.AccessToken));
        Assert.False(string.IsNullOrWhiteSpace(tokens.RefreshToken));

        using var fresh = factory.ClientWithToken(tokens.AccessToken);
        Assert.Equal(HttpStatusCode.OK, (await fresh.GetAsync("/api/v1/me")).StatusCode);
        // The token that completed the change is now past the cutoff.
        Assert.Equal(HttpStatusCode.Unauthorized, (await user.GetAsync("/api/v1/me")).StatusCode);
        Assert.False(await ATz.ScalarAsync<bool>(
            "select coalesce((raw_app_meta_data ->> 'must_change_password')::boolean, false) from auth.users where id = @u", ("u", userId)));
    }

    [Fact]
    public async Task A_token_issued_before_the_reset_is_revoked()
    {
        var (userId, membershipId) = await NewAlphaStaffAsync();
        using var oldSession = factory.ClientAs(userId, Alpha);
        Assert.Equal(HttpStatusCode.OK, (await oldSession.GetAsync("/api/v1/me")).StatusCode);

        await Task.Delay(1100);
        using (var admin = factory.ClientAs(AlphaAdmin, Alpha))
        {
            Assert.Equal(HttpStatusCode.NoContent,
                (await admin.PostAsJsonAsync($"/api/v1/members/{membershipId}/password", new { password = "Synthetic123x" })).StatusCode);
        }

        var revoked = await oldSession.GetAsync("/api/v1/me");
        Assert.Equal(HttpStatusCode.Unauthorized, revoked.StatusCode);
        Assert.Contains("session_revoked", await revoked.Content.ReadAsStringAsync());
        // Even the change-password call: the old token must not be usable at all.
        Assert.Equal(HttpStatusCode.Unauthorized,
            (await oldSession.PostAsJsonAsync("/api/v1/me/password", new { password = "ZzOwnChoice2026" })).StatusCode);
    }

    [Fact]
    public async Task Changing_own_password_revokes_other_sessions_and_returns_tokens_for_this_one()
    {
        var (userId, _) = await NewAlphaStaffAsync();
        var sessionId = Guid.NewGuid();
        await ATz.ScalarAsync<object>("insert into auth.sessions (id, user_id) values (@id, @u)", ("id", sessionId), ("u", userId));
        await ATz.ScalarAsync<object>(
            "insert into auth.refresh_tokens (token, user_id, session_id) values (@t, @u, @s)",
            ("t", $"zz-qa-rt-{userId:N}"),
            ("u", userId.ToString()),
            ("s", sessionId));

        using var other = factory.ClientAs(userId, Alpha);
        using var current = factory.ClientAs(userId, Alpha);
        Assert.Equal(HttpStatusCode.OK, (await other.GetAsync("/api/v1/me")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await current.GetAsync("/api/v1/me")).StatusCode);

        var changed = await current.PostAsJsonAsync("/api/v1/me/password", new { password = "ZzOwnChoice2026" });
        Assert.Equal(HttpStatusCode.OK, changed.StatusCode);
        var tokens = await ReadSessionAsync(changed);

        var revoked = await other.GetAsync("/api/v1/me");
        Assert.Equal(HttpStatusCode.Unauthorized, revoked.StatusCode);
        Assert.Contains("session_revoked", await revoked.Content.ReadAsStringAsync());
        Assert.Equal(HttpStatusCode.Unauthorized, (await current.GetAsync("/api/v1/me")).StatusCode);

        using var fresh = factory.ClientWithToken(tokens.AccessToken);
        Assert.Equal(HttpStatusCode.OK, (await fresh.GetAsync("/api/v1/me")).StatusCode);

        Assert.Equal(0, await ATz.ScalarAsync<long>(
            "select count(*) from auth.refresh_tokens where user_id = @u", ("u", userId.ToString())));
        Assert.Equal(0, await ATz.ScalarAsync<long>(
            "select count(*) from auth.sessions where user_id = @u", ("u", userId)));
    }

    [Fact]
    public async Task Users_cannot_write_the_server_flag_table()
    {
        Assert.False(await ATz.ScalarAsync<bool>("select has_table_privilege('authenticated', 'identity.user_security', 'update')"));
        Assert.False(await ATz.ScalarAsync<bool>("select has_table_privilege('authenticated', 'identity.user_security', 'insert')"));
    }

    private static async Task<PasswordChangeSessionJson> ReadSessionAsync(HttpResponseMessage response)
    {
        var tokens = await response.Content.ReadFromJsonAsync<PasswordChangeSessionJson>(JsonOptions);
        Assert.NotNull(tokens);
        return tokens;
    }

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private sealed record PasswordChangeSessionJson(string AccessToken, string RefreshToken, int ExpiresIn, string TokenType)
    {
        public override string ToString() => $"{nameof(PasswordChangeSessionJson)} {{ ExpiresIn = {ExpiresIn}, TokenType = {TokenType} }}";
    }
}
