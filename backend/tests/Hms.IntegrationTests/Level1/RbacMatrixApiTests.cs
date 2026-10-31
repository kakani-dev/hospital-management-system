using System.Net;
using System.Net.Http.Json;
using Hms.IntegrationTests.AuditTz;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Level1;

public sealed record RbacMe(Guid? ActiveTenantId, List<string> Roles, List<string>? Permissions);

/// <summary>
/// RBAC (ADR 0001): per-role authorization matrix through the YARP edge and the three services,
/// real JWT, real Postgres + RLS. Allowed = anything but 403; denied = 403.
/// Every request is shaped to stop at validation / not-found so nothing is written.
/// </summary>
[Trait("Category", "Database")]
public sealed class RbacMatrixApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly string[] ForgedRoles = ["tenant_admin"];
    private static readonly Guid Missing = Guid.Parse("99999999-9999-4999-8999-999999999999");

    // role -> set of allowed action names (mirror of the ADR table, written out independently of HmsPermissions)
    private static readonly string[] AdminOnly = ["branches.create", "members.list", "invites.list", "settings.update", "practitioners.create", "patients.restore", "patients.merge"];
    private static readonly Dictionary<string, string[]> Allowed = new()
    {
        ["tenant_admin"] = ["patients.list", "patients.create", "patients.edit", "patients.delete", "appointments.list", "appointments.book", "appointments.cancel", "appointments.check_in", "queue.board", "queue.walk_in", "practitioners.list", .. AdminOnly],
        ["receptionist"] = ["patients.list", "patients.create", "patients.edit", "appointments.list", "appointments.book", "appointments.cancel", "appointments.check_in", "queue.board", "queue.walk_in", "practitioners.list"],
        ["nurse"] = ["patients.list", "appointments.list", "appointments.book", "appointments.check_in", "queue.board", "queue.walk_in", "practitioners.list"],
        // doctors reach booking only for a follow-up of an earlier visit (an empty body is 400, a fresh booking 403: BusinessRulesApiTests)
        ["doctor"] = ["patients.list", "appointments.list", "appointments.book", "queue.board", "practitioners.list"],
        ["billing"] = ["patients.list", "appointments.list", "queue.board", "practitioners.list"],
        ["pharmacist"] = ["practitioners.list"],
        ["lab_technician"] = ["practitioners.list"],
        ["viewer"] = ["practitioners.list"],
    };

    private static readonly (string Name, HttpMethod Method, string Path, object? Body)[] Actions =
    [
        ("patients.list", HttpMethod.Get, "/api/v1/patients", null),
        ("patients.create", HttpMethod.Post, "/api/v1/patients", new { }),
        ("patients.edit", HttpMethod.Patch, $"/api/v1/patients/{Missing}", new { lastName = "X" }),
        ("patients.delete", HttpMethod.Delete, $"/api/v1/patients/{Missing}", null),
        ("patients.restore", HttpMethod.Post, $"/api/v1/patients/{Missing}/restore", null),
        ("patients.merge", HttpMethod.Post, $"/api/v1/patients/{Missing}/merge", new { }),
        ("appointments.list", HttpMethod.Get, $"/api/v1/appointments?branchId={AlphaMain}", null),
        ("appointments.book", HttpMethod.Post, "/api/v1/appointments", new { }),
        ("appointments.cancel", HttpMethod.Post, $"/api/v1/appointments/{Missing}/cancel", new { }),
        ("appointments.check_in", HttpMethod.Post, $"/api/v1/appointments/{Missing}/check-in", null),
        ("queue.board", HttpMethod.Get, $"/api/v1/queue?branchId={AlphaMain}", null),
        ("queue.walk_in", HttpMethod.Post, "/api/v1/queue/walk-in", new { }),
        ("practitioners.list", HttpMethod.Get, "/api/v1/practitioners", null),
        ("practitioners.create", HttpMethod.Post, "/api/v1/practitioners", new { }),
        ("branches.create", HttpMethod.Post, "/api/v1/branches", new { }),
        ("members.list", HttpMethod.Get, "/api/v1/members", null),
        ("invites.list", HttpMethod.Get, "/api/v1/members/invite-links", null),
        ("settings.update", HttpMethod.Patch, "/api/v1/tenants/current", new { timeZone = "Not/AZone" }),
    ];

    public static TheoryData<string> Roles() => [.. Allowed.Keys];

    [Theory]
    [MemberData(nameof(Roles))]
    public async Task Every_action_is_allowed_or_403_per_the_matrix(string role)
    {
        var user = await CreateUserAsync($"rbac-{role.Replace('_', '-')}", (Alpha, null, role));
        using var client = factory.ClientAs(user, Alpha);
        var failures = new List<string>();
        foreach (var (name, method, path, body) in Actions)
        {
            using var request = new HttpRequestMessage(method, path) { Content = body is null ? null : JsonContent.Create(body) };
            var status = (await client.SendAsync(request)).StatusCode;
            var expectAllowed = Allowed[role].Contains(name);
            if (expectAllowed ? status is HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized : status != HttpStatusCode.Forbidden)
            {
                failures.Add($"{role} {name}: {(int)status} (expected {(expectAllowed ? "allowed" : "403")})");
            }
        }

        Assert.Empty(failures);
    }

    [Fact]
    public async Task Me_returns_server_side_permissions_and_ignores_client_role_claims()
    {
        var user = await CreateUserAsync("rbac-me", (Alpha, null, "nurse"));
        var token = TestJwt.Create(user, new Dictionary<string, object>
        {
            ["tenant_id"] = Alpha.ToString(),
            ["role"] = "authenticated",
            ["app_metadata"] = new Dictionary<string, object> { ["tenant_id"] = Alpha.ToString(), ["roles"] = ForgedRoles },
        });
        using var client = factory.ClientWithToken(token);
        var me = (await client.GetFromJsonAsync<RbacMe>("/api/v1/me"))!;
        Assert.Equal(["nurse"], me.Roles);
        Assert.Contains("appointments.check_in", me.Permissions!);
        Assert.DoesNotContain("members.manage", me.Permissions!);
        Assert.DoesNotContain("patients.create", me.Permissions!);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/members")).StatusCode);
    }

    [Fact]
    public async Task Doctor_may_mark_no_show_only_on_their_own_appointments()
    {
        var doctor = await CreateUserAsync("rbac-doc", (Alpha, null, "doctor"));
        var own = await ATz.ScalarAsync<Guid>(
            "insert into appointment.practitioners (tenant_id, user_id, display_name) values (@t, @u, 'Dr Rbac (synthetic)') returning id",
            ("t", Alpha), ("u", doctor));
        var other = await ATz.ScalarAsync<Guid>(
            "insert into appointment.practitioners (tenant_id, user_id, display_name) values (@t, @u, 'Dr Other (synthetic)') returning id",
            ("t", Alpha), ("u", await CreateUserAsync("rbac-doc-other", (Alpha, null, "doctor"))));
        var start = DateTimeOffset.UtcNow.AddHours(-2);
        async Task<Guid> Book(Guid practitioner, int minutes)
        {
            await ATz.ScalarAsync<Guid>(
                "insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id) values (@t, @pr, @b) returning id",
                ("t", Alpha), ("pr", practitioner), ("b", AlphaMain));
            return await ATz.ScalarAsync<Guid>(
                "insert into appointment.appointments (tenant_id, branch_id, patient_id, practitioner_id, starts_at, ends_at) values (@t, @b, @p, @pr, @s, @e) returning id",
                ("t", Alpha), ("b", AlphaMain), ("p", AlphaPatientId), ("pr", practitioner), ("s", start.AddMinutes(minutes)), ("e", start.AddMinutes(minutes + 10)));
        }
        var mine = await Book(own, 0);
        var theirs = await Book(other, 20);

        using var client = factory.ClientAs(doctor, Alpha);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync($"/api/v1/appointments/{theirs}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync($"/api/v1/appointments/{theirs}/no-show", null)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.PostAsync($"/api/v1/appointments/{mine}/no-show", null)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsJsonAsync($"/api/v1/appointments/{theirs}/cancel", new { })).StatusCode);
    }
}
