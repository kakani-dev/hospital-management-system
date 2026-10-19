using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Pr1Regression;

/// <summary>
/// PR #1 review finding M2: created_by / deleted_at (and the other audit columns) were
/// client-writable on INSERT and the audit trigger kept a client-supplied created_by.
///
/// Scope change (21:20 IST): the DB hardening for M2 (actor-wins trigger, revoked column grants) is
/// DEFERRED, so direct table writes are NOT tested here. This class asserts only the API-level
/// guarantee: forged server-owned fields sent THROUGH THE API are ignored / overwritten, verified by
/// reading back via the API and the DB.
/// </summary>
[Trait("Category", "Database")]
public sealed class M2ServerOwnedFieldsApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly DateTimeOffset Forged = new(2000, 1, 1, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task M2_forged_audit_fields_on_create_are_ignored_and_server_set()
    {
        var forgedId = Guid.NewGuid();
        var mrn = Pr1Db.NewMrn("M2C");
        var body = new Dictionary<string, object?>
        {
            ["mrn"] = mrn,
            ["firstName"] = "Forged",
            ["lastName"] = "Audit",
            ["registeredBranchId"] = AlphaMain,
            // Server-owned fields, in both the API's camelCase and the DB's snake_case spelling.
            ["id"] = forgedId,
            ["tenantId"] = Beta, ["tenant_id"] = Beta,
            ["createdBy"] = AlphaAdmin, ["created_by"] = AlphaAdmin,
            ["updatedBy"] = AlphaAdmin, ["updated_by"] = AlphaAdmin,
            ["createdAt"] = Forged, ["created_at"] = Forged,
            ["updatedAt"] = Forged, ["updated_at"] = Forged,
            ["createdOn"] = Forged, ["created_on"] = Forged,
            ["updatedOn"] = Forged, ["updated_on"] = Forged,
            ["isDeleted"] = true, ["is_deleted"] = true,
            ["deletedAt"] = DateTimeOffset.UtcNow, ["deleted_at"] = DateTimeOffset.UtcNow,
        };

        var started = DateTimeOffset.UtcNow;
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        var response = await reception.PostAsJsonAsync("/api/v1/patients", body);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var created = await response.Content.ReadFromJsonAsync<PatientView>();
        Assert.NotEqual(forgedId, created!.Id);

        // Read back through the API: the row is not "born soft-deleted" (it would be filtered out).
        Assert.Equal(HttpStatusCode.OK, (await reception.GetAsync($"/api/v1/patients/{created.Id}")).StatusCode);
        var page = await reception.GetFromJsonAsync<PagedView<PatientView>>("/api/v1/patients?pageSize=100");
        Assert.Contains(page!.Items, p => p.Id == created.Id);

        // Read back the persisted columns.
        var stored = await Pr1Db.PatientAuditAsync(created.Id);
        Assert.NotNull(stored);
        Assert.Equal(Alpha, stored.TenantId);
        Assert.Equal(AlphaReception, stored.CreatedBy);
        Assert.Equal(AlphaReception, stored.UpdatedBy);
        Assert.Null(stored.DeletedAt);
        Assert.InRange(stored.CreatedOn, started.AddMinutes(-5), DateTimeOffset.UtcNow.AddMinutes(5));
        Assert.InRange(stored.UpdatedOn, started.AddMinutes(-5), DateTimeOffset.UtcNow.AddMinutes(5));
        Assert.Null(await Pr1Db.PatientAuditAsync(forgedId));
    }
}
