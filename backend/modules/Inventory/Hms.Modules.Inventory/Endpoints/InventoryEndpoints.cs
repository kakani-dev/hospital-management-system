using System.Text.Json;
using Hms.Modules.Inventory.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;

namespace Hms.Modules.Inventory.Endpoints;

public static class InventoryEndpoints
{
    public static RouteGroupBuilder MapInventoryEndpoints(this RouteGroupBuilder api)
    {
        var root = api.MapGroup("/inventory").WithTags("Inventory").RequireTenant().WithDbTransaction<InventoryDbContext>();
        root.MapGet("/items", (InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView, "select inventory.list_items(@t::uuid)::text", ct));
        root.MapPost("/items", (JsonElement body, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
        {
            if (InventoryCodeRules.HasClientSuppliedCode(body))
            {
                return Task.FromResult<IResult>(HmsProblems.BadRequest(
                    HmsProblems.Codes.InvalidParameter, InventoryCodeRules.ClientSuppliedCodeDetail));
            }

            return Write(db, tenant, HmsPermissions.InventoryCatalog, "select inventory.create_item(@t::uuid, @b::jsonb)::text", body, ct);
        });
        root.MapGet("/stores", (InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView, "select inventory.list_stores(@t::uuid)::text", ct));
        root.MapPost("/stores", (JsonElement body, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
        {
            if (InventoryCodeRules.HasClientSuppliedCode(body))
            {
                return Task.FromResult<IResult>(HmsProblems.BadRequest(
                    HmsProblems.Codes.InvalidParameter, InventoryCodeRules.ClientSuppliedCodeDetail));
            }

            return Write(db, tenant, HmsPermissions.InventoryCatalog, "select inventory.create_store(@t::uuid, @b::jsonb)::text", body, ct);
        });
        root.MapPost("/opening-stock", PostOpeningAsync);
        // Pharmacy barcode scanning: a GS1 GTIN-14 links once to a catalogue item in this hospital.
        root.MapGet("/gtin/{gtin}", (string gtin, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView, "select inventory.resolve_gtin(@t::uuid, @g)::text", ct, ("g", gtin)));
        root.MapPost("/gtin", (JsonElement body, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            body.ValueKind != JsonValueKind.Object
                ? Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Body must be a JSON object."))
                : Write(db, tenant, HmsPermissions.InventoryCatalog, "select inventory.link_gtin(@t::uuid, @b::jsonb)::text", body, ct));
        root.MapGet("/stock", (Guid? storeId, Guid? itemId, bool? lowStock, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView,
                "select inventory.stock_on_hand(@t::uuid, @s::uuid, @i::uuid, @low::boolean)::text", ct,
                ("s", storeId), ("i", itemId), ("low", lowStock == true)));
        // Pharmacy stock and expiry alerts: below reorder level, expired and near-expiry batches (FEFO order).
        root.MapGet("/stock/alerts", (Guid? branchId, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView,
                "select inventory.stock_alerts(@t::uuid, @br::uuid)::text", ct, ("br", branchId)));
        root.MapGet("/settings", (InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView, "select pharmacy.get_settings(@t::uuid)::text", ct));
        root.MapPut("/settings", (JsonElement body, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            body.ValueKind != JsonValueKind.Object
                ? Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Body must be a JSON object."))
                : Write(db, tenant, HmsPermissions.SettingsManage, "select pharmacy.set_alert_settings(@t::uuid, @b::jsonb)::text", body, ct));
        root.MapPut("/stores/{storeId:guid}/items/{itemId:guid}/reorder", (Guid storeId, Guid itemId, JsonElement body, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            body.ValueKind != JsonValueKind.Object
                ? Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Body must be a JSON object."))
                : Exec(db, tenant, HmsPermissions.InventoryCatalog,
                    "select inventory.set_reorder_policy(@t::uuid, @s::uuid, @i::uuid, @b::jsonb)::text", ct,
                    ("s", storeId), ("i", itemId), ("b", body.GetRawText())));
        root.MapGet("/fefo", (Guid storeId, Guid itemId, long? qty, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView,
                "select inventory.fefo_pick_v1(@t::uuid, @s::uuid, @i::uuid, @q::bigint)::text", ct,
                ("s", storeId), ("i", itemId), ("q", qty)));

        // #106 pharmacy dispensing (ADR 0004: the pharmacy schema lives in the inventory service). The tenant
        // always comes from the server-resolved context; branch scope is enforced again in the database.
        root.MapGet("/pharmacy/queue", (Guid? branchId, string? status, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PharmacyView,
                "select pharmacy.list_queue(@t::uuid, @br::uuid, @st::text)::text", ct,
                ("br", branchId), ("st", status)));
        root.MapGet("/pharmacy/prescriptions/{id:guid}", (Guid id, Guid? storeId, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PharmacyView,
                "select pharmacy.get_prescription(@t::uuid, @id::uuid, @s::uuid)::text", ct,
                ("id", id), ("s", storeId)));
        root.MapPost("/pharmacy/dispenses", PostDispenseAsync);
        return api;
    }

    private static async Task<IResult> PostOpeningAsync(
        HttpRequest request, JsonElement body, InventoryDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (InventoryCodeRules.HasClientSuppliedCode(body))
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, InventoryCodeRules.ClientSuppliedCodeDetail);
        }

        if (!request.Headers.TryGetValue("Idempotency-Key", out var raw) || !Guid.TryParse(raw, out var key))
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Idempotency-Key must be a UUID.");
        }

        if (InventoryCodeRules.HasTooManyOpeningLines(body))
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, InventoryCodeRules.TooManyOpeningLinesDetail);
        }

        if (!tenant.Can(HmsPermissions.InventoryOpening) || !tenant.Can(HmsPermissions.InventoryApprove))
        {
            return HmsProblems.Forbidden();
        }

        return await Exec(db, tenant, HmsPermissions.InventoryOpening,
            "select inventory.post_opening_stock(@t::uuid, @k::uuid, @b::jsonb)::text", ct,
            ("k", key), ("b", body.GetRawText()));
    }

    private static Task<IResult> PostDispenseAsync(
        HttpRequest request, JsonElement body, InventoryDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!request.Headers.TryGetValue("Idempotency-Key", out var raw) || !Guid.TryParse(raw, out var key))
        {
            return Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Idempotency-Key must be a UUID."));
        }

        if (body.ValueKind != JsonValueKind.Object)
        {
            return Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Body must be a JSON object."));
        }

        return Exec(db, tenant, HmsPermissions.PharmacyDispense,
            "select pharmacy.dispense(@t::uuid, @k::uuid, @b::jsonb)::text", ct,
            ("k", key), ("b", body.GetRawText()));
    }

    private static Task<IResult> Write(InventoryDbContext db, ITenantContext tenant, string permission, string sql, JsonElement body, CancellationToken ct) =>
        Exec(db, tenant, permission, sql, ct, ("b", body.GetRawText()));

    private static async Task<IResult> Exec(
        InventoryDbContext db, ITenantContext tenant, string permission, string sql, CancellationToken ct, params (string Name, object? Value)[] extra)
    {
        if (!tenant.Can(permission))
        {
            return HmsProblems.Forbidden();
        }

        var args = new List<(string Name, object? Value)>(extra.Length + 1) { ("t", tenant.TenantId) };
        args.AddRange(extra);
        try
        {
            var value = await RawSql.ScalarAsync(db, sql, ct, [.. args]);
            return Results.Text(value?.ToString() ?? "null", "application/json");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }
}
