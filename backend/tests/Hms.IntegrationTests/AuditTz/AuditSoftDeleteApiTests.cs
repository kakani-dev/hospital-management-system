using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.AuditTz;

/// <summary>(A) Audit columns are server-owned; soft delete / restore replaces the four hard deletes.</summary>
[Trait("Category", "Database")]
public sealed class AuditSoftDeleteApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly DateTimeOffset Forged = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static Dictionary<string, object?> ForgedAudit(Guid who) => new()
    {
        ["createdOn"] = Forged, ["created_on"] = Forged, ["updatedOn"] = Forged, ["updated_on"] = Forged,
        ["createdBy"] = who, ["created_by"] = who, ["updatedBy"] = who, ["updated_by"] = who,
        ["isDeleted"] = true, ["is_deleted"] = true,
    };

    private static async Task<(DateTimeOffset CreatedOn, Guid CreatedBy, DateTimeOffset UpdatedOn, Guid UpdatedBy, bool IsDeleted)> AuditOfAsync(string table, Guid id)
    {
        await using var conn = new Npgsql.NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new Npgsql.NpgsqlCommand($"select created_on, created_by, updated_on, updated_by, is_deleted from {table} where id = @id", conn);
        cmd.Parameters.AddWithValue("id", id);
        await using var r = await cmd.ExecuteReaderAsync();
        Assert.True(await r.ReadAsync(), $"{table} {id} not found");
        return (r.GetFieldValue<DateTimeOffset>(0), r.GetGuid(1), r.GetFieldValue<DateTimeOffset>(2), r.GetGuid(3), r.GetBoolean(4));
    }

    [Fact]
    public async Task Audit_fields_cannot_be_forged_on_create_or_update()
    {
        var started = DateTimeOffset.UtcNow.AddMinutes(-5);
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);

        // Branch
        var branchBody = ForgedAudit(BetaAdmin);
        branchBody["code"] = ATz.Code("b");
        branchBody["name"] = "Forged audit branch";
        var branch = await ATz.ReadAsync<ATzBranch>(await admin.PostAsJsonAsync("/api/v1/branches", branchBody), HttpStatusCode.Created);
        var stored = await AuditOfAsync("identity.branches", branch.Id);
        Assert.Equal(AlphaAdmin, stored.CreatedBy);
        Assert.Equal(AlphaAdmin, stored.UpdatedBy);
        Assert.False(stored.IsDeleted);
        Assert.True(stored.CreatedOn > started);

        // Practitioner
        var practitionerBody = ForgedAudit(BetaAdmin);
        practitionerBody["displayName"] = "Dr Forged (synthetic)";
        var practitioner = await ATz.ReadAsync<ATzPractitioner>(await admin.PostAsJsonAsync("/api/v1/practitioners", practitionerBody), HttpStatusCode.Created);
        stored = await AuditOfAsync("appointment.practitioners", practitioner.Id);
        Assert.Equal(AlphaAdmin, stored.CreatedBy);
        Assert.False(stored.IsDeleted);
        Assert.True(stored.CreatedOn > started);

        // Patient update by another user: created_* stay, updated_* = caller, is_deleted untouched.
        var patient = await Sprint2.S2.CreatePatientAsync(admin, AlphaMain);
        var before = await AuditOfAsync("patient.patients", patient.Id);
        var patchBody = ForgedAudit(BetaAdmin);
        patchBody["firstName"] = "Patched";
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        // PATCH is strict: audit fields are read-only properties -> 400, nothing written.
        var rejected = await reception.PatchAsJsonAsync($"/api/v1/patients/{patient.Id}", patchBody);
        Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
        Assert.Contains("isDeleted", await rejected.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        Assert.Equal(before, await AuditOfAsync("patient.patients", patient.Id));
        var patched = await ATz.ReadAsync<ATzPatient>(await reception.PatchAsJsonAsync($"/api/v1/patients/{patient.Id}", new { firstName = "Patched" }), HttpStatusCode.OK);
        var after = await AuditOfAsync("patient.patients", patient.Id);
        Assert.Equal(before.CreatedOn, after.CreatedOn);
        Assert.Equal(AlphaAdmin, after.CreatedBy);
        Assert.Equal(AlphaReception, after.UpdatedBy);
        Assert.True(after.UpdatedOn >= before.UpdatedOn);
        Assert.False(after.IsDeleted);
        Assert.NotEqual(Forged, patched.CreatedOn); // API exposes created_on / updated_on
        // expand/contract: the legacy created_at/updated_at still mirror the new columns
        Assert.True(await ATz.ScalarAsync<bool>(
            "select created_at = created_on and updated_at = updated_on from patient.patients where id = @id", ("id", patient.Id)));
        Assert.Equal(HttpStatusCode.OK, (await reception.GetAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
    }

    [Fact]
    public async Task Practitioner_soft_delete_and_restore()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await ATz.CreatePractitionerAsync(admin);
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.DeleteAsync($"/api/v1/practitioners/{practitioner.Id}")).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/practitioners/{practitioner.Id}")).StatusCode);
        var list = await admin.GetFromJsonAsync<List<ATzPractitioner>>("/api/v1/practitioners");
        Assert.DoesNotContain(list!, p => p.Id == practitioner.Id);
        var row = await AuditOfAsync("appointment.practitioners", practitioner.Id); // the row is kept
        Assert.True(row.IsDeleted);
        Assert.Equal(AlphaAdmin, row.UpdatedBy);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.DeleteAsync($"/api/v1/practitioners/{practitioner.Id}")).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/practitioners/{practitioner.Id}/restore", null)).StatusCode);
        // restored but inactive (delete deactivated it): visible to admins with activeOnly=false
        list = await admin.GetFromJsonAsync<List<ATzPractitioner>>("/api/v1/practitioners?activeOnly=false");
        Assert.False(list!.Single(p => p.Id == practitioner.Id).IsActive);
        Assert.False((await AuditOfAsync("appointment.practitioners", practitioner.Id)).IsDeleted);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsync($"/api/v1/practitioners/{practitioner.Id}/restore", null)).StatusCode);
    }

    [Fact]
    public async Task Practitioner_with_open_appointments_cannot_be_deleted()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await ATz.CreatePractitionerAsync(admin);
        var patient = await Sprint2.S2.CreatePatientAsync(admin, AlphaMain);
        var booked = await Sprint2.S2.BookAsync(admin, AlphaMain, practitioner.Id, patient.Id, Sprint2.S2.FutureSlot(dayOffset: 40));
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
        var response = await admin.DeleteAsync($"/api/v1/practitioners/{practitioner.Id}");
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.False((await AuditOfAsync("appointment.practitioners", practitioner.Id)).IsDeleted);
    }

    [Fact]
    public async Task Schedule_soft_delete_and_restore()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await ATz.CreatePractitionerAsync(admin);
        var schedule = await ATz.ReadAsync<ATzSchedule>(
            await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = practitioner.Id, branchId = AlphaMain, weekday = 5, startTime = "09:00", endTime = "11:00", slotMinutes = 15 }),
            HttpStatusCode.Created);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/schedules/{schedule.Id}")).StatusCode);
        Assert.True((await AuditOfAsync("appointment.schedules", schedule.Id)).IsDeleted);
        var list = await admin.GetFromJsonAsync<List<ATzSchedule>>($"/api/v1/schedules?practitionerId={practitioner.Id}");
        Assert.DoesNotContain(list!, s => s.Id == schedule.Id);

        // A new schedule may take the freed time (the overlap constraint ignores deleted rows) ...
        var replacement = await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = practitioner.Id, branchId = AlphaMain, weekday = 5, startTime = "10:00", endTime = "12:00", slotMinutes = 15 });
        Assert.Equal(HttpStatusCode.Created, replacement.StatusCode);
        // ... and then restoring the old one would overlap: 409
        Assert.Equal(HttpStatusCode.Conflict, (await admin.PostAsync($"/api/v1/schedules/{schedule.Id}/restore", null)).StatusCode);
        var replacementId = (await replacement.Content.ReadFromJsonAsync<ATzSchedule>())!.Id;
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/schedules/{replacementId}")).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/schedules/{schedule.Id}/restore", null)).StatusCode);
        Assert.False((await AuditOfAsync("appointment.schedules", schedule.Id)).IsDeleted);
    }

    [Fact]
    public async Task Branch_soft_delete_and_restore()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var branch = await ATz.CreateBranchAsync(admin, timezone: null);
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.DeleteAsync($"/api/v1/branches/{branch.Id}")).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/branches/{branch.Id}")).StatusCode);
        var visible = await admin.GetFromJsonAsync<List<ATzBranch>>("/api/v1/branches");
        Assert.DoesNotContain(visible!, b => b.Id == branch.Id);
        var withDeleted = await admin.GetFromJsonAsync<List<ATzBranch>>("/api/v1/branches?includeDeleted=true");
        Assert.True(withDeleted!.Single(b => b.Id == branch.Id).IsDeleted);
        // a deleted branch cannot be used
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PatchAsJsonAsync($"/api/v1/branches/{branch.Id}", new { name = "Ghost" })).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/branches/{branch.Id}/restore", null)).StatusCode);
        var restored = (await admin.GetFromJsonAsync<List<ATzBranch>>("/api/v1/branches"))!.Single(b => b.Id == branch.Id);
        Assert.False(restored.IsDeleted);
        Assert.False(restored.IsActive); // restored inactive: an admin re-activates it deliberately
    }

    [Fact]
    public async Task The_last_branch_of_a_tenant_cannot_be_deleted()
    {
        var t = await ATz.NewTenantAsync(factory);
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        Assert.Equal(HttpStatusCode.Conflict, (await admin.DeleteAsync($"/api/v1/branches/{t.MainBranchId}")).StatusCode);
    }

    [Fact]
    public async Task A_soft_deleted_membership_denies_access_until_restored()
    {
        var user = await CreateUserAsync("atz-member", (Alpha, AlphaMain, "receptionist"));
        using var member = factory.ClientAs(user, Alpha);
        Assert.Equal(HttpStatusCode.OK, (await member.GetAsync("/api/v1/patients?pageSize=1")).StatusCode);

        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var members = await admin.GetFromJsonAsync<List<ATzMember>>("/api/v1/members");
        var membership = members!.Single(m => m.UserId == user);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/members/{membership.Id}")).StatusCode);

        // Same token, tenant claim still says Alpha: no grant any more.
        Assert.Equal(HttpStatusCode.Forbidden, (await member.GetAsync("/api/v1/patients?pageSize=1")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await member.GetAsync("/api/v1/tenants/current")).StatusCode);
        var me = await member.GetFromJsonAsync<ATzMe>("/api/v1/me");
        Assert.Null(me!.TenantId);
        Assert.DoesNotContain((await admin.GetFromJsonAsync<List<ATzMember>>("/api/v1/members"))!, m => m.Id == membership.Id);
        Assert.True((await AuditOfAsync("identity.memberships", membership.Id)).IsDeleted);

        // An admin cannot delete their own membership (would lock the tenant out).
        var own = (await admin.GetFromJsonAsync<List<ATzMember>>("/api/v1/members"))!.First(m => m.UserId == AlphaAdmin);
        Assert.Equal(HttpStatusCode.Conflict, (await admin.DeleteAsync($"/api/v1/members/{own.Id}")).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/members/{membership.Id}/restore", null)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await member.GetAsync("/api/v1/patients?pageSize=1")).StatusCode);
    }

    [Fact]
    public async Task Deleting_a_branch_revokes_the_roles_of_staff_scoped_to_it()
    {
        // code review MAJ-2: a doctor whose only membership is at a deleted branch must not keep a
        // tenant-wide role (clinical roles read patients tenant-wide).
        var t = await ATz.NewTenantAsync(factory);
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        var east = await ATz.CreateBranchAsync(admin, timezone: null);
        await Sprint2.S2.CreatePatientAsync(admin, t.MainBranchId);
        var doctor = await CreateUserAsync("atz-east-doctor", (t.TenantId, east.Id, "doctor"));
        using var doctorClient = factory.ClientAs(doctor, t.TenantId);
        Assert.Equal(HttpStatusCode.OK, (await doctorClient.GetAsync("/api/v1/patients?pageSize=5")).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/branches/{east.Id}")).StatusCode);

        // Same token, tenant claim still set: the API grant has no roles any more.
        Assert.Equal(HttpStatusCode.Forbidden, (await doctorClient.GetAsync("/api/v1/patients?pageSize=5")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await doctorClient.GetAsync("/api/v1/tenants/current")).StatusCode);
        var me = await doctorClient.GetFromJsonAsync<ATzMe>("/api/v1/me");
        Assert.Null(me!.TenantId);
        // ... and the DB helpers agree (RLS)
        Assert.Equal(0L, await ATz.ScalarAsync<long>(
            "select count(*) from identity.resolve_active_context(@u)", ("u", doctor)));

        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/branches/{east.Id}/restore", null)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await doctorClient.GetAsync("/api/v1/patients?pageSize=5")).StatusCode);
    }

    [Fact]
    public async Task Cross_tenant_soft_delete_and_restore_are_404()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await ATz.CreatePractitionerAsync(admin);
        var schedule = await ATz.ReadAsync<ATzSchedule>(
            await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = practitioner.Id, branchId = AlphaEast, weekday = 6, startTime = "09:00", endTime = "10:00", slotMinutes = 15 }),
            HttpStatusCode.Created);
        var alphaMember = await CreateUserAsync("atz-x", (Alpha, AlphaEast, "nurse"));
        var membershipId = (await admin.GetFromJsonAsync<List<ATzMember>>("/api/v1/members"))!.Single(m => m.UserId == alphaMember).Id;

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        string[] urls =
        [
            $"/api/v1/branches/{AlphaEast}", $"/api/v1/members/{membershipId}",
            $"/api/v1/practitioners/{practitioner.Id}", $"/api/v1/schedules/{schedule.Id}",
        ];
        foreach (var url in urls)
        {
            Assert.Equal(HttpStatusCode.NotFound, (await beta.DeleteAsync(url)).StatusCode);
            Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsync($"{url}/restore", null)).StatusCode);
        }

        // nothing changed on Alpha's side
        Assert.False((await AuditOfAsync("identity.branches", AlphaEast)).IsDeleted);
        Assert.False((await AuditOfAsync("identity.memberships", membershipId)).IsDeleted);
        Assert.False((await AuditOfAsync("appointment.practitioners", practitioner.Id)).IsDeleted);
        Assert.False((await AuditOfAsync("appointment.schedules", schedule.Id)).IsDeleted);

        // and a deleted Alpha row is still 404 for Beta's restore
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/practitioners/{practitioner.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsync($"/api/v1/practitioners/{practitioner.Id}/restore", null)).StatusCode);
        Assert.True((await AuditOfAsync("appointment.practitioners", practitioner.Id)).IsDeleted);
    }
}
