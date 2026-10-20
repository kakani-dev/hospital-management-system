using System.Net;
using System.Net.Http.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Pr1Regression;

/// <summary>
/// PR #1 review finding M1: roles were not bound to the branch they were granted for (the API and
/// RLS used the union of roles x the union of branches).
///
/// Backend's TenantIsolationApiTests already cover the plain P2 case over HTTP (unpinned create at
/// Main 403, at East 201, GET Main patient by id 200); this class adds the pinned-branch,
/// persistence, list/search and invite-uniformity gaps.
///
/// Contract (FIX-PLAN.md + scope change 21:20 IST): patient WRITES need the writer role AT THAT
/// BRANCH, enforced in the API (ITenantContext.HasRoleAtBranch / PatientEndpoints.CanWritePatientAt).
/// The DB-level has_branch_role RLS is DEFERRED, so these tests only go through the API.
/// Patient READ stays tenant-wide. Adding a tenant_admin with a branch is 400. Authz stays 403.
/// </summary>
[Trait("Category", "Database")]
public sealed class M1BranchScopedWriteApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid AlphaEastPatientId = Guid.Parse("aa000000-0000-4000-8000-000000000003");

    /// <summary>The reproduced P2 shape: billing (read-only) at Alpha Main, nurse (writer) at Alpha East.</summary>
    private static Task<Guid> BillingAtMainNurseAtEastAsync() =>
        CreateUserAsync("m1-split", (Alpha, AlphaMain, "billing"), (Alpha, AlphaEast, "receptionist") /* RBAC: nurses no longer write patients */);

    // MRNs are server-generated (Level 1): the unique marker travels in the last name instead.
    private static object NewPatient(string marker, Guid branch) =>
        new { firstName = "Branch", lastName = marker, registeredBranchId = branch, sex = "female" };

    private static async Task<int> CountByMrnAsync(string mrn)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand("select count(*)::int from patient.patients where last_name = @m", conn);
        cmd.Parameters.AddWithValue("m", mrn);
        return (int)(await cmd.ExecuteScalarAsync())!;
    }

    [Fact]
    public async Task M1_billing_at_Main_nurse_at_East_cannot_create_patient_at_Main()
    {
        var user = await BillingAtMainNurseAtEastAsync();
        var mrn = Pr1Db.NewMrn("M1M");

        // Unpinned token (no branch claim): the case where the API used the union of roles.
        using var unpinned = factory.ClientAs(user, Alpha);
        var response = await unpinned.PostAsJsonAsync("/api/v1/patients", NewPatient(mrn, AlphaMain));
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);

        // Pinned to East (where the user IS a writer) and naming Main in the body: still refused.
        using var pinnedEast = factory.ClientAs(user, Alpha, AlphaEast);
        var viaEast = await pinnedEast.PostAsJsonAsync("/api/v1/patients", NewPatient(mrn, AlphaMain));
        Assert.Equal(HttpStatusCode.Forbidden, viaEast.StatusCode);

        Assert.Equal(0, await CountByMrnAsync(mrn));
    }

    [Fact]
    public async Task M1_billing_at_Main_nurse_at_East_can_create_patient_at_East()
    {
        var user = await BillingAtMainNurseAtEastAsync();
        var mrn = Pr1Db.NewMrn("M1E");
        using var client = factory.ClientAs(user, Alpha);

        var response = await client.PostAsJsonAsync("/api/v1/patients", NewPatient(mrn, AlphaEast));
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var created = await response.Content.ReadFromJsonAsync<PatientView>();
        Assert.Equal(AlphaEast, created!.RegisteredBranchId);

        var stored = await Pr1Db.PatientAuditAsync(created.Id);
        Assert.NotNull(stored);
        Assert.Equal(Alpha, stored.TenantId);
        Assert.Equal(AlphaEast, stored.RegisteredBranchId);
        Assert.Equal(user, stored.CreatedBy);
    }

    [Fact]
    public async Task M1_billing_at_Main_nurse_at_East_can_still_read_patients_at_both_branches()
    {
        var user = await BillingAtMainNurseAtEastAsync();
        using var client = factory.ClientAs(user, Alpha);

        // Paged list (GET without search) and POST search both span the whole tenant.
        var page = await client.GetFromJsonAsync<PagedView<PatientView>>("/api/v1/patients?pageSize=100");
        Assert.Contains(page!.Items, p => p.Id == AlphaPatientId && p.RegisteredBranchId == AlphaMain);
        Assert.Contains(page.Items, p => p.Id == AlphaEastPatientId && p.RegisteredBranchId == AlphaEast);

        var search = await client.PostAsJsonAsync(Pr1Contract.PatientSearch, new { search = "synthetic-alpha", page = 1, pageSize = 100 });
        Assert.Equal(HttpStatusCode.OK, search.StatusCode);
        var found = await search.Content.ReadFromJsonAsync<PagedView<PatientView>>();
        Assert.Contains(found!.Items, p => p.Id == AlphaPatientId);
        Assert.Contains(found.Items, p => p.Id == AlphaEastPatientId);

        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync($"/api/v1/patients/{AlphaEastPatientId}")).StatusCode);

        // Pinned to East, Main patients are still readable (reads are tenant-wide).
        using var pinnedEast = factory.ClientAs(user, Alpha, AlphaEast);
        Assert.Equal(HttpStatusCode.OK, (await pinnedEast.GetAsync($"/api/v1/patients/{AlphaPatientId}")).StatusCode);
    }

    [Fact]
    public async Task M1_branch_scoped_tenant_admin_invite_is_rejected_identically_whether_or_not_the_account_exists()
    {
        // tenant_admin is tenant-wide (product decision). Rejection must not depend on whether the
        // e-mail has an account, or it would reopen the B1 enumeration oracle.
        var existing = await CreateUserAsync("m1-branch-admin");
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var withAccount = await admin.PostAsJsonAsync(
            Pr1Contract.Members, new { email = await EmailOfAsync(existing), role = "tenant_admin", branchId = AlphaEast });
        var withoutAccount = await admin.PostAsJsonAsync(
            Pr1Contract.Members, new { email = $"nobody-{Guid.NewGuid():N}@synthetic.example", role = "tenant_admin", branchId = AlphaEast });

        Assert.Equal(HttpStatusCode.BadRequest, withAccount.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, withoutAccount.StatusCode);
        Assert.Empty(await Pr1Db.MembershipsAsync(Alpha, existing));
    }
}
