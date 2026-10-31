using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Hms.Modules.Appointments.Functions;
using Hms.Modules.Appointments.Persistence;
using Hms.Modules.Identity.Persistence;
using Hms.Platform.Tenancy;
using Hms.Modules.Patients.Persistence;
using Hms.Modules.Patients.Registry;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Hms.UnitTests;

/// <summary>
/// The real gateway pipeline (middleware order, endpoints, filters, validators) in-process, with
/// EF InMemory instead of PostgreSQL, a fake membership store and a header-driven test auth
/// scheme. No database needed, so these run in the unit job. RLS/SQL behaviour is covered by
/// Hms.IntegrationTests / Hms.DatabaseTests against real Postgres.
/// </summary>
public sealed class InProcessApiTests : IClassFixture<InProcessApiTests.ApiFactory>
{
    internal static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    internal static readonly Guid Main = Guid.Parse("a1111111-0000-4000-8000-000000000001"); // Asia/Kolkata
    internal static readonly Guid East = Guid.Parse("a1111111-0000-4000-8000-000000000002"); // UTC
    internal static readonly Guid BetaMain = Guid.Parse("b2222222-0000-4000-8000-000000000001");

    /// <summary>billing at Main + nurse at East (review M1 PoC P2).</summary>
    internal static readonly Guid MixedUser = Guid.Parse("0d000000-0000-4000-8000-000000000001");
    internal static readonly Guid BillingOnly = Guid.Parse("0d000000-0000-4000-8000-000000000002");
    internal static readonly Guid Admin = Guid.Parse("0d000000-0000-4000-8000-000000000003");
    internal static readonly Guid LabTech = Guid.Parse("0d000000-0000-4000-8000-000000000004");

    /// <summary>doctor at Main + receptionist at East (Sprint 2 edit/delete matrix).</summary>
    internal static readonly Guid DoctorMainReceptionEast = Guid.Parse("0d000000-0000-4000-8000-000000000005");

    /// <summary>RBAC matrix users: one tenant-wide user per role (Main + East), 0e000000-...-00000000000N.</summary>
    internal static readonly IReadOnlyDictionary<string, Guid> RoleUsers = HmsRoles.All.Order(StringComparer.Ordinal)
        .Select((role, i) => (role, id: Guid.Parse($"0e000000-0000-4000-8000-{i + 1:D12}")))
        .ToDictionary(x => x.role, x => x.id, StringComparer.Ordinal);

    /// <summary>2026-10-06 20:00 UTC = 2026-10-07 01:30 in Asia/Kolkata.</summary>
    internal static readonly DateTimeOffset Now = new(2026, 10, 6, 20, 0, 0, TimeSpan.Zero);

    private readonly ApiFactory _factory;

    public InProcessApiTests(ApiFactory factory) => _factory = factory;

    private static string NewMrn(string prefix = "t") => $"{prefix}-{Guid.NewGuid():N}"[..20];

    // Each chart gets its own name. The in-memory registry is shared by this class, and a repeated
    // name is now a 409 until a reason is stored. Tests that care about the name pass their own.
    private static object NewPatient(Guid branch, string? mrn = null, string? dob = null) =>
        new { mrn = mrn ?? NewMrn(), firstName = "Test", lastName = $"P{Guid.NewGuid():N}"[..12], registeredBranchId = branch, dateOfBirth = dob, sex = "unknown", ageYears = 30, noPhoneReason = "test fixture", details = new { guardianName = "Zz-QA Guardian" } };

