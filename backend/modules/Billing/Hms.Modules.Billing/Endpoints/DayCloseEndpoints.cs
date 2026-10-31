using System.Text.Json;
using System.Text.Json.Nodes;
using Hms.Modules.Billing.DayClose;
using Hms.Modules.Billing.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Billing.Endpoints;

/// <summary>
/// #65: day-end close for every method on one screen. Cash per drawer (count, reason, handover),
/// card/UPI/bank settled per payment account for the branch-day, and a supervisor sign-off that
/// locks the day. The tenant is always the server-side tenant.
/// </summary>
public static class DayCloseEndpoints
{
    public static RouteGroupBuilder MapDayCloseEndpoints(this RouteGroupBuilder api)
    {
        var g = api.MapGroup("/billing-reports/day-close").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        g.MapGet("/", SummaryAsync);
        g.MapPost("/sessions/{id:guid}/close", CloseAsync);
        g.MapPost("/handovers/{id:guid}/receive", ReceiveAsync);
        g.MapPut("/settlements", SettleAsync);
        g.MapPost("/signoff", SignoffAsync);
        return api;
    }

    private static Task<IResult> SummaryAsync(
        Guid branchId, DateOnly date, BillingDbContext db, ITenantContext tenant, IOptions<DayCloseOptions> options, CancellationToken ct) =>
        Run(db, tenant, HmsPermissions.BillingView, options.Value,
            "select billing.day_close_summary(@t::uuid, @b::uuid, @d::date)::text", ct, ("b", branchId), ("d", date));

    private static Task<IResult> CloseAsync(
        Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, IOptions<DayCloseOptions> options, CancellationToken ct)
    {
        var errors = DayCloseValidation.CheckClose(body, options.Value.MaxReasonLength);
        return errors.Count > 0
            ? Task.FromResult<IResult>(TypedResults.ValidationProblem(errors))
            : Run(db, tenant, HmsPermissions.BillingCollect, null,
                "select billing.close_counter_session(@t::uuid, @s::uuid, @j::jsonb)::text", ct, ("s", id), ("j", body.GetRawText()));
    }

    private static Task<IResult> ReceiveAsync(Guid id, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
        Run(db, tenant, HmsPermissions.BillingCollect, null, "select billing.receive_handover(@t::uuid, @h::uuid)::text", ct, ("h", id));

    private static Task<IResult> SettleAsync(
        Guid branchId, DateOnly date, JsonElement body, BillingDbContext db, ITenantContext tenant, IOptions<DayCloseOptions> options, CancellationToken ct)
    {
        var errors = DayCloseValidation.CheckSettlements(body, options.Value.MaxReasonLength);
        return errors.Count > 0
            ? Task.FromResult<IResult>(TypedResults.ValidationProblem(errors))
            : Run(db, tenant, HmsPermissions.BillingCollect, options.Value,
                "select billing.record_settlements(@t::uuid, @b::uuid, @d::date, @j::jsonb)::text", ct,
                ("b", branchId), ("d", date), ("j", body.GetRawText()));
    }

    private static Task<IResult> SignoffAsync(
        Guid branchId, DateOnly date, JsonElement body, BillingDbContext db, ITenantContext tenant, IOptions<DayCloseOptions> options, CancellationToken ct)
    {
        var raw = body.ValueKind == JsonValueKind.Object ? body.GetRawText() : "{}";
        return Run(db, tenant, HmsPermissions.BillingCounterReconcile, options.Value,
            "select billing.signoff_day(@t::uuid, @b::uuid, @d::date, @j::jsonb)::text", ct, ("b", branchId), ("d", date), ("j", raw));
    }

    private static async Task<IResult> Run(
        BillingDbContext db, ITenantContext tenant, string permission, DayCloseOptions? decorate, string sql, CancellationToken ct,
        params (string Name, object? Value)[] extra)
    {
        if (!tenant.Can(permission))
        {
            return HmsProblems.Forbidden();
        }

        try
        {
            var value = await RawSql.ScalarAsync(db, sql, ct, [("t", tenant.TenantId), .. extra]);
            var text = value?.ToString() ?? "null";
            return Results.Text(decorate is null ? text : Decorate(text, decorate), "application/json");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    /// <summary>Adds the configured reason suggestions and method labels to a summary.</summary>
    internal static string Decorate(string summaryJson, DayCloseOptions options)
    {
        if (JsonNode.Parse(summaryJson) is not JsonObject doc)
        {
            return summaryJson;
        }

        doc["varianceReasons"] = new JsonArray([.. options.VarianceReasons.Select(r => (JsonNode?)JsonValue.Create(r))]);
        var labels = new JsonObject();
        foreach (var (mode, label) in options.MethodLabels)
        {
            labels[mode] = label;
        }

        doc["methodLabels"] = labels;
        return doc.ToJsonString();
    }
}
