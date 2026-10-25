using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Pr1Regression;

/// <summary>
/// PR #1 review finding B1: add_member created an ACTIVE membership for any platform user without
/// consent, which then silently became the victim's default tenant, and the 404/409/201 responses
/// enabled platform-wide email enumeration.
///
/// Contract (FIX-PLAN.md incl. the 21:16 IST update): POST /api/v1/members always answers 202
/// with one fixed message (no-account, invited, already-member); memberships start 'invited' and
/// grant nothing; pending invites are hidden from admins (not listed, PATCH 404) and the DB keeps
/// them out of admin-visible RLS / is_admin_of_member and blocks admins from activating them;
/// only the invitee can accept (204, else 404), also without any tenant; invited memberships never
/// count for the default tenant (membership age order, first resolution persisted).
///
/// Backend's TenantAdminApiTests (fix/pr1-backend @ 2a3fd19) already cover the basic flow
/// (unknown == known 202 body, invited -> patients 403, hidden from GET /members, admin PATCH
/// status=active 404, another member's accept 404, accept 204 / second accept 404 / access after
/// accept, default tenant unchanged via /tenants/current, empty invitation list without a tenant,
/// tenant_admin+branch 400). This class only adds the gaps; see the PR #1 QA report.
/// </summary>
[Trait("Category", "Database")]
public sealed class B1MembershipConsentApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid AlphaEastPatientId = Guid.Parse("aa000000-0000-4000-8000-000000000003");

    private static string NoAccountEmail() => $"nobody-{Guid.NewGuid():N}@synthetic.example";

    private sealed record ResponseShape(HttpStatusCode Status, string? MediaType, string Body, string HeaderNames);

    private static async Task<ResponseShape> ShapeOf(HttpResponseMessage response)
    {
        // Everything an attacker can observe, minus values that legitimately vary per request.
        var volatileHeaders = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Date", "Content-Length", "X-Correlation-Id", "X-Request-Id", "traceparent" };
        var names = response.Headers.Select(h => h.Key)
            .Concat(response.Content.Headers.Select(h => h.Key))
            .Where(n => !volatileHeaders.Contains(n))
            .Select(n => n.ToUpperInvariant())
            .Order(StringComparer.Ordinal);
        return new ResponseShape(
            response.StatusCode,
            response.Content.Headers.ContentType?.MediaType,
            await response.Content.ReadAsStringAsync(),
            string.Join(",", names));
    }

    private static void AssertIsUniformInviteResponse(ResponseShape shape)
    {
        Assert.Equal(HttpStatusCode.Accepted, shape.Status);
        using var doc = JsonDocument.Parse(shape.Body);
        var message = Assert.Single(doc.RootElement.EnumerateObject().ToList());
        Assert.Equal("message", message.Name);
        Assert.Equal(Pr1Contract.InviteMessage, message.Value.GetString());
    }

    /// <summary>ProblemDetails carry a per-request traceId; everything else must match.</summary>
    private static string WithoutTraceId(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var rest = doc.RootElement.EnumerateObject()
            .Where(p => !string.Equals(p.Name, "traceId", StringComparison.Ordinal))
            .ToDictionary(p => p.Name, p => p.Value.GetRawText(), StringComparer.Ordinal);
        return JsonSerializer.Serialize(rest);
    }

    private async Task<HttpResponseMessage> InviteAsync(string email, string role = "doctor", Guid? branchId = null)
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        return await admin.PostAsJsonAsync(Pr1Contract.Members, new { email, role, branchId });
    }

    private async Task<Guid> InviteVictimAsync(Guid victim, string role = "doctor", Guid? branchId = null)
    {
        AssertIsUniformInviteResponse(await ShapeOf(await InviteAsync(await EmailOfAsync(victim), role, branchId)));
        var row = Assert.Single(await Pr1Db.MembershipsAsync(Alpha, victim));
        Assert.Equal("invited", row.Status);
        return row.Id;
    }

    [Fact]
    public async Task B1_invite_response_is_identical_for_no_account_existing_user_already_invited_case_variant_and_active_member()
    {
        var victim = await CreateUserAsync("b1-enum-victim", (Beta, null, "doctor"));
        var victimEmail = await EmailOfAsync(victim);
        var member = await CreateUserAsync("b1-enum-member", (Alpha, AlphaEast, "nurse"));

        var noAccount = await ShapeOf(await InviteAsync(NoAccountEmail()));
        var existingUser = await ShapeOf(await InviteAsync(victimEmail));
        var alreadyInvited = await ShapeOf(await InviteAsync(victimEmail));
        var differentCase = await ShapeOf(await InviteAsync(victimEmail.ToUpperInvariant()));
        var activeMember = await ShapeOf(await InviteAsync(await EmailOfAsync(member), "nurse", AlphaEast));

        AssertIsUniformInviteResponse(noAccount);
        // Indistinguishable: same status, media type, exact body bytes and the same set of headers.
        Assert.Equal(noAccount, existingUser);
        Assert.Equal(noAccount, alreadyInvited);
        Assert.Equal(noAccount, differentCase);
        Assert.Equal(noAccount, activeMember);
        Assert.DoesNotContain("LOCATION", existingUser.HeaderNames, StringComparison.Ordinal);

        // State behind the uniform answer: one invited row for the outsider; the member untouched.
        Assert.Equal("invited", Assert.Single(await Pr1Db.MembershipsAsync(Alpha, victim)).Status);
        var memberRow = Assert.Single(await Pr1Db.MembershipsAsync(Alpha, member));
        Assert.Equal("active", memberRow.Status);
        Assert.Equal("nurse", memberRow.Role);
    }

    [Fact]
    public async Task B1_default_tenant_unchanged_in_me_header_hook_claim_and_persisted_profile()
    {
        // (1) Victim who already resolved a context once (the first resolution is persisted).
        var resolved = await CreateUserAsync("b1-default-resolved", (Beta, null, "doctor"));
        using var asResolved = factory.ClientAs(resolved);
        Assert.Equal(HttpStatusCode.OK, (await asResolved.GetAsync("/api/v1/tenants/current")).StatusCode);
        Assert.Equal(Beta, await Pr1Db.PersistedActiveTenantAsync(resolved));

        // (2) Victim who never signed in: the pending invite must not win the FIRST resolution either.
        var fresh = await CreateUserAsync("b1-default-fresh", (Beta, null, "doctor"));

        // "Demo Alpha Hospital" sorts before "Demo Beta Clinic": the original bug moved victims to Alpha.
        await InviteVictimAsync(resolved);
        await InviteVictimAsync(fresh);

        foreach (var victim in new[] { resolved, fresh })
        {
            // The next token the custom access token hook issues still carries Beta...
            Assert.Equal(Beta.ToString(), await Pr1Db.HookTenantClaimAsync(victim), ignoreCase: true);

            // ...and so does the API's server-side fallback (no tenant claim), header included.
            using var client = factory.ClientAs(victim);
            var response = await client.GetAsync("/api/v1/me");
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.Equal(Beta.ToString(), Assert.Single(response.Headers.GetValues(Pr1Contract.TenantHeader)), ignoreCase: true);
            var me = await response.Content.ReadFromJsonAsync<MeView>();
            Assert.Equal(Beta, me!.ActiveTenantId);
            Assert.DoesNotContain(me.AccessibleBranches, b => b.Id == AlphaMain || b.Id == AlphaEast);
            Assert.DoesNotContain(me.Memberships, m => m.TenantId == Alpha);
            Assert.Equal(Beta, await Pr1Db.PersistedActiveTenantAsync(victim));
        }
    }

    [Fact]
    public async Task B1_pending_invitation_grants_nothing_in_the_inviting_tenant()
    {
        var victim = await CreateUserAsync("b1-noaccess-victim", (Beta, null, "doctor"));
        await InviteVictimAsync(victim);

        // A token claiming Alpha (stale/forged claim, or a hook that wrongly counted the invite).
        using var claimingAlpha = factory.ClientAs(victim, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await claimingAlpha.GetAsync("/api/v1/branches")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await claimingAlpha.GetAsync("/api/v1/tenants/current")).StatusCode);
        Assert.Contains((await claimingAlpha.GetAsync($"/api/v1/patients/{AlphaPatientId}")).StatusCode, new[] { HttpStatusCode.Forbidden, HttpStatusCode.NotFound });
        var search = await claimingAlpha.PostAsJsonAsync(Pr1Contract.PatientSearch, new { search = "synthetic", page = 1, pageSize = 100 });
        Assert.Equal(HttpStatusCode.Forbidden, search.StatusCode);
        var write = await claimingAlpha.PostAsJsonAsync("/api/v1/patients", new { mrn = Pr1Db.NewMrn("B1"), firstName = "No", lastName = "Access", registeredBranchId = AlphaMain });
        Assert.Contains(write.StatusCode, new[] { HttpStatusCode.Forbidden, HttpStatusCode.NotFound });

        using var claimingAlphaMain = factory.ClientAs(victim, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await claimingAlphaMain.GetAsync("/api/v1/patients")).StatusCode);

        // Cannot switch into Alpha before accepting.
        using var asVictim = factory.ClientAs(victim);
        Assert.Equal(HttpStatusCode.Forbidden, (await asVictim.PostAsJsonAsync("/api/v1/me/context", new { tenantId = Alpha })).StatusCode);

        // Defense in depth: RLS through the API's own DB login grants nothing in Alpha either.
        await Pr1Db.AsApiRoleAsync(victim, Alpha, async (conn, tx) =>
        {
            await using var cmd = new NpgsqlCommand("select count(*) from patient.patients where tenant_id = @t", conn, tx);
            cmd.Parameters.AddWithValue("t", Alpha);
            Assert.Equal(0L, (long)(await cmd.ExecuteScalarAsync())!);
        });
    }

    [Fact]
    public async Task B1_accept_by_anyone_other_than_the_invitee_is_404()
    {
        var victim = await CreateUserAsync("b1-accept-victim", (Beta, null, "doctor"));
        var bystander = await CreateUserAsync("b1-bystander");
        var membershipId = await InviteVictimAsync(victim);

        var others = new (string Who, HttpClient Client)[]
        {
            ("the inviting tenant admin", factory.ClientAs(AlphaAdmin, Alpha)),
            ("another tenant's admin", factory.ClientAs(BetaAdmin, Beta)),
            ("a colleague of the invitee", factory.ClientAs(BetaDoctor, Beta)),
            ("a user without memberships", factory.ClientAs(Outsider)),
            ("a fresh user", factory.ClientAs(bystander)),
        };
        foreach (var (who, client) in others)
        {
            using (client)
            {
                var response = await client.PostAsync(Pr1Contract.Accept(membershipId), content: null);
                Assert.True(response.StatusCode == HttpStatusCode.NotFound, $"accept by {who}: expected 404, got {(int)response.StatusCode}");
            }
        }

        Assert.Equal("invited", Assert.Single(await Pr1Db.MembershipsAsync(Alpha, victim)).Status);
        using var claimingAlpha = factory.ClientAs(victim, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await claimingAlpha.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task B1_accepting_does_not_switch_the_default_tenant_and_reinviting_an_active_member_changes_nothing()
    {
        var victim = await CreateUserAsync("b1-accepting", (Beta, null, "doctor"));
        using var asVictim = factory.ClientAs(victim);
        Assert.Equal(Beta, (await asVictim.GetFromJsonAsync<TenantView>("/api/v1/tenants/current"))!.Id);
        var membershipId = await InviteVictimAsync(victim);

        Assert.Equal(HttpStatusCode.NoContent, (await asVictim.PostAsync(Pr1Contract.Accept(membershipId), content: null)).StatusCode);

        // Access as granted. A doctor reads the registry, and only charts linked to their own visits.
        using var claimingAlpha = factory.ClientAs(victim, Alpha);
        Assert.Equal(HttpStatusCode.OK, (await claimingAlpha.GetAsync("/api/v1/patients")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await claimingAlpha.GetAsync($"/api/v1/patients/{AlphaEastPatientId}")).StatusCode);

        // Accepting is not a context switch: the persisted default and the next token stay Beta.
        Assert.Equal(Beta, (await asVictim.GetFromJsonAsync<TenantView>("/api/v1/tenants/current"))!.Id);
        Assert.Equal(Beta, await Pr1Db.PersistedActiveTenantAsync(victim));
        Assert.Equal(Beta.ToString(), await Pr1Db.HookTenantClaimAsync(victim), ignoreCase: true);

        // Re-inviting an active member: same 202, no status change, no duplicate row.
        AssertIsUniformInviteResponse(await ShapeOf(await InviteAsync(await EmailOfAsync(victim))));
        Assert.Equal("active", Assert.Single(await Pr1Db.MembershipsAsync(Alpha, victim)).Status);
    }

    [Fact]
    public async Task B1_user_without_any_membership_can_list_and_accept_a_real_invitation()
    {
        var newcomer = await CreateUserAsync("b1-newcomer");
        await InviteVictimAsync(newcomer, "nurse", AlphaEast);

        using var asNewcomer = factory.ClientAs(newcomer);
        var invitations = await asNewcomer.GetFromJsonAsync<List<Pr1InvitationView>>(Pr1Contract.MyInvitations);
        var invite = Assert.Single(invitations!);
        Assert.Equal(Alpha, invite.TenantId);
        Assert.Equal("Demo Alpha Hospital (synthetic)", invite.TenantName);
        Assert.Equal(AlphaEast, invite.BranchId);
        Assert.Equal("nurse", invite.Role);

        Assert.Equal(HttpStatusCode.NoContent, (await asNewcomer.PostAsync(Pr1Contract.Accept(invite.MembershipId), content: null)).StatusCode);
        // First (and only) active membership => default context, persisted.
        Assert.Equal(Alpha, (await asNewcomer.GetFromJsonAsync<TenantView>("/api/v1/tenants/current"))!.Id);
        Assert.Equal(Alpha, await Pr1Db.PersistedActiveTenantAsync(newcomer));
        var me = await asNewcomer.GetFromJsonAsync<MeView>("/api/v1/me");
        Assert.Equal([AlphaEast], me!.AccessibleBranches.Select(b => b.Id).ToArray());
    }

    [Fact]
    public async Task B1_pending_invite_is_immutable_for_admins_via_any_patch()
    {
        var victim = await CreateUserAsync("b1-hidden", (Beta, null, "doctor"));
        var membershipId = await InviteVictimAsync(victim);
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);

        // API: any PATCH on a pending membership is 404 (not only status=active), nothing changes.
        foreach (var body in new object[] { new { role = "nurse" }, new { status = "suspended" }, new { status = "active" } })
        {
            var patch = await admin.PatchAsJsonAsync($"{Pr1Contract.Members}/{membershipId}", body);
            Assert.Equal(HttpStatusCode.NotFound, patch.StatusCode);
        }

        var row = Assert.Single(await Pr1Db.MembershipsAsync(Alpha, victim));
        Assert.Equal(("invited", "doctor"), (row.Status, row.Role));
    }

    /// <summary>
    /// B1 part of the DB invite fix (contract update 21:16 IST): invited rows stay out of the
    /// admin-visible RLS and is_admin_of_member, and admins cannot move invited -> active. Kept
    /// separate so it can be dropped on its own if the DB team does not ship this part now.
    /// </summary>
    [Fact]
    public async Task B1_db_keeps_pending_invites_out_of_admin_visible_rls_and_blocks_admin_activation()
    {
        var victim = await CreateUserAsync("b1-hidden-db", (Beta, null, "doctor"));
        var membershipId = await InviteVictimAsync(victim);

        // Through the API's DB login as the Alpha admin.
        await Pr1Db.AsApiRoleAsync(AlphaAdmin, Alpha, async (conn, tx) =>
        {
            await using var memberships = new NpgsqlCommand("select count(*) from identity.memberships where user_id = @u", conn, tx);
            memberships.Parameters.AddWithValue("u", victim);
            Assert.Equal(0L, (long)(await memberships.ExecuteScalarAsync())!);

            await using var profile = new NpgsqlCommand("select count(*) from identity.user_profiles where id = @u", conn, tx);
            profile.Parameters.AddWithValue("u", victim);
            Assert.Equal(0L, (long)(await profile.ExecuteScalarAsync())!);
        });
        await Pr1Db.AsApiRoleAsync(AlphaAdmin, Alpha, async (conn, tx) =>
        {
            await using var activate = new NpgsqlCommand("update identity.memberships set status = 'active' where id = @id", conn, tx);
            activate.Parameters.AddWithValue("id", membershipId);
            try
            {
                Assert.Equal(0, await activate.ExecuteNonQueryAsync());
            }
            catch (PostgresException ex)
            {
                Assert.Contains(ex.SqlState, new[] { PostgresErrorCodes.InsufficientPrivilege, PostgresErrorCodes.RaiseException, PostgresErrorCodes.CheckViolation });
            }
        });
        Assert.Equal("invited", Assert.Single(await Pr1Db.MembershipsAsync(Alpha, victim)).Status);
    }

    [Fact]
    public async Task B1_server_owned_fields_in_the_invite_body_are_ignored()
    {
        var victim = await CreateUserAsync("b1-forged-body", (Beta, null, "doctor"));
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await admin.PostAsJsonAsync(
            Pr1Contract.Members,
            new { email = await EmailOfAsync(victim), role = "doctor", status = "active", userId = victim, tenantId = Beta });
        AssertIsUniformInviteResponse(await ShapeOf(response));

        // The tenant comes from the admin's resolved context, the status is always 'invited'.
        Assert.Equal("invited", Assert.Single(await Pr1Db.MembershipsAsync(Alpha, victim)).Status);
        Assert.Equal("active", Assert.Single(await Pr1Db.MembershipsAsync(Beta, victim)).Status); // pre-existing, untouched
    }

    [Fact]
    public async Task B1_admin_token_claiming_a_tenant_where_they_are_not_admin_cannot_invite()
    {
        var target = await CreateUserAsync("b1-cross-target");
        var email = await EmailOfAsync(target);

        // Alpha admin with a token naming Beta (no Beta membership) => tenant not resolved => 403.
        using var alphaAdminInBeta = factory.ClientAs(AlphaAdmin, Beta);
        var cross = await alphaAdminInBeta.PostAsJsonAsync(Pr1Contract.Members, new { email, role = "doctor" });
        Assert.Equal(HttpStatusCode.Forbidden, cross.StatusCode);

        // Beta doctor (member, not admin) in Beta => 403 and no different from an unknown email.
        using var betaDoctor = factory.ClientAs(BetaDoctor, Beta);
        var notAdmin = await ShapeOf(await betaDoctor.PostAsJsonAsync(Pr1Contract.Members, new { email, role = "doctor" }));
        var notAdminUnknown = await ShapeOf(await betaDoctor.PostAsJsonAsync(Pr1Contract.Members, new { email = NoAccountEmail(), role = "doctor" }));
        Assert.Equal(HttpStatusCode.Forbidden, notAdmin.Status);
        Assert.Equal(notAdminUnknown.Status, notAdmin.Status);
        Assert.Equal(WithoutTraceId(notAdminUnknown.Body), WithoutTraceId(notAdmin.Body));

        Assert.Empty(await Pr1Db.MembershipsAsync(Beta, target));
        Assert.Empty(await Pr1Db.MembershipsAsync(Alpha, target));
    }

    [Fact]
    public async Task B1_validation_errors_stay_400_and_identical_whether_or_not_the_account_exists()
    {
        var existing = await CreateUserAsync("b1-validation");
        var withAccount = await ShapeOf(await InviteAsync(await EmailOfAsync(existing), role: "superuser"));
        var withoutAccount = await ShapeOf(await InviteAsync(NoAccountEmail(), role: "superuser"));
        Assert.Equal(HttpStatusCode.BadRequest, withAccount.Status);
        Assert.Equal(withoutAccount.Status, withAccount.Status);
        Assert.Equal(WithoutTraceId(withoutAccount.Body), WithoutTraceId(withAccount.Body));
        Assert.Empty(await Pr1Db.MembershipsAsync(Alpha, existing));
    }
}
