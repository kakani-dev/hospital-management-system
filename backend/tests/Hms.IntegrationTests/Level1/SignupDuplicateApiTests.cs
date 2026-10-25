using System.Net;
using System.Net.Http.Json;
using Hms.IntegrationTests.AuditTz;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Level1;

/// <summary>
/// Public sign-up duplicate rules over HTTP. This class has its own factory (own source salt and
/// rate-limit window) and stays at three stored public requests: the per-source cap is 3 per 24h,
/// and the IP limiter is 10. Validation failures and the registered-email 409 do not insert.
/// </summary>
[Trait("Category", "Database")]
public sealed class SignupDuplicateApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private const string Accepted = "Thank you. Your request was received; our team will review it and email the contact person.";
    private const string Registered = "This email is already registered. Please sign in or contact support.";
    private const string ConfirmDuplicate = "This request may duplicate an existing hospital. Confirm to approve it.";

    [Fact]
    public async Task Signup_blocks_a_live_admin_flags_a_later_match_and_allows_resubmit_after_rejection()
    {
        var token = Guid.NewGuid().ToString("N")[..8];
        var anon = factory.CreateClient();
        var hospital = await ATz.NewTenantAsync(factory);
        var adminEmail = await EmailOfAsync(hospital.AdminId);
        var tenantName = $"Synthetic {hospital.Code}";

        // Invalid and empty input: 400 from the form, nothing stored.
        Assert.Equal(HttpStatusCode.BadRequest, (await anon.PostAsJsonAsync("/api/v1/public/hospital-signups", new
        {
            hospitalName = "  ", timeZone = "", contactName = "", contactEmail = "", phone = "", city = "",
        })).StatusCode);
        var invalidEmail = $"not-an-email-{token}";
        Assert.Equal(HttpStatusCode.BadRequest, (await anon.PostAsJsonAsync("/api/v1/public/hospital-signups", new
        {
            hospitalName = "X", timeZone = "IST", contactName = "A", contactEmail = invalidEmail, phone = "12", city = " ",
        })).StatusCode);
        Assert.Equal(0L, await ATz.ScalarAsync<long>(
            "select count(*) from identity.tenant_signup_requests where contact_email = @e", ("e", invalidEmail)));

        // Case, whitespace, and a client-supplied tenant id: a live tenant admin is 409 with fixed copy.
        var blocked = await PostAsync(anon, $"Elsewhere {token} Hospital", $"  {adminEmail.ToUpperInvariant()}  ", National(), "Asia/Kolkata", Guid.NewGuid());
        var blockedBody = await blocked.Content.ReadAsStringAsync();
        Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode);
        Assert.Contains("\"email_registered\"", blockedBody, StringComparison.Ordinal);
        Assert.Contains(Registered, blockedBody, StringComparison.Ordinal);
        Assert.DoesNotContain(hospital.Code, blockedBody, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(tenantName, blockedBody, StringComparison.Ordinal);
        var retry = await PostAsync(anon, $"Elsewhere {token} Clinic", adminEmail, National(), "UTC");
        Assert.Equal(HttpStatusCode.Conflict, retry.StatusCode);
        Assert.Equal(0L, await ATz.ScalarAsync<long>(
            "select count(*) from identity.tenant_signup_requests where contact_email = @e", ("e", adminEmail)));

        // A new email is stored once. Asia/Calcutta canonicalizes; the forged tenant id is ignored.
        var applicant = $"applicant@dup-{token}.example";
        var filedName = $"Dup {token}   HOSPITAL";
        var phone = National();
        var accepted = await PostAsync(anon, filedName, $"Applicant@Dup-{token}.example", $"+91 {phone}", "Asia/Calcutta", Guid.NewGuid());
        Assert.Equal(HttpStatusCode.Accepted, accepted.StatusCode);
        var acceptedBody = await accepted.Content.ReadAsStringAsync();
        Assert.Contains(Accepted, acceptedBody, StringComparison.Ordinal);
        Assert.DoesNotContain(tenantName, acceptedBody, StringComparison.Ordinal);
        Assert.DoesNotContain(hospital.Code, acceptedBody, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(1L, await ATz.ScalarAsync<long>(
            "select count(*) from identity.tenant_signup_requests where contact_email = @e", ("e", applicant)));
        Assert.Equal(filedName, await ATz.ScalarAsync<string>(
            "select hospital_name from identity.tenant_signup_requests where contact_email = @e", ("e", applicant)));
        Assert.Equal("Asia/Kolkata", await ATz.ScalarAsync<string>(
            "select time_zone from identity.tenant_signup_requests where contact_email = @e", ("e", applicant)));
        Assert.Null(await ATz.ScalarAsync<Guid?>(
            "select tenant_id from identity.tenant_signup_requests where contact_email = @e", ("e", applicant)));
        Assert.False(await ATz.ScalarAsync<bool>(
            "select possible_duplicate from identity.tenant_signup_requests where contact_email = @e", ("e", applicant)));

        // Double-submit of the same pending email: same 202 body, still one row.
        var again = await PostAsync(anon, $"Dup {token} Other", applicant, National(), "UTC");
        Assert.Equal(HttpStatusCode.Accepted, again.StatusCode);
        Assert.Equal(acceptedBody, await again.Content.ReadAsStringAsync());
        Assert.Equal(1L, await ATz.ScalarAsync<long>(
            "select count(*) from identity.tenant_signup_requests where contact_email = @e", ("e", applicant)));

        // A tenant created after the request still flags it on the live list. A tenant admin cannot read that list.
        using var op = factory.ClientAs(PlatformConsoleApiTests.Operator);
        var clinicName = $"Dup {token} Clinic";
        var clinicCode = ATz.Code("dup");
        await ATz.ReadAsync<L1Approved>(await op.PostAsJsonAsync("/api/v1/platform/tenants",
            new { code = clinicCode, name = clinicName, timeZone = "Asia/Kolkata", adminEmail = $"boss-{token}@synthetic.example" }), HttpStatusCode.Created);
        var pending = (await op.GetFromJsonAsync<List<DupRequest>>("/api/v1/platform/hospital-requests?status=pending"))!
            .Single(r => r.ContactEmail == applicant);
        Assert.True(pending.PossibleDuplicate);
        Assert.Contains(clinicName, pending.MatchedHospitals);
        Assert.False(await ATz.ScalarAsync<bool>(
            "select possible_duplicate from identity.tenant_signup_requests where id = @id", ("id", pending.Id)));
        using var tenantAdmin = factory.ClientAs(hospital.AdminId, hospital.TenantId);
        Assert.Equal(HttpStatusCode.Forbidden, (await tenantAdmin.GetAsync("/api/v1/platform/hospital-requests")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.GetAsync("/api/v1/platform/hospital-requests")).StatusCode);

        // Approving the flagged request without confirmation rolls nothing forward.
        var approveCode = ATz.Code("dup");
        var unconfirmed = await op.PostAsJsonAsync($"/api/v1/platform/hospital-requests/{pending.Id}/approve",
            new { tenantCode = approveCode, acknowledgeDuplicate = false });
        var unconfirmedBody = await unconfirmed.Content.ReadAsStringAsync();
        Assert.Equal(HttpStatusCode.Conflict, unconfirmed.StatusCode);
        Assert.Contains("\"possible_duplicate\"", unconfirmedBody, StringComparison.Ordinal);
        Assert.Contains(ConfirmDuplicate, unconfirmedBody, StringComparison.Ordinal);
        Assert.DoesNotContain(clinicName, unconfirmedBody, StringComparison.Ordinal);
        Assert.Equal(0L, await ATz.ScalarAsync<long>("select count(*) from identity.tenants where code = @c", ("c", approveCode)));
        Assert.Equal("pending", await ATz.ScalarAsync<string>(
            "select status from identity.tenant_signup_requests where id = @id", ("id", pending.Id)));

        var approved = await ATz.ReadAsync<L1Approved>(await op.PostAsJsonAsync(
            $"/api/v1/platform/hospital-requests/{pending.Id}/approve",
            new { tenantCode = approveCode, acknowledgeDuplicate = true }), HttpStatusCode.OK);
        Assert.NotEqual(Guid.Empty, approved.TenantId);

        // Suspending that admin's original hospital lifts the membership block. Rejection then allows the same email again.
        Assert.Equal(HttpStatusCode.NoContent, (await op.PostAsJsonAsync(
            $"/api/v1/platform/tenants/{hospital.TenantId}/suspend", new { reason = "Synthetic suspension" })).StatusCode);
        var paused = await PostAsync(anon, $"Paused {token} Ward", adminEmail, National(), "UTC");
        Assert.Equal(HttpStatusCode.Accepted, paused.StatusCode);
        var pausedRow = (await op.GetFromJsonAsync<List<DupRequest>>("/api/v1/platform/hospital-requests?status=pending"))!
            .Single(r => r.ContactEmail == adminEmail);
        Assert.Equal(HttpStatusCode.NoContent, (await op.PostAsJsonAsync(
            $"/api/v1/platform/hospital-requests/{pausedRow.Id}/reject", new { reason = "Synthetic rejection" })).StatusCode);
        var resubmit = await PostAsync(anon, $"Second Chance {token}", $"  {adminEmail.ToUpperInvariant()} ", National(), "Pacific/Pago_Pago");
        Assert.Equal(HttpStatusCode.Accepted, resubmit.StatusCode);
        Assert.Equal(1L, await ATz.ScalarAsync<long>(
            "select count(*) from identity.tenant_signup_requests where contact_email = @e and status = 'pending'", ("e", adminEmail)));

        // The fourth stored attempt from this source is refused and writes nothing.
        var overflowEmail = $"overflow-{token}@synthetic.example";
        var overflow = await PostAsync(anon, $"Overflow {token} Hospital", overflowEmail, National(), "UTC");
        Assert.Equal(HttpStatusCode.TooManyRequests, overflow.StatusCode);
        Assert.Contains("\"rate_limited\"", await overflow.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        Assert.Equal(0L, await ATz.ScalarAsync<long>(
            "select count(*) from identity.tenant_signup_requests where contact_email = @e", ("e", overflowEmail)));
    }

    private static async Task<HttpResponseMessage> PostAsync(
        HttpClient anon, string hospitalName, string email, string phone, string timeZone, Guid? tenantId = null) =>
        await anon.PostAsJsonAsync("/api/v1/public/hospital-signups", new
        {
            hospitalName,
            timeZone,
            contactName = "Asha Synthetic",
            contactEmail = email,
            phone = phone.StartsWith('+') || phone.StartsWith('0') ? phone : $"+91{phone}",
            city = "Pune",
            tenantId,
        });

    private static string National()
    {
        var bytes = Guid.NewGuid().ToByteArray();
        var digits = new char[10];
        for (var i = 0; i < 10; i++)
        {
            digits[i] = (char)('0' + (bytes[i] % 10));
        }

        if (digits[0] == '0')
        {
            digits[0] = '6';
        }

        return new string(digits);
    }

    private sealed record DupRequest(
        Guid Id, string HospitalName, string TimeZone, string ContactEmail, Guid? TenantId,
        bool PossibleDuplicate, List<string> MatchedHospitals);
}
