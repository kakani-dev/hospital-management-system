using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.AuditTz;

// Wire mirrors (db/audit-tz: audit columns + tenant time zone).
public sealed record ATzBranch(Guid Id, string Code, string Name, string Timezone, bool IsActive, string? TimezoneOverride, bool IsDeleted);

public sealed record ATzTenant(Guid Id, string Code, string Name, Guid? ActiveBranchId, List<string> Roles, string TimeZone);

public sealed record ATzBranchOption(Guid Id, string Name, string? TimeZone);

public sealed record ATzMe(Guid UserId, Guid? TenantId, Guid? BranchId, List<ATzBranchOption> AccessibleBranches, string? TimeZone);

public sealed record ATzMember(Guid Id, Guid UserId, string? Email, string Role, Guid? BranchId, string Status);

public sealed record ATzInvitation(Guid MembershipId, Guid TenantId);

public sealed record ATzPractitioner(Guid Id, string DisplayName, bool IsActive);

public sealed record ATzSchedule(Guid Id, Guid PractitionerId, Guid BranchId, int Weekday, DateOnly ValidFrom);

public sealed record ATzPatient(Guid Id, string Mrn, DateTimeOffset CreatedOn, DateTimeOffset UpdatedOn);

/// <summary>A newly created tenant (identity.create_tenant) with an accepted tenant_admin.</summary>
public sealed record ATzTenantFixture(Guid TenantId, string Code, Guid AdminId, Guid MainBranchId);

/// <summary>TimeProvider whose "now" the test sets (the API's branch-local "today" comes from it).</summary>
public sealed class ATzClock : TimeProvider
{
    public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;

    public override DateTimeOffset GetUtcNow() => Now;
}

/// <summary>API (every in-process host) with a settable clock. One instance per test class (tests in a class run sequentially).</summary>
public sealed class FixedClockApiFactory : HmsApiFactory
{
    public ATzClock Clock { get; } = new();

    protected override void ConfigureHost(IWebHostBuilder builder)
    {
        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<TimeProvider>();
            services.AddSingleton<TimeProvider>(Clock);
        });
    }
}

internal static class ATz
{
    /// <summary>audit.system_actor(): the fixed "MediCore System" actor (no auth.users row).</summary>
    public static readonly Guid SystemActor = Guid.Parse("00000000-0000-4000-8000-00000000005e");

    public static string Code(string prefix = "atz") => $"{prefix}-{Guid.NewGuid():N}"[..16];

    public static async Task<T?> ScalarAsync<T>(string sql, params (string Name, object? Value)[] parameters)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(sql, conn);
        foreach (var (name, value) in parameters)
        {
            cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        }

        var result = await cmd.ExecuteScalarAsync();
        return result is null or DBNull ? default : (T)result;
    }

    public static async Task<T> ReadAsync<T>(HttpResponseMessage response, HttpStatusCode expected)
    {
        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.StatusCode == expected, $"Expected {(int)expected}, got {(int)response.StatusCode}: {body}");
        return (await response.Content.ReadFromJsonAsync<T>())!;
    }

    public static async Task<string?> CodeAsync(HttpResponseMessage response) => await Sprint2.S2.CodeAsync(response);

    /// <summary>
    /// Creates a tenant with identity.create_tenant as a trusted caller (what the identity service will
    /// do; the monolith has no create-tenant endpoint, code review MIN-5), then the invited admin
    /// accepts the invitation through /me/invitations, exactly as a real onboarding would.
    /// </summary>
    public static async Task<ATzTenantFixture> NewTenantAsync(HmsApiFactory factory, string timeZone = "Asia/Kolkata")
    {
        var adminId = await CreateUserAsync("atz-admin");
        var email = await EmailOfAsync(adminId);
        var code = Code();
        var tenantId = await ScalarAsync<Guid>(
            "select identity.create_tenant(@code, @name, @zone, @email)",
            ("code", code), ("name", $"Synthetic {code}"), ("zone", timeZone), ("email", email));

        using var invitee = factory.ClientAs(adminId);
        var invitations = await invitee.GetFromJsonAsync<List<ATzInvitation>>("/api/v1/me/invitations");
        var invitation = Assert.Single(invitations!, i => i.TenantId == tenantId);
        Assert.Equal(HttpStatusCode.NoContent, (await invitee.PostAsync($"/api/v1/me/invitations/{invitation.MembershipId}/accept", content: null)).StatusCode);

        var main = await ScalarAsync<Guid>("select id from identity.branches where tenant_id = @t", ("t", tenantId));
        return new ATzTenantFixture(tenantId, code, adminId, main);
    }

    public static async Task<ATzBranch> CreateBranchAsync(HttpClient admin, string? timezone)
    {
        return await ReadAsync<ATzBranch>(
            await admin.PostAsJsonAsync("/api/v1/branches", new { code = Code("b"), name = $"Synthetic branch {Code("n")}", timezone }),
            HttpStatusCode.Created);
    }

    public static async Task<ATzPractitioner> CreatePractitionerAsync(HttpClient admin)
    {
        var practitioner = await ReadAsync<ATzPractitioner>(
            await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = $"Dr {Code("p")} (synthetic)", specialty = "General" }),
            HttpStatusCode.Created);
        await TestSchedules.OpenAllHoursAsync(practitioner.Id);
        return practitioner;
    }
}