    [Fact]
    public async Task M1_role_at_another_branch_does_not_authorize_writes_here()
    {
        using var client = _factory.ClientAs(DoctorMainReceptionEast);
        var atMain = await client.PostAsJsonAsync("/api/v1/patients", NewPatient(Main));
        Assert.Equal(HttpStatusCode.Forbidden, atMain.StatusCode); // RBAC: doctor at Main is view-only

        var atEast = await client.PostAsJsonAsync("/api/v1/patients", NewPatient(East));
        Assert.Equal(HttpStatusCode.Created, atEast.StatusCode); // receptionist at East

        using var mixed = _factory.ClientAs(MixedUser); // billing @Main, nurse @East: RBAC makes both view-only
        Assert.Equal(HttpStatusCode.Forbidden, (await mixed.PostAsJsonAsync("/api/v1/patients", NewPatient(East))).StatusCode);

        // Reads stay tenant-wide for clinical roles.
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task M1_read_only_role_cannot_write_anywhere_and_foreign_branch_is_refused()
    {
        using var billing = _factory.ClientAs(BillingOnly);
        Assert.Equal(HttpStatusCode.Forbidden, (await billing.PostAsJsonAsync("/api/v1/patients", NewPatient(Main))).StatusCode);

        using var admin = _factory.ClientAs(Admin);
        // 404-not-403 (CTO 16:49): another tenant's branch is 404; a same-tenant branch without a write role stays 403.
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsJsonAsync("/api/v1/patients", NewPatient(BetaMain))).StatusCode);
        using var mixed = _factory.ClientAs(MixedUser); // billing @Main, nurse @East
        Assert.Equal(HttpStatusCode.Forbidden, (await mixed.PostAsJsonAsync("/api/v1/patients", NewPatient(Main))).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/patients", NewPatient(Main))).StatusCode);
    }

    [Fact]
    public async Task Mrn_is_generated_server_side_and_a_client_mrn_is_ignored()
    {
        using var client = _factory.ClientAs(Admin);
        var typed = NewMrn("typed");
        var first = await client.PostAsJsonAsync("/api/v1/patients", NewPatient(Main, typed));
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);
        var a = (await first.Content.ReadFromJsonAsync<PatientBody>())!;
        Assert.NotEqual(typed.ToUpperInvariant(), a.Mrn);
        Assert.Matches("^[A-Z0-9-]+-[0-9]{6,}$", a.Mrn);

