using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>
/// Duplicate patient detection (contract §1.4-1.5, §A.3, D3): same tenant, not deleted, matched on
/// name+DOB (trimmed, case-insensitive) or normalized phone (last 10 digits); both-reasons first;
/// at most 20; advisory only (create still succeeds and returns duplicateWarnings).
/// Every test uses a fresh random surname/phone so results are deterministic on a shared database.
/// </summary>
[Trait("Category", "Database")]
public sealed class QaDuplicateDetectionApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly DateOnly Dob = new(1977, 7, 7);

    private static async Task<List<QaDuplicateCandidate>> CheckAsync(HttpClient client, object body) =>
        (await Qa.ReadAsync<QaDuplicates>(await client.PostAsJsonAsync(QaRoutes.PatientDuplicates, body), HttpStatusCode.OK)).Candidates;

    [Fact]
    public async Task Name_and_dob_match_ignores_case_and_whitespace_and_needs_the_same_dob()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var surname = Qa.NewSurname("Dup");
        var existing = await Qa.CreatePatientAsync(admin, AlphaEast, "Leela", surname, Dob);

        var hit = Assert.Single(await CheckAsync(admin, new { firstName = "  lEELA ", lastName = surname.ToUpperInvariant() + " ", dateOfBirth = Dob }));
        Assert.Equal((existing.Id, existing.Mrn, existing.RegisteredBranchId), (hit.Id, hit.Mrn, hit.RegisteredBranchId));
        Assert.Equal<string>(["name_dob"], hit.MatchReasons);

        Assert.Empty(await CheckAsync(admin, new { firstName = "Leela", lastName = surname, dateOfBirth = Dob.AddDays(1) }));
        Assert.Empty(await CheckAsync(admin, new { firstName = "Leela", lastName = surname })); // no DOB -> no name_dob match
        Assert.Empty(await CheckAsync(admin, new { firstName = "Leelavathi", lastName = surname, dateOfBirth = Dob }));
    }

    [Fact]
    public async Task Phone_match_uses_the_normalized_last_ten_digits()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var digits = Qa.NewPhoneDigits();
        var formatted = $"+91 {digits[..5]} {digits[5..]}";
        var existing = await Qa.CreatePatientAsync(admin, AlphaMain, "Phone", Qa.NewSurname("Dup"), phone: formatted);

        var hit = Assert.Single(await CheckAsync(admin, new { firstName = "Someone", lastName = "Else", phone = $"0{digits[..3]}-{digits[3..6]}-{digits[6..]}" }));
        Assert.Equal(existing.Id, hit.Id);
        Assert.Equal<string>(["phone"], hit.MatchReasons);

        // Phone search uses the same normalization (POST body, never the URL).
        var search = await Qa.ReadAsync<QaPaged<QaPatient>>(await admin.PostAsJsonAsync(QaRoutes.PatientSearch, new { phone = digits }), HttpStatusCode.OK);
        Assert.Equal(existing.Id, Assert.Single(search.Items).Id);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsJsonAsync(QaRoutes.PatientSearch, new { phone = "12-34" })).StatusCode);
    }

    [Fact]
    public async Task Both_reasons_rank_first_then_by_name_and_the_edited_patient_is_excluded()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var surname = Qa.NewSurname("Rank");
        var digits = Qa.NewPhoneDigits();
        var nameOnly = await Qa.CreatePatientAsync(admin, AlphaMain, "Arun", surname, Dob);
        var phoneOnly = await Qa.CreatePatientAsync(admin, AlphaMain, "Zed", Qa.NewSurname("Aaa"), new DateOnly(2000, 1, 1), digits);
        var both = await Qa.CreatePatientAsync(admin, AlphaEast, "Arun", surname, Dob, digits);

        var candidates = await CheckAsync(admin, new { firstName = "Arun", lastName = surname, dateOfBirth = Dob, phone = digits });
        Assert.Equal(both.Id, candidates[0].Id);
        Assert.Equal<string>(["name_dob", "phone"], candidates[0].MatchReasons.Order());
        // Both-reasons first, then last_name, first_name, mrn ("Zz-Aaa-..." sorts before "Zz-Rank-...").
        Assert.Equal<Guid>([both.Id, phoneOnly.Id, nameOnly.Id], candidates.Select(c => c.Id));

        // Editing `both`: it must not report itself.
        var whileEditing = await CheckAsync(admin, new { firstName = "Arun", lastName = surname, dateOfBirth = Dob, phone = digits, excludePatientId = both.Id });
        Assert.DoesNotContain(whileEditing, c => c.Id == both.Id);
        Assert.Equal(2, whileEditing.Count);
    }

    [Fact]
    public async Task Other_tenants_and_soft_deleted_patients_are_never_candidates()
    {
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var surname = Qa.NewSurname("Iso");
        var digits = Qa.NewPhoneDigits();
        await Qa.CreatePatientAsync(beta, BetaMain, "Tara", surname, Dob, digits);
        var deleted = await Qa.CreatePatientAsync(alpha, AlphaMain, "Tara", surname, Dob, digits);
        Assert.Equal(HttpStatusCode.NoContent, (await alpha.DeleteAsync(QaRoutes.Patient(deleted.Id))).StatusCode);

        Assert.Empty(await CheckAsync(alpha, new { firstName = "Tara", lastName = surname, dateOfBirth = Dob, phone = digits }));

        // A tenantId in the body is ignored: still only the caller's tenant.
        Assert.Empty(await CheckAsync(alpha, new { tenantId = Beta, firstName = "Tara", lastName = surname, dateOfBirth = Dob, phone = digits }));

        // The Beta row is found from Beta (sanity check of the fixture).
        Assert.Single(await CheckAsync(beta, new { firstName = "Tara", lastName = surname, dateOfBirth = Dob, phone = digits }));
    }

    [Fact]
    public async Task Duplicates_are_advisory_create_succeeds_with_warnings()
    {
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        var surname = Qa.NewSurname("Adv");
        var first = await Qa.CreatePatientAsync(reception, AlphaMain, "Nila", surname, Dob);
        Assert.Empty(first.DuplicateWarnings!);

        var second = await Qa.CreatePatientAsync(reception, AlphaMain, "Nila", surname, Dob);
        Assert.NotEqual(first.Id, second.Id);
        var warning = Assert.Single(second.DuplicateWarnings!);
        Assert.Equal((first.Id, first.Mrn), (warning.Id, warning.Mrn));
        Assert.Contains("name_dob", warning.MatchReasons);
        Assert.Equal(2L, await Qa.ScalarAsync<long>("select count(*) from patient.patients where last_name = @l", ("l", surname)));
    }

    [Fact]
    public async Task Duplicate_check_needs_a_registry_writer_role()
    {
        var lab = await CreateUserAsync("s2qa-dup-lab", (Alpha, null, "lab_technician"));
        using var client = factory.ClientAs(lab, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden,
            (await client.PostAsJsonAsync(QaRoutes.PatientDuplicates, new { firstName = "Asha", lastName = "Synthetic-Alpha", dateOfBirth = new DateOnly(1985, 4, 12) })).StatusCode);

        var billing = await CreateUserAsync("s2qa-dup-billing", (Alpha, null, "billing"));
        using var billingClient = factory.ClientAs(billing, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden,
            (await billingClient.PostAsJsonAsync(QaRoutes.PatientDuplicates, new { firstName = "Asha", lastName = "Synthetic-Alpha", dateOfBirth = new DateOnly(1985, 4, 12) })).StatusCode);
    }
}
