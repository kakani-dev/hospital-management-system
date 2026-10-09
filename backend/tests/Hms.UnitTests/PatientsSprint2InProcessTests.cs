using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.SharedKernel.Tenancy;
using static Hms.UnitTests.InProcessApiTests;

namespace Hms.UnitTests;

/// <summary>Sprint 2.1 patient endpoints through the real pipeline (EF InMemory + fake registry RPCs).</summary>
public sealed class PatientsSprint2InProcessTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    private static readonly string[] BothReasons = ["name_dob", "phone"];

    private static string Unique(string prefix) => $"{prefix}{Guid.NewGuid():N}"[..18];

    private async Task<Detail> CreateAsync(Guid branch, string? lastName = null, string? dob = null, string? phone = null, Guid? asUser = null)
    {
        using var client = factory.ClientAs(asUser ?? Admin);
        var response = await client.PostAsJsonAsync("/api/v1/patients", new
        {
            mrn = Unique("m"), firstName = "Ravi", lastName = lastName ?? Unique("L"), registeredBranchId = branch,
            dateOfBirth = dob, phone, email = "ravi@synthetic.example",
        });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return (await response.Content.ReadFromJsonAsync<Detail>())!;
    }

    private static Task<HttpResponseMessage> PatchAsync(HttpClient client, Guid id, object body) =>
        client.PatchAsJsonAsync($"/api/v1/patients/{id}", body);

    private static async Task<string?> CodeOf(HttpResponseMessage response)
    {
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return doc.RootElement.TryGetProperty("code", out var code) ? code.GetString() : null;
    }

    [Fact]
    public async Task Get_returns_the_detail_and_404_for_unknown_ids()
    {
        var created = await CreateAsync(Main, phone: "+91 98450 12345");
        using var client = factory.ClientAs(MixedUser); // billing at Main can read
        var detail = await client.GetFromJsonAsync<Detail>($"/api/v1/patients/{created.Id}");
        Assert.Equal("+91 98450 12345", detail!.Phone);
        Assert.Equal("ravi@synthetic.example", detail.Email);
        Assert.Null(detail.DeletedAt);

        var missing = await client.GetAsync($"/api/v1/patients/{Guid.NewGuid()}");
        Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
        Assert.Equal("not_found", await CodeOf(missing));

        using var lab = factory.ClientAs(LabTech);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.GetAsync($"/api/v1/patients/{created.Id}")).StatusCode);
    }

    [Fact]
    public async Task Patch_has_merge_patch_semantics()
    {
        var created = await CreateAsync(Main, dob: "1990-01-02", phone: "9845012345");
        using var client = factory.ClientAs(Admin);

        var response = await PatchAsync(client, created.Id, new { firstName = "  Ravindra ", phone = (string?)null });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var updated = (await response.Content.ReadFromJsonAsync<Detail>())!;
        Assert.Equal("Ravindra", updated.FirstName);
        Assert.Null(updated.Phone);                                      // explicit null clears
        Assert.Equal(new DateOnly(1990, 1, 2), updated.DateOfBirth);     // absent = unchanged
        Assert.Equal("ravi@synthetic.example", updated.Email);
        Assert.Equal(created.Mrn, updated.Mrn);

        var reread = await client.GetFromJsonAsync<Detail>($"/api/v1/patients/{created.Id}");
        Assert.Equal("Ravindra", reread!.FirstName);
        Assert.Null(reread.Phone);
    }

    [Theory]
    [InlineData("{\"mrn\":\"OTHER-1\"}", "mrn")]
    [InlineData("{\"nickname\":\"x\"}", "nickname")]
    [InlineData("{\"firstName\":null}", "firstName")]
    [InlineData("{\"sex\":null}", "sex")]
    [InlineData("{\"sex\":\"robot\"}", "sex")]
    [InlineData("{\"registeredBranchId\":null}", "registeredBranchId")]
    [InlineData("{\"dateOfBirth\":\"2026-10-08\"}", "dateOfBirth")]   // future even in Kolkata (today = 2026-10-07)
    [InlineData("{\"dateOfBirth\":\"07/10/2026\"}", "dateOfBirth")]
    [InlineData("{\"phone\":\"123456789012345678901234567890123\"}", "phone")]
    [InlineData("{\"firstName\":42}", "firstName")]
    public async Task Patch_validation_errors_are_400_with_the_field(string json, string field)
    {
        var created = await CreateAsync(Main);
        using var client = factory.ClientAs(Admin);
        using var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");
        var response = await client.PatchAsync($"/api/v1/patients/{created.Id}", content);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains($"\"{field}\"", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Patch_same_mrn_in_other_case_and_tenant_id_are_accepted_and_ignored()
    {
        var created = await CreateAsync(Main);
        using var client = factory.ClientAs(Admin);
        var response = await PatchAsync(client, created.Id, new { mrn = created.Mrn.ToLowerInvariant(), tenantId = Guid.NewGuid(), lastName = "Same" });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(Alpha.ToString(), Assert.Single(response.Headers.GetValues(HmsHeaders.Tenant)));
    }

    [Fact]
    public async Task Patch_is_authorized_at_the_current_and_the_new_branch()
    {
        var atMain = await CreateAsync(Main);
        var atEast = await CreateAsync(East);
        using var mixed = factory.ClientAs(MixedUser); // billing @Main, nurse @East

        Assert.Equal(HttpStatusCode.Forbidden, (await PatchAsync(mixed, atMain.Id, new { lastName = "Nope" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await PatchAsync(mixed, atEast.Id, new { lastName = "Yes" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await PatchAsync(mixed, atEast.Id, new { registeredBranchId = Main })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await PatchAsync(mixed, atEast.Id, new { registeredBranchId = BetaMain })).StatusCode); // foreign branch (v4)

        using var billing = factory.ClientAs(BillingOnly);
        Assert.Equal(HttpStatusCode.Forbidden, (await PatchAsync(billing, atEast.Id, new { lastName = "Nope" })).StatusCode);

        using var admin = factory.ClientAs(Admin);
        var moved = await PatchAsync(admin, atMain.Id, new { registeredBranchId = East });
        Assert.Equal(HttpStatusCode.OK, moved.StatusCode);
        Assert.Equal(East, (await moved.Content.ReadFromJsonAsync<Detail>())!.RegisteredBranchId);

        Assert.Equal(HttpStatusCode.NotFound, (await PatchAsync(admin, Guid.NewGuid(), new { lastName = "Ghost" })).StatusCode);
    }

    [Fact]
    public async Task Soft_delete_hides_the_patient_from_get_list_search_and_duplicates()
    {
        var last = Unique("Del");
        var patient = await CreateAsync(East, lastName: last, dob: "1985-05-05", phone: "080-4111-2222");
        using var reception = factory.ClientAs(DoctorMainReceptionEast);

        using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/v1/patients/{patient.Id}")
        {
            Content = JsonContent.Create(new { reason = "Registered twice" }),
        };
        Assert.Equal(HttpStatusCode.NoContent, (await reception.SendAsync(request)).StatusCode);

        Assert.Equal(HttpStatusCode.NotFound, (await reception.GetAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
        var list = await reception.GetFromJsonAsync<Page>("/api/v1/patients?pageSize=100");
        Assert.DoesNotContain(list!.Items, p => p.Id == patient.Id);
        var search = await (await reception.PostAsJsonAsync("/api/v1/patients/search", new { search = last })).Content.ReadFromJsonAsync<Page>();
        Assert.Empty(search!.Items);
        var dupes = await (await reception.PostAsJsonAsync("/api/v1/patients/duplicates", new { firstName = "Ravi", lastName = last, dateOfBirth = "1985-05-05" }))
            .Content.ReadFromJsonAsync<Dupes>();
        Assert.Empty(dupes!.Candidates);
        Assert.Equal(HttpStatusCode.NotFound, (await PatchAsync(reception, patient.Id, new { lastName = "X" })).StatusCode);

        // Deleting again: 404 (already deleted is indistinguishable from unknown).
        Assert.Equal(HttpStatusCode.NotFound, (await reception.DeleteAsync($"/api/v1/patients/{patient.Id}")).StatusCode);

        // Admin can find it with includeDeleted, and restore it.
        using var admin = factory.ClientAs(Admin);
        var deleted = await (await admin.PostAsJsonAsync("/api/v1/patients/search", new { search = last, includeDeleted = true })).Content.ReadFromJsonAsync<Page>();
        Assert.NotNull(Assert.Single(deleted!.Items).DeletedAt);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/patients/{patient.Id}/restore", null)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsync($"/api/v1/patients/{patient.Id}/restore", null)).StatusCode);
    }

    [Fact]
    public async Task Delete_and_restore_follow_the_D1_role_matrix()
    {
        var atMain = await CreateAsync(Main);
        var atEast = await CreateAsync(East);

        using var doctorMain = factory.ClientAs(DoctorMainReceptionEast); // doctor can edit at Main but not delete
        Assert.Equal(HttpStatusCode.OK, (await PatchAsync(doctorMain, atMain.Id, new { lastName = "Edited" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await doctorMain.DeleteAsync($"/api/v1/patients/{atMain.Id}")).StatusCode);

        using var nurse = factory.ClientAs(MixedUser);
        Assert.Equal(HttpStatusCode.Forbidden, (await nurse.DeleteAsync($"/api/v1/patients/{atEast.Id}")).StatusCode);

        using var reception = factory.ClientAs(DoctorMainReceptionEast);
        using var tooLong = new HttpRequestMessage(HttpMethod.Delete, $"/api/v1/patients/{atEast.Id}") { Content = JsonContent.Create(new { reason = new string('r', 501) }) };
        Assert.Equal(HttpStatusCode.BadRequest, (await reception.SendAsync(tooLong)).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await reception.DeleteAsync($"/api/v1/patients/{atEast.Id}")).StatusCode);

        // Restore is tenant_admin only.
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsync($"/api/v1/patients/{atEast.Id}/restore", null)).StatusCode);
        // Search incl. deleted is tenant_admin only.
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsJsonAsync("/api/v1/patients/search", new { includeDeleted = true })).StatusCode);
    }

    [Fact]
    public async Task Search_by_phone_and_dob_is_normalized_and_and_ed()
    {
        var last = Unique("Ph");
        var a = await CreateAsync(Main, lastName: last, dob: "1970-03-04", phone: "+91 (98450) 77-1234");
        var b = await CreateAsync(East, lastName: last, dob: "1971-03-04", phone: "098450 771234");
        _ = await CreateAsync(East, lastName: last, dob: "1970-03-04", phone: "11112222");
        using var client = factory.ClientAs(MixedUser);

        async Task<List<Summary>> Search(object body)
        {
            var response = await client.PostAsJsonAsync("/api/v1/patients/search", body);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            return (await response.Content.ReadFromJsonAsync<Page>())!.Items;
        }

        var byPhone = await Search(new { phone = "9845077 1234", search = last });
        Assert.Equal(new[] { a.Id, b.Id }.Order(), byPhone.Select(x => x.Id).Order());
        var byPhoneAndDob = await Search(new { phone = "9845077 1234", dateOfBirth = "1971-03-04" });
        Assert.Equal(b.Id, Assert.Single(byPhoneAndDob).Id);
        Assert.Equal(2, (await Search(new { dateOfBirth = "1970-03-04", search = last })).Count);
        Assert.Equal("098450 771234", byPhoneAndDob[0].Phone);

        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/v1/patients/search", new { phone = "12-34" })).StatusCode);
    }

    [Fact]
    public async Task Create_returns_advisory_duplicate_warnings()
    {
        var last = Unique("Dup");
        var first = await CreateAsync(Main, lastName: last, dob: "1960-12-31", phone: "+91 90000 11111");
        Assert.Empty(first.DuplicateWarnings);

        using var client = factory.ClientAs(Admin);
        var response = await client.PostAsJsonAsync("/api/v1/patients", new
        {
            mrn = Unique("m"), firstName = " ravi ", lastName = last.ToUpperInvariant(), dateOfBirth = "1960-12-31",
            registeredBranchId = East, phone = "9000011111",
        });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode); // advisory: never blocks (D3)
        var second = (await response.Content.ReadFromJsonAsync<Detail>())!;
        var warning = Assert.Single(second.DuplicateWarnings);
        Assert.Equal(first.Id, warning.Id);
        Assert.Equal(BothReasons, warning.MatchReasons);

        // Pre-check endpoint, excluding the patient being edited.
        var check = await (await client.PostAsJsonAsync("/api/v1/patients/duplicates", new { phone = "90000-11111", excludePatientId = first.Id }))
            .Content.ReadFromJsonAsync<Dupes>();
        Assert.Equal(second.Id, Assert.Single(check!.Candidates).Id);

        using var billing = factory.ClientAs(BillingOnly);
        Assert.Equal(HttpStatusCode.Forbidden, (await billing.PostAsJsonAsync("/api/v1/patients/duplicates", new { phone = "9000011111" })).StatusCode);
    }

    [Fact]
    public async Task Duplicate_mrn_conflict_carries_a_machine_code()
    {
        var created = await CreateAsync(Main);
        using var client = factory.ClientAs(Admin);
        var response = await client.PostAsJsonAsync("/api/v1/patients", new { mrn = created.Mrn.ToLowerInvariant(), firstName = "A", lastName = "B", registeredBranchId = East });
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal("duplicate_mrn", await CodeOf(response));
    }

    private sealed record Candidate(Guid Id, string Mrn, List<string> MatchReasons);

    private sealed record Detail(
        Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, string Sex, Guid RegisteredBranchId,
        string? Phone, DateTimeOffset? DeletedAt, string? Email, List<Candidate> DuplicateWarnings);

    private sealed record Summary(Guid Id, string Mrn, string LastName, string? Phone, DateTimeOffset? DeletedAt);

    private sealed record Page(List<Summary> Items, int TotalCount);

    private sealed record Dupes(List<Candidate> Candidates);
}
