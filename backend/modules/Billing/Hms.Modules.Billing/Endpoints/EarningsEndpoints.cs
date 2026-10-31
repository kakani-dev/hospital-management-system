using System.Text.Json;
using Hms.Modules.Billing.Caching;
using Hms.Modules.Billing.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Hms.SharedKernel.Time;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;

namespace Hms.Modules.Billing.Endpoints;

public static class EarningsEndpoints
{
    public static RouteGroupBuilder MapEarningsEndpoints(this RouteGroupBuilder api)
    {
        var reports = api.MapGroup("/billing-reports").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        reports.MapGet("/earnings", GetAsync);
        reports.MapGet("/earnings/export", ExportAsync);
        reports.MapGet("/owner-kpis", OwnerKpisAsync);
        return api;
    }

    private static async Task<IResult> GetAsync(
        HttpContext http, BillingDbContext db, ITenantContext tenant, EarningsReportCache cache, TimeProvider clock, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.BillingEarnings))
        {
            return HmsProblems.Forbidden();
        }

        var (parsed, error) = Parse(http, tenant, clock);
        if (error is not null)
        {
            return error;
        }

        try
        {
            var (json, hit) = await cache.GetOrCreateAsync(tenant.TenantId, parsed!.CacheKey, token => LoadAsync(db, tenant, parsed, token), ct);
            http.Response.Headers["X-Earnings-Cache"] = hit ? "hit" : "miss";
            return Results.Text(json, "application/json");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<IResult> ExportAsync(
        HttpContext http, BillingDbContext db, ITenantContext tenant, EarningsReportCache cache, TimeProvider clock, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.BillingEarnings))
        {
            return HmsProblems.Forbidden();
        }

        var (parsed, error) = Parse(http, tenant, clock);
        if (error is not null)
        {
            return error;
        }

        var query = QueryMap(http);
        var format = (query.TryGetValue("format", out var formatText) ? formatText : null)?.Trim().ToLowerInvariant();
        var section = (query.TryGetValue("section", out var sectionText) ? sectionText : null)?.Trim().ToLowerInvariant();
        if (string.IsNullOrEmpty(section))
        {
            section = null;
        }

        if (format is not ("csv" or "xlsx"))
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "format must be csv or xlsx.");
        }

        if (format == "csv")
        {
            section ??= "summary";
        }

        if (section is not null && !EarningsExport.Known(section))
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Unknown export section.");
        }

        string json;
        bool hit;
        try
        {
            (json, hit) = await cache.GetOrCreateAsync(tenant.TenantId, parsed!.CacheKey, token => LoadAsync(db, tenant, parsed, token), ct);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        http.Response.Headers["X-Earnings-Cache"] = hit ? "hit" : "miss";
        using var document = JsonDocument.Parse(json);
        var from = document.RootElement.GetProperty("from").GetString();
        var to = document.RootElement.GetProperty("to").GetString();
        if (format == "csv")
        {
            var bytes = EarningsExport.Csv(document.RootElement, section!);
            return Results.File(bytes, "text/csv; charset=utf-8", $"earnings-{section}-{from}-{to}.csv");
        }

        var book = EarningsExport.Xlsx(document.RootElement, section);
        var name = section is null ? $"earnings-accounts-{from}-{to}.xlsx" : $"earnings-{section}-{from}-{to}.xlsx";
        return Results.File(book, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", name);
    }

    private static (EarningsQuery.Parsed? Parsed, IResult? Error) Parse(HttpContext http, ITenantContext tenant, TimeProvider clock)
    {
        try
        {
            var (parsed, error) = EarningsQuery.Parse(QueryMap(http), tenant.TimeZoneFor(BranchOrNull(http)), clock);
            return error is null
                ? (parsed, null)
                : (null, HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, error));
        }
        catch (MissingTimeZoneException)
        {
            return (null, HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "This hospital has no time zone."));
        }
    }

    private static Guid? BranchOrNull(HttpContext http)
    {
        var text = http.Request.Query["branchId"].ToString().Trim();
        return Guid.TryParse(text, out var id) && id != Guid.Empty ? id : null;
    }

    private static Dictionary<string, string?> QueryMap(HttpContext http)
    {
        var map = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in http.Request.Query)
        {
            // A client-supplied tenant id is never read. ASP.NET also drops unknown action parameters.
            if (pair.Key.Equals("tenantId", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            map[pair.Key] = pair.Value.ToString();
        }

        return map;
    }

    /// <summary>Owner dashboard: read-only daily KPIs for a date range (max 92 days) and optional branch.</summary>
    private static async Task<IResult> OwnerKpisAsync(
        HttpContext http, BillingDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.BillingEarnings))
        {
            return HmsProblems.Forbidden();
        }

        var q = http.Request.Query;
        if (!DateOnly.TryParseExact(q["from"].ToString(), "yyyy-MM-dd", out var from)
            || !DateOnly.TryParseExact(q["to"].ToString(), "yyyy-MM-dd", out var to))
        {
            return HmsProblems.BadRequest("invalid_range", "from and to must be dates (yyyy-MM-dd).");
        }

        Guid? branchId = null;
        var rawBranch = q["branchId"].ToString();
        if (!string.IsNullOrEmpty(rawBranch))
        {
            if (!Guid.TryParse(rawBranch, out var parsedBranch))
            {
                return HmsProblems.BadRequest("invalid_branch", "branchId must be a UUID.");
            }

            branchId = parsedBranch;
        }

        try
        {
            var value = await RawSql.ScalarAsync(
                db,
                "select billing.owner_kpis(@t::uuid, @f::date, @u::date, @br::uuid)::text",
                ct,
                ("t", tenant.TenantId),
                ("f", from),
                ("u", to),
                ("br", branchId));
            return Results.Text(value?.ToString() ?? "null", "application/json");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<string> LoadAsync(BillingDbContext db, ITenantContext tenant, EarningsQuery.Parsed parsed, CancellationToken ct)
    {
        var value = await RawSql.ScalarAsync(
            db,
            "select billing.earnings_report(@t::uuid, @f::date, @u::date, @br::uuid, @g::text, @fy::integer, @q::integer)::text",
            ct,
            ("t", tenant.TenantId),
            ("f", parsed.From),
            ("u", parsed.To),
            ("br", parsed.BranchId),
            ("g", parsed.Grain),
            ("fy", parsed.FinancialYear),
            ("q", parsed.Quarter));
        return value?.ToString() ?? "null";
    }
}
