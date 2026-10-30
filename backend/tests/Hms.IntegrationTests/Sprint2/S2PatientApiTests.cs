using System.Net;
using System.Net.Http.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2;

/// <summary>Sprint 2.1 against real PostgreSQL (RLS + patient.* RPCs), through the edge.</summary>
[Trait("Category", "Database")]
public sealed class S2PatientApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static async Task<(Guid? UpdatedBy, string? DeletionReason, Guid? DeletedBy)> AuditAsync(Guid patientId)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand("select updated_by, deletion_reason, deleted_by from patient.patients where id = @id", conn);
        cmd.Parameters.AddWithValue("id", patientId);
        await using var r = await cmd.ExecuteReaderAsync();
        Assert.True(await r.ReadAsync());
        return (r.IsDBNull(0) ? null : r.GetGuid(0), r.IsDBNull(1) ? null : r.GetString(1), r.IsDBNull(2) ? null : r.GetGuid(2));
    }

    [Fact]
    public async Task Detail_and_patch_persist_with_db_attribution()
    {
        var nurseEast = await CreateUserAsync("s2-nurse-east", (Alpha, AlphaEast, "receptionist") /* RBAC */);
        using var nurse = factory.ClientAs(nurseEast, Alpha);
        var patient = await S2.CreatePatientAsync(nurse, AlphaEast, dob: "1980-02-02", phone: "+91 98450 11111");

        var detail = await nurse.GetFromJsonAsync<S2Patient>($"/api/v1/patients/{patient.Id}");
        Assert.Equal("+919845011111", detail!.Phone); // E.164

        var patch = await nurse.PatchAsJsonAsync($"/api/v1/patients/{patient.Id}", new { firstName = "Edited", phone = (string?)null, email = "e@synthetic.example" });
        Assert.Equal(HttpStatusCode.OK, patch.StatusCode);
        Assert.Equal(Alpha.ToString(), Assert.Single(patch.Headers.GetValues("X-Hms-Tenant")));

        var reread = await nurse.GetFromJsonAsync<S2Patient>($"/api/v1/patients/{patient.Id}");
        Assert.Equal("Edited", reread!.FirstName);
        Assert.Null(reread.Phone);
        Assert.Equal("e@synthetic.example", reread.Email);
        Assert.Equal(new DateOnly(1980, 2, 2), reread.DateOfBirth);
        Assert.Equal(nurseEast, (await AuditAsync(patient.Id)).UpdatedBy); // stamped by the DB trigger, not sent by EF
    }

    [Fact]
    public async Task Patch_is_tenant_wide_for_a_writer_and_a_foreign_branch_is_404()
    {
        var receptionEast = await CreateUserAsync("s2-reception-east-only", (Alpha, AlphaEast, "receptionist"));
        using var reception = factory.ClientAs(receptionEast, Alpha);
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var atMain = await S2.CreatePatientAsync(admin, AlphaMain);
        var atEast = await S2.CreatePatientAsync(admin, AlphaEast);
        var renamed = S2.Unique("Wide");

        Assert.Equal(HttpStatusCode.OK, (await reception.PatchAsJsonAsync($"/api/v1/patients/{atMain.Id}", new { lastName = renamed })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await reception.PatchAsJsonAsync($"/api/v1/patients/{atEast.Id}", new { registeredBranchId = AlphaMain })).StatusCode);
        Assert.Equal(renamed, (await admin.GetFromJsonAsync<S2Patient>($"/api/v1/patients/{atMain.Id}"))!.LastName);
        Assert.Equal(AlphaMain, (await admin.GetFromJsonAsync<S2Patient>($"/api/v1/patients/{atEast.Id}"))!.RegisteredBranchId);
        Assert.Equal(HttpStatusCode.NotFound, (await reception.PatchAsJsonAsync($"/api/v1/patients/{atMain.Id}", new { registeredBranchId = BetaMain })).StatusCode);

        var billing = await CreateUserAsync("s2-billing-view", (Alpha, AlphaMain, "billing"));
        using var view = factory.ClientAs(billing, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await view.PatchAsJsonAsync($"/api/v1/patients/{atMain.Id}", new { firstName = "Nope" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await reception.GetAsync($"/api/v1/patients/{atMain.Id}")).StatusCode);
    }

    [Fact]
    public async Task Another_tenants_patient_is_404_for_every_verb()
    {
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var url = $"/api/v1/patients/{AlphaPatientId}";
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync(url)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PatchAsJsonAsync(url, new { lastName = "X" })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.DeleteAsync(url)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsync($"{url}/restore", null)).StatusCode);

        var search = await (await beta.PostAsJsonAsync("/api/v1/patients/search", new { search = "ALP-0001", includeDeleted = true }))
            .Content.ReadFromJsonAsync<S2Page<S2Patient>>();
        Assert.Empty(search!.Items);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PatchAsJsonAsync($"/api/v1/patients/{(await S2.CreatePatientAsync(beta, BetaMain)).Id}", new { registeredBranchId = AlphaMain })).StatusCode);
        using var lab = factory.ClientAs(AlphaLab, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PostAsJsonAsync("/api/v1/patients/duplicates", new { phone = "+1-555-0101" })).StatusCode);
        var dupes = await (await beta.PostAsJsonAsync("/api/v1/patients/duplicates", new { phone = "+1-555-0101" })).Content.ReadAsStringAsync();
        Assert.DoesNotContain(AlphaPatientId.ToString(), dupes, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Soft_delete_via_rpc_hides_the_patient_and_admin_can_restore()
    {
        var receptionEast = await CreateUserAsync("s2-reception-east", (Alpha, AlphaEast, "receptionist"));
        using var reception = factory.ClientAs(receptionEast, Alpha);
        using var mainReception = factory.ClientAs(AlphaReception, Alpha); // receptionist at Main only
        var last = S2.Unique("Del");
        var patient = await S2.CreatePatientAsync(reception, AlphaEast, lastName: last, dob: "1977-07-07", phone: "080 4000 7777");

        using var delete = new HttpRequestMessage(HttpMethod.Delete, $"/api/v1/patients/{patient.Id}") { Content = JsonContent.Create(new { reason = "Duplicate registration" }) };
        Assert.Equal(HttpStatusCode.NoContent, (await mainReception.SendAsync(delete)).StatusCode);
        var audit = await AuditAsync(patient.Id);
        Assert.Equal("Duplicate registration", audit.DeletionReason);
        Assert.Equal(AlphaReception, audit.DeletedBy);

        Assert.Equal(HttpStatusCode.NotFound, (await reception.GetAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await reception.PatchAsJsonAsync($"/api/v1/patients/{patient.Id}", new { lastName = "X" })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await reception.DeleteAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
        var page = await (await reception.PostAsJsonAsync("/api/v1/patients/search", new { search = last })).Content.ReadFromJsonAsync<S2Page<S2Patient>>();
        Assert.Empty(page!.Items);
        var byPhone = await (await reception.PostAsJsonAsync("/api/v1/patients/search", new { phone = "08040007777" })).Content.ReadFromJsonAsync<S2Page<S2Patient>>();
        Assert.DoesNotContain(byPhone!.Items, p => p.Id == patient.Id);
        var list = await reception.GetFromJsonAsync<S2Page<S2Patient>>("/api/v1/patients?pageSize=100");
        Assert.DoesNotContain(list!.Items, p => p.Id == patient.Id);
        var dupes = await (await reception.PostAsJsonAsync("/api/v1/patients/duplicates", new { firstName = "Synth", lastName = last, dateOfBirth = "1977-07-07" })).Content.ReadAsStringAsync();
        Assert.DoesNotContain(patient.Id.ToString(), dupes, StringComparison.OrdinalIgnoreCase);

        // MRN stays reserved after delete (D1): a new registration never gets it (a typed MRN is ignored).
        var reuse = await reception.PostAsJsonAsync("/api/v1/patients", new { mrn = patient.Mrn, firstName = "Re", lastName = "Use", registeredBranchId = AlphaEast, sex = "unknown", ageYears = 30, noPhoneReason = "test fixture" });
        Assert.Equal(HttpStatusCode.Created, reuse.StatusCode);
        Assert.DoesNotContain(patient.Mrn, await reuse.Content.ReadAsStringAsync(), StringComparison.Ordinal);

        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsync($"/api/v1/patients/{patient.Id}/restore", null)).StatusCode);
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var deleted = await (await admin.PostAsJsonAsync("/api/v1/patients/search", new { search = last, includeDeleted = true })).Content.ReadFromJsonAsync<S2Page<S2Patient>>();
        Assert.NotNull(Assert.Single(deleted!.Items).DeletedAt);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/patients/{patient.Id}/restore", null)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await reception.GetAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
    }

    [Fact]
    public async Task Delete_with_an_open_appointment_is_409_invalid_state()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        var practitioner = await S2.CreatePractitionerAsync(admin);
        Assert.Equal(HttpStatusCode.Created, (await S2.BookAsync(admin, AlphaMain, practitioner.Id, patient.Id, S2.FutureSlot(5))).StatusCode);

        var response = await admin.DeleteAsync($"/api/v1/patients/{patient.Id}");
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal("invalid_state", await S2.CodeAsync(response));
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
    }

    [Fact]
    public async Task Phone_and_dob_search_and_duplicate_warnings_use_the_db_functions()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var last = S2.Unique("Dup");
        var digits = $"9{Random.Shared.Next(100_000_000, 999_999_999)}";
        var first = await S2.CreatePatientAsync(admin, AlphaMain, lastName: last, dob: "1955-05-15", phone: $"+91 {digits[..5]} {digits[5..]}");
        Assert.Empty(first.DuplicateWarnings!);

        var sharedPhone = await admin.PostAsJsonAsync("/api/v1/patients", new
        {
            firstName = "Other", lastName = S2.Unique("Ph"), registeredBranchId = AlphaEast, phone = $"0{digits}", sex = "unknown", ageYears = 30, noPhoneReason = "test fixture"
        });
        Assert.Equal(HttpStatusCode.Conflict, sharedPhone.StatusCode);
        Assert.Equal("duplicate_patient", await S2.CodeAsync(sharedPhone));

        var sameName = await admin.PostAsJsonAsync("/api/v1/patients", new
        {
            firstName = " synth ", lastName = last.ToLowerInvariant(), dateOfBirth = "1955-05-15", registeredBranchId = AlphaEast,
            duplicateOverrideReason = "Different person, confirmed", sex = "unknown", ageYears = 30, noPhoneReason = "test fixture"
        });
        Assert.Equal(HttpStatusCode.Created, sameName.StatusCode);
        var created = (await sameName.Content.ReadFromJsonAsync<S2Patient>())!;
        Assert.Contains("name_dob", Assert.Single(created.DuplicateWarnings!).MatchReasons);

        var byPhone = await (await admin.PostAsJsonAsync("/api/v1/patients/search", new { phone = digits })).Content.ReadFromJsonAsync<S2Page<S2Patient>>();
        Assert.Equal(first.Id, Assert.Single(byPhone!.Items).Id);
        var byPhoneDob = await (await admin.PostAsJsonAsync("/api/v1/patients/search", new { phone = digits, dateOfBirth = "1955-05-15", search = last }))
            .Content.ReadFromJsonAsync<S2Page<S2Patient>>();
        Assert.Equal(1, byPhoneDob!.TotalCount);
        var noMatch = await (await admin.PostAsJsonAsync("/api/v1/patients/search", new { phone = digits, dateOfBirth = "1955-05-16" }))
            .Content.ReadFromJsonAsync<S2Page<S2Patient>>();
        Assert.Empty(noMatch!.Items);

        var excl = await (await admin.PostAsJsonAsync("/api/v1/patients/duplicates", new { firstName = "Synth", lastName = last, dateOfBirth = "1955-05-15", excludePatientId = first.Id }))
            .Content.ReadAsStringAsync();
        Assert.Contains(created.Id.ToString(), excl, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(first.Id.ToString(), excl, StringComparison.OrdinalIgnoreCase);
    }
}
