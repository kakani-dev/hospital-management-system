using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Hms.Modules.Billing.Endpoints;
using Hms.Modules.Billing.Gl;
using Xunit;

namespace Hms.UnitTests;

public class GlExportTests
{
    private static GlExportOptions Options() => new()
    {
        Ledgers = new(StringComparer.Ordinal)
        {
            ["party:self"] = new() { Name = "Patient Receivables", Group = "Sundry Debtors" },
            ["sales:*"] = new() { Name = "{category} Income", Group = "Sales Accounts" },
            ["gst:cgst"] = new() { Name = "Output CGST @ {rate}%", Group = "Duties & Taxes" },
            ["gst:sgst"] = new() { Name = "Output SGST @ {rate}%", Group = "Duties & Taxes" },
            ["round_off"] = new() { Name = "Round Off", Group = "Indirect Expenses" },
            ["tender:upi"] = new() { Name = "UPI Collections", Group = "Bank Accounts" },
            ["tender:cash"] = new() { Name = "Cash", Group = "Cash-in-Hand" },
        },
        VoucherTypes = new(StringComparer.Ordinal) { ["sales"] = "Sales", ["refund"] = "Payment" },
    };

    private static readonly string Today = DateOnly.FromDateTime(DateTime.UtcNow).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);

    private static JsonElement Feed(string vouchers) =>
        JsonDocument.Parse("{\"vouchers\":" + vouchers.Replace("TODAY", Today, StringComparison.Ordinal) + ",\"skippedZero\":1}").RootElement;

    private const string SaleWithRoundOff = """
        [{"id":"11111111-1111-4111-8111-111111111111","type":"sales","number":"MN/1","date":"TODAY","entries":[
          {"key":"party:self","amountPaise":11800},{"key":"round_off","amountPaise":12},
          {"key":"sales:lab","amountPaise":-10010},{"key":"gst:cgst","rateBp":900,"amountPaise":-901},{"key":"gst:sgst","rateBp":900,"amountPaise":-901}]}]
        """;

    [Fact]
    public void Tenant_override_wins_over_config_default()
    {
        var l = new GlLedgers(Options(), [("round_off", "Rounding Off", "Indirect Expenses")]);
        Assert.Equal("Rounding Off", l.Resolve("round_off").Name);
        Assert.False(l.Resolve("round_off").IsDefault);
        Assert.Equal("Cash", l.Resolve("tender:cash").Name);
    }

    [Fact]
    public void Gst_rate_and_category_fill_the_template()
    {
        var l = new GlLedgers(Options(), []);
        Assert.Equal("Output CGST @ 9%", l.Resolve("gst:cgst", 900).Name);
        Assert.Equal("Output CGST @ 2.5%", l.Resolve("gst:cgst", 250).Name);
        Assert.Equal("Lab Income", l.Resolve("sales:lab").Name);
    }

    [Fact]
    public void Payment_account_falls_back_to_its_tender_mode_and_unknown_keys_are_flagged()
    {
        var l = new GlLedgers(Options(), []);
        Assert.Equal("UPI Collections", l.Resolve("payacct:abc", null, "upi").Name);
        var mine = new GlLedgers(Options(), [("payacct:abc", "HDFC UPI 1234", "Bank Accounts")]);
        Assert.Equal("HDFC UPI 1234", mine.Resolve("payacct:abc", null, "upi").Name);
        Assert.True(l.Resolve("party:insurer").Unmapped);
    }

    [Fact]
    public void Build_keeps_round_off_and_balances()
    {
        var (vouchers, skipped) = GlBook.Build(Feed(SaleWithRoundOff), new GlLedgers(Options(), []));
        var v = Assert.Single(vouchers);
        Assert.True(v.Balanced);
        Assert.Equal(1, skipped);
        Assert.Equal(11812, v.DebitPaise);
        Assert.Contains(v.Entries, e => e.Ledger.Name == "Round Off" && e.AmountPaise == 12);
    }

    [Fact]
    public void Two_keys_mapped_to_one_ledger_are_merged()
    {
        const string receipt = """
            [{"id":"22222222-2222-4222-8222-222222222222","type":"receipt","number":"R1","date":"TODAY","entries":[
              {"key":"payacct:x","mode":"upi","amountPaise":100},{"key":"tender:upi","mode":"upi","amountPaise":50},{"key":"party:self","amountPaise":-150}]}]
            """;
        var v = Assert.Single(GlBook.Build(Feed(receipt), new GlLedgers(Options(), [])).Vouchers);
        Assert.Equal(2, v.Entries.Count);
        Assert.Equal(150, v.Entries.Single(e => e.Ledger.Name == "UPI Collections").AmountPaise);
    }

    [Fact]
    public void Tally_xml_uses_negative_amounts_for_debits_and_a_stable_remote_id()
    {
        var (vouchers, _) = GlBook.Build(Feed(SaleWithRoundOff), new GlLedgers(Options(), [("company", "Zz-QA Hospital", null)]));
        var xml = XDocument.Parse(Encoding.UTF8.GetString(GlBook.TallyVouchers(vouchers, "Zz-QA Hospital")));
        var voucher = xml.Descendants("VOUCHER").Single();
        Assert.Equal("hms-11111111-1111-4111-8111-111111111111", (string?)voucher.Attribute("REMOTEID"));
        Assert.Equal("Sales", (string?)voucher.Attribute("VCHTYPE"));
        Assert.Equal("Zz-QA Hospital", xml.Descendants("SVCURRENTCOMPANY").Single().Value);
        var party = voucher.Elements("ALLLEDGERENTRIES.LIST").Single(e => e.Element("LEDGERNAME")!.Value == "Patient Receivables");
        Assert.Equal("-118.00", party.Element("AMOUNT")!.Value);
        Assert.Equal("Yes", party.Element("ISDEEMEDPOSITIVE")!.Value);
        var cgst = voucher.Elements("ALLLEDGERENTRIES.LIST").Single(e => e.Element("LEDGERNAME")!.Value == "Output CGST @ 9%");
        Assert.Equal("9.01", cgst.Element("AMOUNT")!.Value);
        Assert.Equal(0m, voucher.Elements("ALLLEDGERENTRIES.LIST").Sum(e => decimal.Parse(e.Element("AMOUNT")!.Value, System.Globalization.CultureInfo.InvariantCulture)));
    }

    [Fact]
    public void Masters_list_each_ledger_once_with_its_group()
    {
        var (vouchers, _) = GlBook.Build(Feed(SaleWithRoundOff), new GlLedgers(Options(), []));
        var xml = XDocument.Parse(Encoding.UTF8.GetString(GlBook.TallyMasters(vouchers.SelectMany(v => v.Entries).Select(e => e.Ledger), null)));
        Assert.Equal(5, xml.Descendants("LEDGER").Count());
        Assert.Equal("Duties & Taxes", xml.Descendants("LEDGER").First(l => (string?)l.Attribute("NAME") == "Output SGST @ 9%").Element("PARENT")!.Value);
        Assert.Empty(xml.Descendants("SVCURRENTCOMPANY"));
    }

    [Fact]
    public void Csv_has_debit_and_credit_columns_and_guards_formulas()
    {
        var l = new GlLedgers(Options(), [("round_off", "=Round, Off", null)]);
        var (vouchers, _) = GlBook.Build(Feed(SaleWithRoundOff), l);
        var csv = Encoding.UTF8.GetString(GlBook.Csv(vouchers)).TrimStart('\uFEFF');
        var lines = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("Date,Voucher Type,Voucher No,Reference,Ledger,Group,Debit,Credit,Narration", lines[0]);
        Assert.Equal(6, lines.Length);
        Assert.Contains("\"'=Round, Off\"", csv, StringComparison.Ordinal);
        Assert.Contains("Patient Receivables,Sundry Debtors,118.00,,Bill MN/1", csv, StringComparison.Ordinal);
    }

    [Fact]
    public void Credit_note_and_refund_narrations_reference_the_original()
    {
        var cn = new GlVoucher("1", "credit_note", "Credit Note", "CN/1", DateOnly.MinValue, "MN/1", false, []);
        var rf = new GlVoucher("2", "refund", "Payment", "RF/1", DateOnly.MinValue, "R/1", false, []);
        var adv = new GlVoucher("3", "receipt", "Receipt", "R/2", DateOnly.MinValue, null, true, []);
        Assert.Equal("Credit note CN/1 against bill MN/1", GlBook.Narration(cn));
        Assert.Equal("Refund RF/1 of receipt R/1", GlBook.Narration(rf));
        Assert.Equal("Advance receipt R/2", GlBook.Narration(adv));
    }

    [Fact]
    public void Period_defaults_to_month_to_date_and_validates()
    {
        var clock = new FixedClock(DateTimeOffset.UtcNow);
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(clock.GetUtcNow(), TimeZoneInfo.FindSystemTimeZoneById("Asia/Kolkata")).DateTime);
        var (p, e) = GlEndpoints.ParsePeriod(null, null, null, "Asia/Kolkata", clock);
        Assert.Null(e);
        Assert.Equal(new DateOnly(today.Year, today.Month, 1), p!.From);
        Assert.Equal(today, p.To);
        var from = today.AddDays(-10).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var to = today.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal("to is before from.", GlEndpoints.ParsePeriod(to, from, null, "Asia/Kolkata", clock).Error);
        Assert.Equal("from and to are both required.", GlEndpoints.ParsePeriod(from, null, null, "Asia/Kolkata", clock).Error);
        Assert.Equal("the period is longer than 400 days.", GlEndpoints.ParsePeriod(today.AddDays(-500).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), to, null, "Asia/Kolkata", clock).Error);
        Assert.Equal("branchId must be a branch id.", GlEndpoints.ParsePeriod(from, to, "nope", "Asia/Kolkata", clock).Error);
        Assert.Equal("from and to must be dates (yyyy-MM-dd).", GlEndpoints.ParsePeriod("31-10-2026", to, null, "Asia/Kolkata", clock).Error);
    }

    [Fact]
    public void Ledger_keys_are_validated_before_the_database()
    {
        var items = JsonDocument.Parse("""[{"key":"round_off","name":"Round Off"},{"key":"Bad Key","name":"x"}]""").RootElement;
        var errors = GlValidation.Check(items);
        Assert.Single(errors);
        Assert.True(errors.ContainsKey("ledgers[1].key"));
    }
}