        // the same typed value again is not a conflict any more: it is simply ignored
        var second = await client.PostAsJsonAsync("/api/v1/patients", NewPatient(Main, typed));
        Assert.Equal(HttpStatusCode.Created, second.StatusCode);
        Assert.NotEqual(a.Mrn, (await second.Content.ReadFromJsonAsync<PatientBody>())!.Mrn);
    }

    [Fact]
    public async Task Date_of_birth_today_is_judged_in_the_branch_time_zone()
    {
        using var client = _factory.ClientAs(Admin);
        // 2026-10-07 is already "today" in Kolkata (Main) but still tomorrow in UTC (East).
        Assert.Equal(HttpStatusCode.Created, (await client.PostAsJsonAsync("/api/v1/patients", NewPatient(Main, dob: "2026-10-07"))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/v1/patients", NewPatient(East, dob: "2026-10-07"))).StatusCode);
    }

    [Fact]
    public async Task Phone_and_email_lengths_are_validated()
    {
        using var client = _factory.ClientAs(Admin);
        var response = await client.PostAsJsonAsync("/api/v1/patients", new
        {
            mrn = NewMrn(), firstName = "Long", lastName = "Contact", registeredBranchId = Main,
            phone = new string('9', 33), email = new string('a', 250) + "@x.example", sex = "unknown", ageYears = 30, noPhoneReason = "test fixture"
        });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var text = await response.Content.ReadAsStringAsync();
        Assert.Contains("\"phone\"", text, StringComparison.Ordinal);
        Assert.Contains("\"email\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Search_uses_a_post_body_and_the_get_query_parameter_is_rejected()
    {
        using var client = _factory.ClientAs(Admin);
        var last = $"Findme{Guid.NewGuid():N}"[..20];
        var created = await client.PostAsJsonAsync("/api/v1/patients", new { mrn = NewMrn(), firstName = "Search", lastName = last, registeredBranchId = Main, sex = "unknown", ageYears = 30, noPhoneReason = "test fixture" });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);

        var search = await client.PostAsJsonAsync("/api/v1/patients/search", new { search = last.ToLowerInvariant(), page = 1, pageSize = 10 });
        Assert.Equal(HttpStatusCode.OK, search.StatusCode);
        var page = await search.Content.ReadFromJsonAsync<PageBody>();
        Assert.Single(page!.Items);
        Assert.Equal(last, page.Items[0].LastName);
        Assert.Equal(1, page.TotalCount);

        Assert.Equal(HttpStatusCode.BadRequest, (await client.GetAsync($"/api/v1/patients?search={last}")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/api/v1/patients?page=1&pageSize=5")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/v1/patients/search", new { search = new string('x', 101) })).StatusCode);

        using var lab = _factory.ClientAs(LabTech);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PostAsJsonAsync("/api/v1/patients/search", new { search = "a" })).StatusCode);
    }

    [Fact]
    public async Task Authenticated_responses_carry_the_resolved_tenant_header()
    {
        using var client = _factory.ClientAs(Admin);
        var ok = await client.GetAsync("/api/v1/patients");
        Assert.Equal(Alpha.ToString(), Assert.Single(ok.Headers.GetValues(HmsHeaders.Tenant)));

        // Also on error responses (validation / authorization) for a resolved tenant.
        var bad = await client.PostAsJsonAsync("/api/v1/patients", new { mrn = "", firstName = "", lastName = "", registeredBranchId = Main, sex = "unknown", ageYears = 30, noPhoneReason = "test fixture" });
        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
        Assert.Equal(Alpha.ToString(), Assert.Single(bad.Headers.GetValues(HmsHeaders.Tenant)));

        using var anonymous = _factory.CreateClient();
        var unauthorized = await anonymous.GetAsync("/api/v1/patients");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);
        Assert.False(unauthorized.Headers.Contains(HmsHeaders.Tenant));
    }

    [Fact]
    public async Task Cors_exposes_the_tenant_header_to_the_spa()
    {
        using var client = _factory.ClientAs(Admin);
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v1/patients");
        request.Headers.Add("Origin", "http://localhost:5173");
        var response = await client.SendAsync(request);
        var exposed = string.Join(",", response.Headers.GetValues("Access-Control-Expose-Headers"));
        Assert.Contains(HmsHeaders.Tenant, exposed, StringComparison.OrdinalIgnoreCase);
        // Export downloads take their file name from Content-Disposition (#90).
        Assert.Contains("Content-Disposition", exposed, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Add_member_validation_and_authorization_errors_are_unchanged()
    {
        using var admin = _factory.ClientAs(Admin);
        var scopedAdmin = await admin.PostAsJsonAsync("/api/v1/members", new { email = "x@synthetic.example", role = "tenant_admin", branchId = Main });
        Assert.Equal(HttpStatusCode.BadRequest, scopedAdmin.StatusCode);

        using var nurse = _factory.ClientAs(MixedUser);
        Assert.Equal(HttpStatusCode.Forbidden, (await nurse.PostAsJsonAsync("/api/v1/members", new { email = "x@synthetic.example", role = "doctor" })).StatusCode);
    }

    [Fact]
    public async Task Rate_limiter_runs_before_tenant_resolution()
    {
        var store = new FakeMembershipStore();
        await using var limited = _factory.WithWebHostBuilder(b =>
        {
            b.UseSetting("RateLimiting:PermitPerMinute", "2");
            b.ConfigureTestServices(s => s.AddSingleton<IMembershipStore>(store));
        });
        using var client = limited.CreateClient();
        client.DefaultRequestHeaders.Add(TestAuthHandler.UserHeader, Admin.ToString());

        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/api/v1/patients")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/api/v1/patients")).StatusCode);
        Assert.Equal(2, store.GrantLookups);

        Assert.Equal(HttpStatusCode.TooManyRequests, (await client.GetAsync("/api/v1/patients")).StatusCode);
        Assert.Equal(2, store.GrantLookups); // throttled request never reached the membership DB lookups
    }

    private sealed record PatientBody(Guid Id, string Mrn, string FirstName, string LastName, Guid RegisteredBranchId);

    private sealed record PageBody(List<PatientBody> Items, int Page, int PageSize, int TotalCount);

    public sealed class ApiFactory : WebApplicationFactory<Program>
    {
        private readonly string _db = Guid.NewGuid().ToString();

        public HttpClient ClientAs(Guid user)
        {
            var client = CreateClient();
            client.DefaultRequestHeaders.Add(TestAuthHandler.UserHeader, user.ToString());
            return client;
        }

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment("Testing");
            builder.UseSetting("RateLimiting:PermitPerMinute", "100000");
            builder.ConfigureLogging(l => l.ClearProviders());
            builder.ConfigureTestServices(services =>
            {
                ReplaceWithInMemory<PatientsDbContext>(services, _db + "-patients");
                ReplaceWithInMemory<IdentityDbContext>(services, _db + "-identity");
                ReplaceWithInMemory<AppointmentsDbContext>(services, _db + "-appointments");
                services.RemoveAll<IAppointmentFunctions>();
                services.AddSingleton<IAppointmentFunctions, UnavailableAppointmentFunctions>();
                services.RemoveAll<IPatientSummaries>();
                services.AddSingleton<InMemoryPatientSummaries>();
                services.AddSingleton<IPatientSummaries>(sp => sp.GetRequiredService<InMemoryPatientSummaries>());
                services.RemoveAll<IPatientRegistryFunctions>();
                services.AddScoped<IPatientRegistryFunctions, InMemoryPatientRegistryFunctions>();
                services.RemoveAll<IMembershipStore>();
                services.AddSingleton<IMembershipStore, FakeMembershipStore>();
                services.RemoveAll<TimeProvider>();
                services.AddSingleton<TimeProvider>(new FixedClock(Now));
                services.AddAuthentication(TestAuthHandler.SchemeName).AddScheme<AuthenticationSchemeOptions, TestAuthHandler>(TestAuthHandler.SchemeName, _ => { });
                services.PostConfigure<AuthenticationOptions>(o =>
                {
                    o.DefaultScheme = TestAuthHandler.SchemeName;
                    o.DefaultAuthenticateScheme = TestAuthHandler.SchemeName;
                    o.DefaultChallengeScheme = TestAuthHandler.SchemeName;
                });
            });
        }

        private static void ReplaceWithInMemory<TContext>(IServiceCollection services, string name)
            where TContext : DbContext
        {
            services.RemoveAll<DbContextOptions<TContext>>();
            services.RemoveAll<IDbContextOptionsConfiguration<TContext>>();
            services.AddDbContext<TContext>((sp, o) => o
                .UseInMemoryDatabase(name)
                .AddInterceptors(sp.GetRequiredService<TenantSaveChangesInterceptor>(), new FakeMrnTrigger()));
        }
    }

    internal sealed class FakeMembershipStore : IMembershipStore
    {
        private static readonly Dictionary<Guid, string> TimeZones = new() { [Main] = "Asia/Kolkata", [East] = "UTC" };

        private int _grantLookups;

        public int GrantLookups => _grantLookups;

        public Task<MembershipGrant?> FindActiveGrantAsync(Guid userId, Guid tenantId, Guid? branchId, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref _grantLookups);
            Dictionary<Guid, IReadOnlyCollection<string>>? map =
                tenantId != Alpha ? null
                : userId == MixedUser ? new() { [Main] = [HmsRoles.Billing], [East] = [HmsRoles.Nurse] }
                : userId == BillingOnly ? new() { [Main] = [HmsRoles.Billing], [East] = [HmsRoles.Billing] }
                : userId == Admin ? new() { [Main] = [HmsRoles.TenantAdmin], [East] = [HmsRoles.TenantAdmin] }
                : userId == LabTech ? new() { [Main] = [HmsRoles.LabTechnician] }
                : userId == DoctorMainReceptionEast ? new() { [Main] = [HmsRoles.Doctor], [East] = [HmsRoles.Receptionist] }
                : RoleUsers.FirstOrDefault(kv => kv.Value == userId).Key is { } role ? new() { [Main] = [role], [East] = [role] }
                : null;
            if (map is null)
            {
                return Task.FromResult<MembershipGrant?>(null);
            }

            var roles = map.Values.SelectMany(r => r).Distinct(StringComparer.Ordinal).ToList();
            var branches = map.Keys.ToList();
            return Task.FromResult<MembershipGrant?>(new MembershipGrant(
                roles, branches, map, branches.ToDictionary(b => b, b => TimeZones[b]), "Asia/Kolkata"));
        }

        public Task<ActiveContext?> FindDefaultContextAsync(CancellationToken cancellationToken) =>
            Task.FromResult<ActiveContext?>(null);
    }

    /// <summary>Authenticates "X-Test-User: &lt;uuid&gt;" as that user with tenant_id = Alpha.</summary>
    internal sealed class TestAuthHandler(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
        : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
    {
        public const string SchemeName = "Test";
        public const string UserHeader = "X-Test-User";

        protected override Task<AuthenticateResult> HandleAuthenticateAsync()
        {
            if (!Request.Headers.TryGetValue(UserHeader, out var user))
            {
                return Task.FromResult(AuthenticateResult.NoResult());
            }

            var identity = new ClaimsIdentity(
                [new Claim("sub", user.ToString()), new Claim("role", "authenticated"), new Claim("tenant_id", Alpha.ToString())],
                SchemeName);
            return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), SchemeName)));
        }
    }
}
