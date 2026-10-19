using System.Net;
using System.Net.Http.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Pr1Regression;

/// <summary>
/// PR #1 re-review N1: identity.add_member deduplicated on (tenant, user) only, so an existing
/// member could never get a second branch membership (the per-branch model the M1 fix relies on).
///
/// Contract (fix/pr1-n1, migration 20261009090000_membership_invite_per_branch.sql):
/// POST /api/v1/members for an existing member at a DIFFERENT branch creates a separate 'invited'
/// membership that the invitee must accept (GET /api/v1/me/invitations, POST .../accept -> 204);
/// the same (tenant, user, branch) is a no-op. Both answer the uniform 202.
///
/// The DB team's supabase/tests/09_membership_invite_per_branch_test.sql covers add_member at the
/// SQL level (dedupe key, tenant-wide NULL branch, concurrency). These tests go through the API
/// (hms_api_login + RLS) and add what SQL cannot show: HTTP uniformity, no branch write access
/// before acceptance, and write access after it.
/// </summary>
[Trait("Category", "Database")]
public sealed class N1SecondBranchInviteApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid AlphaEastPatientId = Guid.Parse("aa000000-0000-4000-8000-000000000003");

    private sealed record InviteShape(HttpStatusCode Status, string? MediaType, string Body);

    private static async Task<InviteShape> ShapeOf(HttpResponseMessage response)
    {
        using (response)
        {
            return new InviteShape(response.StatusCode, response.Content.Headers.ContentType?.MediaType, await response.Content.ReadAsStringAsync());
        }
    }

    private async Task<InviteShape> InviteAsync(string email, string role, Guid? branchId)
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        return await ShapeOf(await admin.PostAsJsonAsync(Pr1Contract.Members, new { email, role, branchId }));
    }

    /// <summary>The 202 a no-account email gets; every other case must be byte-identical to it.</summary>
    private async Task<InviteShape> UniformAnswerAsync()
    {
        var shape = await InviteAsync($"n1-nobody-{Guid.NewGuid():N}@synthetic.example", "nurse", AlphaEast);
        Assert.Equal(HttpStatusCode.Accepted, shape.Status);
        Assert.Contains(Pr1Contract.InviteMessage, shape.Body, StringComparison.Ordinal);
        return shape;
    }

    // MRNs are server-generated (Level 1): the unique marker travels in the last name instead.
    private static object NewPatient(string marker, Guid branch) =>
        new { firstName = "Second", lastName = marker, registeredBranchId = branch, sex = "female" };

    private static async Task<int> CountByMrnAsync(string mrn)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand("select count(*)::int from patient.patients where last_name = @m", conn);
        cmd.Parameters.AddWithValue("m", mrn);
        return (int)(await cmd.ExecuteScalarAsync())!;
    }

    [Fact]
    public async Task N1_member_invited_to_a_second_branch_gets_the_same_202_and_East_write_access_only_after_accepting()
    {
        var member = await CreateUserAsync("n1-second", (Alpha, AlphaMain, "receptionist"));
        var email = await EmailOfAsync(member);
        var mainRow = Assert.Single(await Pr1Db.MembershipsAsync(Alpha, member));
        Assert.Equal((AlphaMain, "receptionist", "active"), (mainRow.BranchId, mainRow.Role, mainRow.Status));

        // Invite to East: identical to the no-account answer.
        var uniform = await UniformAnswerAsync();
        Assert.Equal(uniform, await InviteAsync(email, "nurse", AlphaEast));

        // A separate pending East membership; the Main membership is untouched.
        var rows = await Pr1Db.MembershipsAsync(Alpha, member);
        Assert.Equal(2, rows.Count);
        Assert.Equal(mainRow, Assert.Single(rows, r => r.BranchId == AlphaMain));
        var eastRow = Assert.Single(rows, r => r.BranchId == AlphaEast);
        Assert.Equal(("nurse", "invited"), (eastRow.Role, eastRow.Status));

        // Before accepting: no write access at East (unpinned, or pinned to East)...
        var eastMrn = Pr1Db.NewMrn("N1E");
        using (var unpinned = factory.ClientAs(member, Alpha))
        {
            Assert.Equal(HttpStatusCode.Forbidden, (await unpinned.PostAsJsonAsync("/api/v1/patients", NewPatient(eastMrn, AlphaEast))).StatusCode);
        }
        using (var pinnedEast = factory.ClientAs(member, Alpha, AlphaEast))
        {
            Assert.Equal(HttpStatusCode.Forbidden, (await pinnedEast.PostAsJsonAsync("/api/v1/patients", NewPatient(eastMrn, AlphaEast))).StatusCode);
        }
        Assert.Equal(0, await CountByMrnAsync(eastMrn));

        using var asMember = factory.ClientAs(member, Alpha);
        // ...East is not among the member's branches or memberships yet...
        var meBefore = await asMember.GetFromJsonAsync<MeView>("/api/v1/me");
        Assert.DoesNotContain(meBefore!.AccessibleBranches, b => b.Id == AlphaEast);
        Assert.DoesNotContain(meBefore.Memberships, m => m.BranchId == AlphaEast);
        // ...and the Main access is unchanged: write at Main, tenant-wide read.
        var mainMrn = Pr1Db.NewMrn("N1M");
        Assert.Equal(HttpStatusCode.Created, (await asMember.PostAsJsonAsync("/api/v1/patients", NewPatient(mainMrn, AlphaMain))).StatusCode);
        Assert.Equal(1, await CountByMrnAsync(mainMrn));
        Assert.Equal(HttpStatusCode.OK, (await asMember.GetAsync($"/api/v1/patients/{AlphaEastPatientId}")).StatusCode);

        // The invite is listed for the invitee and accepting it is a 204.
        var invite = Assert.Single((await asMember.GetFromJsonAsync<List<Pr1InvitationView>>(Pr1Contract.MyInvitations))!);
        Assert.Equal((eastRow.Id, Alpha, (Guid?)AlphaEast, "nurse"), (invite.MembershipId, invite.TenantId, invite.BranchId, invite.Role));
        Assert.Equal(HttpStatusCode.NoContent, (await asMember.PostAsync(Pr1Contract.Accept(invite.MembershipId), content: null)).StatusCode);
        Assert.Empty((await asMember.GetFromJsonAsync<List<Pr1InvitationView>>(Pr1Contract.MyInvitations))!);

        var after = await Pr1Db.MembershipsAsync(Alpha, member);
        Assert.Equal(2, after.Count);
        Assert.Equal(mainRow, Assert.Single(after, r => r.BranchId == AlphaMain));
        Assert.Equal(eastRow with { Status = "active" }, Assert.Single(after, r => r.BranchId == AlphaEast));

        // After accepting: the member CAN create a patient at East.
        var created = await asMember.PostAsJsonAsync("/api/v1/patients", NewPatient(eastMrn, AlphaEast));
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var patient = await created.Content.ReadFromJsonAsync<PatientView>();
        Assert.Equal(AlphaEast, patient!.RegisteredBranchId);
        var stored = await Pr1Db.PatientAuditAsync(patient.Id);
        Assert.NotNull(stored);
        Assert.Equal((Alpha, AlphaEast, (Guid?)member), (stored.TenantId, stored.RegisteredBranchId, stored.CreatedBy));
        var meAfter = await asMember.GetFromJsonAsync<MeView>("/api/v1/me");
        Assert.Contains(meAfter!.AccessibleBranches, b => b.Id == AlphaEast);
    }

    [Fact]
    public async Task N1_reinviting_at_the_same_branch_is_a_noop_with_the_identical_202()
    {
        var member = await CreateUserAsync("n1-same", (Alpha, AlphaMain, "receptionist"));
        var email = await EmailOfAsync(member);
        var before = Assert.Single(await Pr1Db.MembershipsAsync(Alpha, member));

        // Same branch, same role and a different role: identical 202, no new row, nothing changes.
        var uniform = await UniformAnswerAsync();
        Assert.Equal(uniform, await InviteAsync(email, "receptionist", AlphaMain));
        Assert.Equal(uniform, await InviteAsync(email.ToUpperInvariant(), "doctor", AlphaMain));
        Assert.Equal(before, Assert.Single(await Pr1Db.MembershipsAsync(Alpha, member)));

        using var asMember = factory.ClientAs(member, Alpha);
        Assert.Empty((await asMember.GetFromJsonAsync<List<Pr1InvitationView>>(Pr1Contract.MyInvitations))!);
        var me = await asMember.GetFromJsonAsync<MeView>("/api/v1/me");
        Assert.Equal(["receptionist"], me!.Roles);

        // A pending second-branch invite repeated at that branch is also a no-op: still one invite, same id.
        Assert.Equal(uniform, await InviteAsync(email, "nurse", AlphaEast));
        var pending = Assert.Single(await Pr1Db.MembershipsAsync(Alpha, member), r => r.BranchId == AlphaEast);
        Assert.Equal(uniform, await InviteAsync(email, "doctor", AlphaEast));
        var rows = await Pr1Db.MembershipsAsync(Alpha, member);
        Assert.Equal(2, rows.Count);
        Assert.Equal(before, Assert.Single(rows, r => r.BranchId == AlphaMain));
        Assert.Equal(pending, Assert.Single(rows, r => r.BranchId == AlphaEast));
        Assert.Equal(("nurse", "invited"), (pending.Role, pending.Status));
        Assert.Equal(pending.Id, Assert.Single((await asMember.GetFromJsonAsync<List<Pr1InvitationView>>(Pr1Contract.MyInvitations))!).MembershipId);
    }
}
