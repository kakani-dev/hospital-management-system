using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Hms.Modules.Billing.Caching;
using Hms.Modules.Billing.Endpoints;
using Microsoft.Extensions.Caching.Memory;

namespace Hms.UnitTests;

public sealed class EarningsReportTests
{
    private static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Beta = Guid.Parse("22222222-2222-4222-8222-222222222222");

    [Fact]
    public void Whitespace_only_fy_is_the_same_as_an_empty_request()
    {
        var clock = new ManualClock(DateTimeOffset.UnixEpoch);
        var (parsed, error) = EarningsQuery.Parse(
            new Dictionary<string, string?> { ["fy"] = "  " }, "Asia/Kolkata", clock);
        Assert.Null(error);
        Assert.Null(parsed!.FinancialYear);
        Assert.Equal(new DateOnly(1970, 1, 1), parsed.From);
        Assert.Equal(new DateOnly(1970, 1, 1), parsed.To);
    }

    [Fact]
    public void Empty_request_uses_the_hospital_month_not_utc()
    {
        // 2026-03-31 19:00 UTC is 2026-04-01 00:30 in Asia/Kolkata.
        var clock = new ManualClock(new DateTimeOffset(2026, 3, 31, 19, 0, 0, TimeSpan.Zero));
        var (parsed, error) = EarningsQuery.Parse(new Dictionary<string, string?>(), "Asia/Kolkata", clock);
        Assert.Null(error);
        Assert.Equal(new DateOnly(2026, 4, 1), parsed!.From);
        Assert.Equal(new DateOnly(2026, 4, 1), parsed.To);
    }

