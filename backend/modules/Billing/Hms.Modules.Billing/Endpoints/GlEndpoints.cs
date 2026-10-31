using System.Globalization;
using System.Text.Json;
using Hms.Modules.Billing.Gl;
using Hms.Modules.Billing.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Hms.SharedKernel.Time;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Billing.Endpoints;

/// <summary>
/// #62: GL / Tally export. One screen: ledger mapping (per tenant), a live preview for the period, and
/// downloads (Tally XML vouchers, Tally XML ledger masters, CSV journal). The tenant is always the
/// server-side tenant; a client tenant id is ignored.
/// </summary>
public static class GlEndpoints
{
    public static RouteGroupBuilder MapGlEndpoints(this RouteGroupBuilder api)
    {
        var gl = api.MapGroup("/billing-reports/gl").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        gl.MapGet("/ledgers", GetLedgersAsync);
        gl.MapPut("/ledgers", PutLedgersAsync);
        gl.MapGet("/preview", PreviewAsync);
        gl.MapGet("/export", ExportAsync);
        return api;
    }

    private static async Task<IResult> GetLedgersAsync(BillingDbContext db, ITenantContext tenant, IOptions<GlExportOptions> options, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.BillingEarnings))
        {
            return HmsProblems.Forbidden();
        }

        try
        {
            using var map = await LoadMapAsync(db, tenant, ct);
            return TypedResults.Ok(LedgerRows(options.Value, map.RootElement));
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<IResult> PutLedgersAsync(
        JsonElement body, BillingDbContext db, ITenantContext tenant, IOptions<GlExportOptions> options, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.BillingEarnings))
        {
            return HmsProblems.Forbidden();
        }

        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty("ledgers", out var items) || items.ValueKind != JsonValueKind.Array)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["ledgers"] = ["ledgers must be a list."] });
        }

        var errors = GlValidation.Check(items);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        try
        {
            await RawSql.ScalarAsync(db, "select billing.gl_ledger_map_set(@t::uuid, @i::jsonb)", ct,
                ("t", tenant.TenantId), ("i", items.GetRawText()));
            using var map = await LoadMapAsync(db, tenant, ct);
            return TypedResults.Ok(LedgerRows(options.Value, map.RootElement));
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<IResult> PreviewAsync(
        HttpContext http, BillingDbContext db, ITenantContext tenant, IOptions<GlExportOptions> options, TimeProvider clock, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.BillingEarnings))
        {
            return HmsProblems.Forbidden();
        }

        var (period, error) = Period(http, tenant, clock);
        if (error is not null)
        {
            return error;
        }

        try
        {
            var (vouchers, skipped, ledgers, map) = await BuildAsync(db, tenant, options.Value, period!, ct);
            using (map)
            {
                var used = vouchers.SelectMany(v => v.Entries)
                    .GroupBy(e => e.Ledger.Name, StringComparer.Ordinal)
                    .Select(g => new
                    {
                        name = g.Key,
                        group = g.First().Ledger.Group,
                        isDefault = g.First().Ledger.IsDefault,
                        unmapped = g.First().Ledger.Unmapped,
                        debitPaise = g.Where(e => e.AmountPaise > 0).Sum(e => e.AmountPaise),
                        creditPaise = -g.Where(e => e.AmountPaise < 0).Sum(e => e.AmountPaise),
                    })
                    .OrderBy(x => x.name, StringComparer.Ordinal)
                    .ToList();
                return TypedResults.Ok(new
                {
                    from = period!.From.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                    to = period.To.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                    branchId = period.BranchId,
                    counts = vouchers.GroupBy(v => v.Type, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal),
                    vouchers = vouchers.Count,
                    debitPaise = vouchers.Sum(v => v.DebitPaise),
                    unbalanced = vouchers.Count(v => !v.Balanced),
                    skippedZero = skipped,
                    ledgers = used,
                    lastExport = map.RootElement.TryGetProperty("lastExport", out var last) && last.ValueKind == JsonValueKind.Object ? (object?)last.Clone() : null,
                });
            }
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<IResult> ExportAsync(
        HttpContext http, BillingDbContext db, ITenantContext tenant, IOptions<GlExportOptions> options, TimeProvider clock, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.BillingEarnings))
        {
            return HmsProblems.Forbidden();
        }

        var (period, error) = Period(http, tenant, clock);
        if (error is not null)
        {
            return error;
        }

        var format = http.Request.Query["format"].ToString().Trim().ToLowerInvariant();
        var kind = http.Request.Query["kind"].ToString().Trim().ToLowerInvariant();
        kind = kind.Length == 0 ? "vouchers" : kind;
        if (format is not ("xml" or "csv"))
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "format must be xml or csv.");
        }

        if (kind is not ("vouchers" or "masters") || (kind == "masters" && format != "xml"))
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "kind must be vouchers, or masters with xml.");
        }

        try
        {
            var (vouchers, _, ledgers, map) = await BuildAsync(db, tenant, options.Value, period!, ct);
            using (map)
            {
                var stamp = $"{period!.From:yyyyMMdd}-{period.To:yyyyMMdd}";
                if (kind == "masters")
                {
                    var all = vouchers.SelectMany(v => v.Entries).Select(e => e.Ledger);
                    return Results.File(GlBook.TallyMasters(all, ledgers.Company), "application/xml; charset=utf-8", $"tally-ledgers-{stamp}.xml");
                }

                if (vouchers.Any(v => !v.Balanced))
                {
                    return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Some vouchers do not balance; nothing was exported.");
                }

                var prior = await RawSql.ScalarAsync(db,
                    "select billing.gl_export_record(@t::uuid, @f::date, @u::date, @b::uuid, @x::text, @n::integer, @d::bigint)::text", ct,
                    ("t", tenant.TenantId), ("f", period.From), ("u", period.To), ("b", period.BranchId), ("x", format),
                    ("n", vouchers.Count), ("d", vouchers.Sum(v => v.DebitPaise)));
                if (prior is string text && text.Length > 0)
                {
                    http.Response.Headers["X-Gl-Prior-Export"] = "true";
                }

                return format == "xml"
                    ? Results.File(GlBook.TallyVouchers(vouchers, ledgers.Company), "application/xml; charset=utf-8", $"tally-vouchers-{stamp}.xml")
                    : Results.File(GlBook.Csv(vouchers), "text/csv; charset=utf-8", $"gl-journal-{stamp}.csv");
            }
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    internal sealed record GlPeriod(DateOnly From, DateOnly To, Guid? BranchId);

    /// <summary>from/to (yyyy-MM-dd); none = current month to date in the hospital time zone.</summary>
    internal static (GlPeriod? Period, string? Error) ParsePeriod(string? fromText, string? toText, string? branchText, string timeZone, TimeProvider clock)
    {
        fromText = string.IsNullOrWhiteSpace(fromText) ? null : fromText.Trim();
        toText = string.IsNullOrWhiteSpace(toText) ? null : toText.Trim();
        Guid? branch = null;
        if (!string.IsNullOrWhiteSpace(branchText))
        {
            if (!Guid.TryParse(branchText.Trim(), out var b) || b == Guid.Empty)
            {
                return (null, "branchId must be a branch id.");
            }

            branch = b;
        }

        if (fromText is null && toText is null)
        {
            var today = BranchTime.Today(clock, timeZone);
            return (new GlPeriod(new DateOnly(today.Year, today.Month, 1), today, branch), null);
        }

        if (fromText is null || toText is null)
        {
            return (null, "from and to are both required.");
        }

        if (!DateOnly.TryParseExact(fromText, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var from)
            || !DateOnly.TryParseExact(toText, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var to))
        {
            return (null, "from and to must be dates (yyyy-MM-dd).");
        }

        if (to < from)
        {
            return (null, "to is before from.");
        }

        if (to.DayNumber - from.DayNumber + 1 > EarningsQuery.MaxInclusiveDays)
        {
            return (null, "the period is longer than 400 days.");
        }

        return (new GlPeriod(from, to, branch), null);
    }

    private static (GlPeriod? Period, IResult? Error) Period(HttpContext http, ITenantContext tenant, TimeProvider clock)
    {
        var q = http.Request.Query;
        var branchText = q["branchId"].ToString();
        Guid? branch = Guid.TryParse(branchText.Trim(), out var id) && id != Guid.Empty ? id : null;
        try
        {
            var (period, error) = ParsePeriod(q["from"].ToString(), q["to"].ToString(), branchText, tenant.TimeZoneFor(branch), clock);
            return error is null ? (period, null) : (null, HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, error));
        }
        catch (MissingTimeZoneException)
        {
            return (null, HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "This hospital has no time zone."));
        }
    }

    private static async Task<JsonDocument> LoadMapAsync(BillingDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        var raw = await RawSql.ScalarAsync(db, "select billing.gl_ledger_map_get(@t::uuid)::text", ct, ("t", tenant.TenantId));
        return JsonDocument.Parse(raw?.ToString() ?? "{}");
    }

    private static async Task<(IReadOnlyList<GlVoucher> Vouchers, int Skipped, GlLedgers Ledgers, JsonDocument Map)> BuildAsync(
        BillingDbContext db, ITenantContext tenant, GlExportOptions options, GlPeriod period, CancellationToken ct)
    {
        var map = await LoadMapAsync(db, tenant, ct);
        var ledgers = GlLedgers.FromMapJson(options, map.RootElement);
        var raw = await RawSql.ScalarAsync(db, "select billing.gl_vouchers(@t::uuid, @f::date, @u::date, @b::uuid)::text", ct,
            ("t", tenant.TenantId), ("f", period.From), ("u", period.To), ("b", period.BranchId));
        using var feed = JsonDocument.Parse(raw?.ToString() ?? "{\"vouchers\":[]}");
        var (vouchers, skipped) = GlBook.Build(feed.RootElement, ledgers);
        return (vouchers, skipped, ledgers, map);
    }

    /// <summary>Every mappable key with its effective name: config defaults, service categories, payment accounts, overrides.</summary>
    internal static object LedgerRows(GlExportOptions options, JsonElement map)
    {
        var ledgers = GlLedgers.FromMapJson(options, map);
        var overrides = new HashSet<string>(StringComparer.Ordinal);
        if (map.TryGetProperty("overrides", out var ov) && ov.ValueKind == JsonValueKind.Array)
        {
            foreach (var o in ov.EnumerateArray())
            {
                overrides.Add(o.GetProperty("key").GetString()!);
            }
        }

        var rows = new List<object>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        void Add(string key, string? hint = null, string? mode = null)
        {
            if (!seen.Add(key))
            {
                return;
            }

            var l = ledgers.Resolve(key, null, mode);
            rows.Add(new { key, name = l.Name, group = l.Group, isDefault = !overrides.Contains(key), hint });
        }

        Add("company", "Tally company name (optional)");
        foreach (var key in options.Ledgers.Keys.Where(k => !k.EndsWith(":*", StringComparison.Ordinal)).OrderBy(Order).ThenBy(k => k, StringComparer.Ordinal))
        {
            Add(key);
        }

        if (map.TryGetProperty("categories", out var cats) && cats.ValueKind == JsonValueKind.Array)
        {
            foreach (var c in cats.EnumerateArray())
            {
                Add("sales:" + c.GetString());
            }
        }

        if (map.TryGetProperty("paymentAccounts", out var accounts) && accounts.ValueKind == JsonValueKind.Array)
        {
            foreach (var a in accounts.EnumerateArray())
            {
                Add("payacct:" + a.GetProperty("id").GetString(), a.GetProperty("label").GetString(), a.GetProperty("mode").GetString());
            }
        }

        foreach (var type in options.VoucherTypes.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            var key = "vchtype:" + type;
            if (seen.Add(key))
            {
                rows.Add(new { key, name = ledgers.VoucherType(type), group = (string?)null, isDefault = !overrides.Contains(key), hint = (string?)null });
            }
        }

        foreach (var key in overrides.Order(StringComparer.Ordinal))
        {
            Add(key);
        }

        var gstRates = map.TryGetProperty("gstRates", out var rates) ? rates.Clone() : default;
        var lastExport = map.TryGetProperty("lastExport", out var last) && last.ValueKind == JsonValueKind.Object ? (object?)last.Clone() : null;
        return new { ledgers = rows, gstRates, lastExport };
    }

    private static int Order(string key) => key.Split(':')[0] switch
    {
        "party" => 0,
        "sales" => 1,
        "gst" => 2,
        "discount" => 3,
        "round_off" => 4,
        "tender" => 5,
        _ => 9,
    };
}

internal static class GlValidation
{
    internal static Dictionary<string, string[]> Check(JsonElement items)
    {
        var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);
        var i = 0;
        foreach (var item in items.EnumerateArray())
        {
            var key = item.ValueKind == JsonValueKind.Object && item.TryGetProperty("key", out var k) && k.ValueKind == JsonValueKind.String ? k.GetString()!.Trim() : "";
            if (!System.Text.RegularExpressions.Regex.IsMatch(key, "^[a-z_]+(:[a-z0-9_-]{1,40})?$", System.Text.RegularExpressions.RegexOptions.None, TimeSpan.FromSeconds(1)))
            {
                errors[$"ledgers[{i}].key"] = ["Unknown ledger key."];
            }

            foreach (var (field, max) in new[] { ("name", 100), ("group", 100) })
            {
                if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty(field, out var v) && v.ValueKind == JsonValueKind.String
                    && v.GetString()!.Trim().Length > max)
                {
                    errors[$"ledgers[{i}].{field}"] = [$"{field} is longer than {max} characters."];
                }
            }

            i++;
        }

        if (i > 200)
        {
            errors["ledgers"] = ["Too many ledgers in one save."];
        }

        return errors;
    }
}
