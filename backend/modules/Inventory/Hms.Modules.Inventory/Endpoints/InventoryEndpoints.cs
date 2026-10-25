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
        root.MapGet("/stock", (Guid? storeId, Guid? itemId, bool? lowStock, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView,
                "select inventory.stock_on_hand(@t::uuid, @s::uuid, @i::uuid, @low::boolean)::text", ct,
                ("s", storeId), ("i", itemId), ("low", lowStock == true)));
        root.MapGet("/fefo", (Guid storeId, Guid itemId, long? qty, InventoryDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.InventoryView,
                "select inventory.fefo_pick_v1(@t::uuid, @s::uuid, @i::uuid, @q::bigint)::text", ct,
                ("s", storeId), ("i", itemId), ("q", qty)));
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

        if (!tenant.Can(HmsPermissions.InventoryOpening) || !tenant.Can(HmsPermissions.InventoryApprove))
        {
            return HmsProblems.Forbidden();
        }

        return await Exec(db, tenant, HmsPermissions.InventoryOpening,
            "select inventory.post_opening_stock(@t::uuid, @k::uuid, @b::jsonb)::text", ct,
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