    [Fact]
    public void Whitespace_grain_and_a_client_tenant_id_are_normalised()
    {
        var clock = new ManualClock(DateTimeOffset.Parse("2026-04-15T00:00:00Z", CultureInfo.InvariantCulture));
        var (parsed, error) = EarningsQuery.Parse(new Dictionary<string, string?>
        {
            ["from"] = " 2026-04-01 ",
            ["to"] = "2026-04-30",
            ["grain"] = "  MONTH ",
            ["branchId"] = "  ",
            ["tenantId"] = Beta.ToString(),
        }, "Asia/Kolkata", clock);
        Assert.Null(error);
        Assert.Equal("month", parsed!.Grain);
        Assert.Null(parsed.BranchId);
        Assert.DoesNotContain(Beta.ToString("N"), parsed.CacheKey, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("fy", "1999", "fy must be a financial year from 2000 to 2100.")]
    [InlineData("fy", "2101", "fy must be a financial year from 2000 to 2100.")]
    [InlineData("quarter", "5", "quarter must be 1, 2, 3 or 4.")]
    [InlineData("grain", "nope", "grain must be day, week or month.")]
    [InlineData("from", "04/01/2026", "from must be a date (yyyy-MM-dd).")]
    [InlineData("branchId", "not-a-guid", "branchId must be a branch id.")]
    public void Invalid_input_is_rejected(string key, string value, string expected)
    {
        var query = new Dictionary<string, string?> { ["from"] = "2026-04-01", ["to"] = "2026-04-30" };
        if (key == "fy")
        {
            query.Remove("from");
            query.Remove("to");
        }

        query[key] = value;
        if (key == "quarter")
        {
            query["fy"] = "2026";
        }

        var (parsed, error) = EarningsQuery.Parse(query, "Asia/Kolkata", new ManualClock(DateTimeOffset.UnixEpoch));
        Assert.Null(parsed);
        Assert.Equal(expected, error);
    }

    [Fact]
    public void Quarter_without_a_year_and_a_reversed_or_huge_range_are_rejected()
    {
        var clock = new ManualClock(DateTimeOffset.UnixEpoch);
        Assert.Equal("quarter needs a financial year.", EarningsQuery.Parse(
            new Dictionary<string, string?> { ["from"] = "2026-04-01", ["to"] = "2026-04-30", ["quarter"] = "1" },
            "Asia/Kolkata", clock).Error);
        Assert.Equal("to is before from.", EarningsQuery.Parse(
            new Dictionary<string, string?> { ["from"] = "2026-04-30", ["to"] = "2026-04-01" },
            "Asia/Kolkata", clock).Error);
        Assert.Equal("the period is longer than 400 days.", EarningsQuery.Parse(
            new Dictionary<string, string?> { ["from"] = "2026-01-01", ["to"] = "2027-02-06" },
            "Asia/Kolkata", clock).Error);
    }

    [Fact]
    public void Financial_year_wins_over_the_client_dates()
    {
        var (parsed, error) = EarningsQuery.Parse(new Dictionary<string, string?>
        {
            ["from"] = "2026-01-01",
            ["to"] = "2026-01-31",
            ["fy"] = "2026",
            ["quarter"] = "4",
        }, "Asia/Kolkata", new ManualClock(DateTimeOffset.UnixEpoch));
        Assert.Null(error);
        Assert.Null(parsed!.From);
        Assert.Null(parsed.To);
        Assert.Equal(2026, parsed.FinancialYear);
        Assert.Equal(4, parsed.Quarter);
    }

    [Fact]
    public async Task Two_tenants_do_not_share_a_cached_report_and_a_failure_is_not_cached()
    {
        var (cache, _) = Create();
        Assert.Equal("alpha", (await cache.GetOrCreateAsync(Alpha, "k", _ => Task.FromResult("alpha"), CancellationToken.None)).Json);
        Assert.Equal("beta", (await cache.GetOrCreateAsync(Beta, "k", _ => Task.FromResult("beta"), CancellationToken.None)).Json);
        Assert.Equal("alpha", (await cache.GetOrCreateAsync(Alpha, "k", _ => Task.FromResult("other"), CancellationToken.None)).Json);

        var loads = 0;
        Task<string> Boom(CancellationToken _) 
        {
            loads++;
            throw new InvalidOperationException("db");
        }

        await Assert.ThrowsAsync<InvalidOperationException>(() => cache.GetOrCreateAsync(Alpha, "bad", Boom, CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => cache.GetOrCreateAsync(Alpha, "bad", Boom, CancellationToken.None));
        Assert.Equal(2, loads);
    }

    [Fact]
    public async Task Simultaneous_misses_run_the_query_once_and_the_entry_expires()
    {
        var (cache, clock) = Create();
        var loads = 0;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<string> Load(CancellationToken _)
        {
            if (Interlocked.Increment(ref loads) == 1)
            {
                started.SetResult();
            }

            return release.Task.ContinueWith(_ => "report", TaskScheduler.Default);
        }

        var first = cache.GetOrCreateAsync(Alpha, "race", Load, CancellationToken.None);
        await started.Task;
        var second = cache.GetOrCreateAsync(Alpha, "race", Load, CancellationToken.None);
        release.SetResult();
        Assert.Equal("report", (await first).Json);
        Assert.False((await first).Hit);
        Assert.Equal("report", (await second).Json);
        Assert.Equal(1, loads);

        clock.Advance(EarningsReportCache.Ttl + TimeSpan.FromSeconds(1));
        Assert.False((await cache.GetOrCreateAsync(Alpha, "race", _ => Task.FromResult("again"), CancellationToken.None)).Hit);
    }

    [Fact]
    public async Task An_empty_tenant_is_never_cached()
    {
        var (cache, _) = Create();
        var loads = 0;
        Task<string> Load(CancellationToken _) => Task.FromResult($"n-{++loads}");
        await cache.GetOrCreateAsync(Guid.Empty, "k", Load, CancellationToken.None);
        await cache.GetOrCreateAsync(Guid.Empty, "k", Load, CancellationToken.None);
        Assert.Equal(2, loads);
    }

    [Fact]
    public void Csv_and_xlsx_use_rupees_and_say_new_when_there_is_no_baseline()
    {
        using var doc = JsonDocument.Parse(Sample("""{"direction":"new","pct":null}"""));
        var csv = Encoding.UTF8.GetString(EarningsExport.Csv(doc.RootElement, "summary"));
        Assert.StartsWith("\uFEFF", csv, StringComparison.Ordinal);
        Assert.Contains("Metric,Amount (INR),Direction,Change percent", csv, StringComparison.Ordinal);
        Assert.Contains("Gross billed,1.01,new,", csv, StringComparison.Ordinal);
        Assert.Contains("Invoice number", Encoding.UTF8.GetString(EarningsExport.Csv(doc.RootElement, "sales")), StringComparison.Ordinal);

        var sales = Encoding.UTF8.GetString(EarningsExport.Csv(doc.RootElement, "sales"));
        Assert.Contains("AM-1,2026-04-01,Asha & Co,B2C,UNREGISTERED,0.10,0.01,0.00,0.00,0.01,0.00", sales, StringComparison.Ordinal);

        using var zip = new ZipArchive(new MemoryStream(EarningsExport.Xlsx(doc.RootElement, "sales")));
        using var sheet = new StreamReader(zip.GetEntry("xl/worksheets/sheet1.xml")!.Open());
        var xml = sheet.ReadToEnd();
        Assert.Contains("Invoice number", xml, StringComparison.Ordinal);
        Assert.Contains("Asha &amp; Co", xml, StringComparison.Ordinal);
        Assert.Contains(">0.01<", xml, StringComparison.Ordinal);
    }

    [Fact]
    public void A_workbook_without_a_section_has_every_register_and_an_unknown_section_is_refused()
    {
        using var doc = JsonDocument.Parse(Sample("""{"direction":"flat","pct":null}"""));
        using var zip = new ZipArchive(new MemoryStream(EarningsExport.Xlsx(doc.RootElement, null)));
        Assert.Equal(EarningsExport.Sections.Length, zip.Entries.Count(e => e.FullName.StartsWith("xl/worksheets/", StringComparison.Ordinal)));
        Assert.Throws<ArgumentException>(() => EarningsExport.Csv(doc.RootElement, "tally"));
    }

    [Fact]
    public void One_paise_is_one_hundredth_of_a_rupee()
    {
        Assert.Equal("0.01", EarningsExport.Inr(1));
        Assert.Equal("2.51", EarningsExport.Inr(251));
        Assert.Equal("-1.00", EarningsExport.Inr(-100));
    }

    private static string Sample(string move) => $$"""
        {
          "focus": {
            "grossBilledPaise": 101, "collectedPaise": 0, "refundsPaise": 0, "netEarningsPaise": 0,
            "outstandingPaise": 0, "discountPaise": 0, "cgstPaise": 1, "sgstPaise": 0, "igstPaise": 0,
            "billCount": 1, "averageBillPaise": 0, "visitCount": 1, "doctorCount": 1,
            "revenuePerVisitPaise": 0, "revenuePerDoctorPaise": 0,
            "collectionEfficiencyPct": null, "refundRatePct": null, "discountRatePct": null,
            "periodGrowthPct": null, "momGrowthPct": null, "yoyGrowthPct": null,
            "deltas": {
              "grossBilled": {{move}}, "collected": {{move}}, "netEarnings": {{move}}, "refunds": {{move}},
              "billCount": {{move}}, "averageBill": {{move}}, "collectionEfficiency": {{move}}, "refundRate": {{move}},
              "mom": {{move}}, "yoy": {{move}}
            }
          },
          "trend": [],
          "branches": [], "doctors": [], "services": [], "paymentModes": [],
          "gstr1": [], "gstr3b": [], "hsn": [],
          "sales": [{
            "invoiceNumber": "AM-1", "date": "2026-04-01", "party": "Asha & Co", "supply": "B2C",
            "gstin": "UNREGISTERED", "taxablePaise": 10, "cgstPaise": 1, "sgstPaise": 0, "igstPaise": 0,
            "taxPaise": 1, "totalPaise": 0
          }],
          "creditNotes": [], "refunds": [], "receipts": [], "dayEndCash": [],
          "ageing": {"b0To30Paise": 0, "b31To60Paise": 0, "b61To90Paise": 0, "b90PlusPaise": 0}
        }
        """;

    private static (EarningsReportCache Cache, ManualClock Clock) Create()
    {
        var clock = new ManualClock(DateTimeOffset.Parse("2026-04-01T00:00:00Z", CultureInfo.InvariantCulture));
        return (new EarningsReportCache(new MemoryCache(new MemoryCacheOptions()), clock), clock);
    }

    private sealed class ManualClock(DateTimeOffset start) : TimeProvider
    {
        private DateTimeOffset _utc = start;
        public override DateTimeOffset GetUtcNow() => _utc;
        public void Advance(TimeSpan by) => _utc += by;
    }
}
