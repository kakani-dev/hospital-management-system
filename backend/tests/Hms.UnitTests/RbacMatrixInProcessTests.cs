using System.Net;
using System.Net.Http.Json;
using System.Text.RegularExpressions;
using Hms.SharedKernel.Tenancy;
using static Hms.UnitTests.InProcessApiTests;

namespace Hms.UnitTests;

/// <summary>
/// RBAC (ADR 0001): role x action authorization matrix through the in-process API pipeline.
/// "Allowed" means the request passes authorization (any status but 403); "denied" means 403.
/// Requests are shaped so an allowed call stops at validation / not-found and writes nothing.
/// </summary>
public sealed class RbacMatrixInProcessTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    private static readonly Guid Missing = Guid.Parse("99999999-9999-4999-8999-999999999999");

    public static readonly (string Name, HttpMethod Method, string Path, string Permission)[] Actions =
    [
        ("patients.list", HttpMethod.Get, "/api/v1/patients", HmsPermissions.PatientsView),
        ("patients.get", HttpMethod.Get, $"/api/v1/patients/{Missing}", HmsPermissions.PatientsView),
        ("patients.create", HttpMethod.Post, "/api/v1/patients", HmsPermissions.PatientsCreate),
        ("patients.edit", HttpMethod.Patch, $"/api/v1/patients/{Missing}", HmsPermissions.PatientsEdit),
        ("patients.delete", HttpMethod.Delete, $"/api/v1/patients/{Missing}", HmsPermissions.PatientsDelete),
        ("patients.restore", HttpMethod.Post, $"/api/v1/patients/{Missing}/restore", HmsPermissions.PatientsRestore),
        ("patients.merge", HttpMethod.Post, $"/api/v1/patients/{Missing}/merge", HmsPermissions.PatientsRestore),
        ("appointments.list", HttpMethod.Get, "/api/v1/appointments", HmsPermissions.AppointmentsView),
        ("appointments.book", HttpMethod.Post, "/api/v1/appointments", HmsPermissions.AppointmentsBook),
        ("appointments.reschedule", HttpMethod.Post, $"/api/v1/appointments/{Missing}/reschedule", HmsPermissions.AppointmentsReschedule),
        ("appointments.cancel", HttpMethod.Post, $"/api/v1/appointments/{Missing}/cancel", HmsPermissions.AppointmentsCancel),
        ("appointments.check_in", HttpMethod.Post, $"/api/v1/appointments/{Missing}/check-in", HmsPermissions.AppointmentsCheckIn),
        ("queue.board", HttpMethod.Get, "/api/v1/queue", HmsPermissions.QueueView),
        ("queue.walk_in", HttpMethod.Post, "/api/v1/queue/walk-in", HmsPermissions.QueueManage),
        ("practitioners.create", HttpMethod.Post, "/api/v1/practitioners", HmsPermissions.PractitionersManage),
        ("schedules.create", HttpMethod.Post, "/api/v1/schedules", HmsPermissions.PractitionersManage),
    ];

    public static TheoryData<string, string> Cases()
    {
        var data = new TheoryData<string, string>();
        foreach (var role in HmsRoles.All.Order(StringComparer.Ordinal))
        {
            foreach (var a in Actions)
            {
                data.Add(role, a.Name);
            }
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public async Task Role_action_matrix_is_enforced(string role, string action)
    {
        var a = Actions.Single(x => x.Name == action);
        using var client = factory.ClientAs(RoleUsers[role]);
        using var request = new HttpRequestMessage(a.Method, a.Path);
        if (a.Method != HttpMethod.Get)
        {
            request.Content = action == "appointments.reschedule"
                ? JsonContent.Create(new { startsAt = "2030-01-07T09:00:00+05:30", endsAt = "2030-01-07T09:15:00+05:30" })
                : JsonContent.Create(new { });
        }

        var response = await client.SendAsync(request);
        // doctors reach the booking endpoint for a follow-up (the body then decides)
        var allowed = HmsPermissions.ByRole[role].Contains(a.Permission)
            || (a.Permission == HmsPermissions.AppointmentsBook && HmsPermissions.ByRole[role].Contains(HmsPermissions.AppointmentsBookFollowUpOwn));
        if (allowed)
        {
            Assert.NotEqual(HttpStatusCode.Forbidden, response.StatusCode);
            Assert.NotEqual(HttpStatusCode.Unauthorized, response.StatusCode);
        }
        else
        {
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
    }

    [Fact]
    public void Matrix_defaults_match_the_adr()
    {
        var p = HmsPermissions.ByRole;
        Assert.True(HmsPermissions.All.All(p[HmsRoles.TenantAdmin].Contains)
                    || HmsPermissions.All.Except(p[HmsRoles.TenantAdmin]).All(x => x.EndsWith("_own", StringComparison.Ordinal) || x == HmsPermissions.ClinicalWrite),
            "tenant_admin holds every tenant permission (own-scoped variants are covered by the full ones)");
        Assert.Contains(HmsPermissions.PatientsCreate, p[HmsRoles.Receptionist]);
        Assert.Contains(HmsPermissions.AppointmentsBook, p[HmsRoles.Receptionist]);
        Assert.DoesNotContain(HmsPermissions.PatientsCreate, p[HmsRoles.Doctor]);
        Assert.Contains(HmsPermissions.PatientsView, p[HmsRoles.Doctor]);
        Assert.Contains(HmsPermissions.AppointmentsCheckIn, p[HmsRoles.Nurse]);
        Assert.Contains(HmsPermissions.AppointmentsBook, p[HmsRoles.Nurse]); // 2026-10-20 business rules
        Assert.DoesNotContain(HmsPermissions.AppointmentsBook, p[HmsRoles.Doctor]);
        Assert.Contains(HmsPermissions.AppointmentsBookFollowUpOwn, p[HmsRoles.Doctor]);
        Assert.Contains(HmsPermissions.AppointmentsOverrideHours, p[HmsRoles.TenantAdmin]);
        Assert.DoesNotContain(HmsPermissions.AppointmentsOverrideHours, p[HmsRoles.Receptionist]);
        foreach (var r in new[] { HmsRoles.Pharmacist, HmsRoles.LabTechnician, HmsRoles.Viewer })
        {
            Assert.DoesNotContain(p[r], x => x.StartsWith("patients.", StringComparison.Ordinal) || x.StartsWith("appointments.", StringComparison.Ordinal) || x.EndsWith(".manage", StringComparison.Ordinal));
        }

        Assert.DoesNotContain(HmsPermissions.All, x => x.StartsWith("platform.", StringComparison.Ordinal));

        // Clinical write is doctor-only (ADR 0003); billing and reception never see clinical notes.
        Assert.Equal([HmsRoles.Doctor], p.Where(kv => kv.Value.Contains(HmsPermissions.ClinicalWrite)).Select(kv => kv.Key).ToArray());
        foreach (var r in new[] { HmsRoles.Billing, HmsRoles.Receptionist, HmsRoles.Accountant, HmsRoles.Pharmacist, HmsRoles.LabTechnician, HmsRoles.Viewer })
        {
            Assert.DoesNotContain(p[r], x => x.StartsWith("clinical.", StringComparison.Ordinal));
        }

        // Dispensing (#106) is pharmacist + tenant admin only.
        Assert.Equal([HmsRoles.Pharmacist, HmsRoles.TenantAdmin],
            p.Where(kv => kv.Value.Contains(HmsPermissions.PharmacyDispense)).Select(kv => kv.Key).Order(StringComparer.Ordinal).ToArray());
        Assert.Equal([HmsRoles.Pharmacist, HmsRoles.TenantAdmin],
            p.Where(kv => kv.Value.Contains(HmsPermissions.PharmacyView)).Select(kv => kv.Key).Order(StringComparer.Ordinal).ToArray());
    }

    [Fact]
    public void Database_matrix_equals_the_api_matrix()
    {
        var dir = AppContext.BaseDirectory;
        while (!Directory.Exists(Path.Combine(dir, "supabase", "migrations")))
        {
            dir = Path.GetDirectoryName(dir) ?? throw new DirectoryNotFoundException("supabase/migrations");
        }

        // the matrix migration plus later grants (20261020140000 business rules)
        var sql = File.ReadAllText(Path.Combine(dir, "supabase", "migrations", "20261020090000_rbac_permission_matrix.sql"))
            + File.ReadAllText(Path.Combine(dir, "supabase", "migrations", "20261020140000_business_rules.sql"))
            + File.ReadAllText(Path.Combine(dir, "supabase", "migrations", "20261023120600_identity_billing_permissions.sql"))
            + File.ReadAllText(Path.Combine(dir, "supabase", "migrations", "20261023170100_identity_inventory_permissions.sql"))
            + File.ReadAllText(Path.Combine(dir, "supabase", "migrations", "20261025220600_identity_privacy_permissions.sql"))
            + File.ReadAllText(Path.Combine(dir, "supabase", "migrations", "20261025250000_identity_accountant_role.sql"))
            + File.ReadAllText(Path.Combine(dir, "supabase", "migrations", "20261026090000_scheduling_clinical_consultations.sql"))
            + File.ReadAllText(Path.Combine(dir, "supabase", "migrations", "20261027150000_inventory_pharmacy_dispense.sql"));
        var db = Regex.Matches(sql, @"\('([a-z_]+)', '([a-z_]+\.[a-z_]+)'\)")
            .Select(m => $"{m.Groups[1].Value}:{m.Groups[2].Value}").Order(StringComparer.Ordinal).ToList();
        var api = HmsPermissions.ByRole.SelectMany(kv => kv.Value.Select(v => $"{kv.Key}:{v}")).Order(StringComparer.Ordinal).ToList();
        Assert.Equal(api, db);

        // apps/web/src/lib/permissions.ts (UX gates) must mirror the same matrix
        var ts = File.ReadAllText(Path.Combine(dir, "apps", "web", "src", "lib", "permissions.ts"));
        var readOnly = Regex.Matches(Regex.Match(ts, @"READ_ONLY_OPS: Permission\[\] = \[(.*?)\]", RegexOptions.Singleline).Groups[1].Value, @"'([a-z_.]+)'")
            .Select(m => m.Groups[1].Value).ToList();
        var block = ts[ts.IndexOf("export const ROLE_PERMISSIONS", StringComparison.Ordinal)..];
        block = block[..block.IndexOf("\n}", StringComparison.Ordinal)];
        var ui = new List<string>();
        foreach (Match m in Regex.Matches(block, @"^\s*(\w+): (?:\[(.*?)\]|READ_ONLY_OPS),?$", RegexOptions.Singleline | RegexOptions.Multiline))
        {
            var perms = m.Groups[2].Success
                ? Regex.Matches(m.Groups[2].Value, @"'([a-z_]+\.[a-z_]+)'").Select(x => x.Groups[1].Value).Concat(m.Groups[2].Value.Contains("READ_ONLY_OPS", StringComparison.Ordinal) ? readOnly : [])
                : readOnly;
            ui.AddRange(perms.Select(p => $"{m.Groups[1].Value}:{p}"));
        }

        Assert.Equal(api, ui.Order(StringComparer.Ordinal).ToList());
    }
}
