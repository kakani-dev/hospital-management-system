using System.Text.Json;
using Hms.Modules.Billing.DayClose;
using Hms.Modules.Billing.Endpoints;
using Xunit;

namespace Hms.UnitTests;

public class DayCloseTests
{
    private static JsonElement J(string json) => JsonDocument.Parse(json).RootElement;

    [Fact]
    public void Close_accepts_count_reason_and_handover()
    {
        Assert.Empty(DayCloseValidation.CheckClose(J("""{"countedCashPaise":49000,"reason":"Change given short","handoverPaise":10000}"""), 200));
    }

    [Theory]
    [InlineData("""{}""", "countedCashPaise")]
    [InlineData("""{"countedCashPaise":-1}""", "countedCashPaise")]
    [InlineData("""{"countedCashPaise":"100"}""", "countedCashPaise")]
    [InlineData("""{"countedCashPaise":100,"handoverPaise":200}""", "handoverPaise")]
    [InlineData("""{"countedCashPaise":100,"handoverPaise":-5}""", "handoverPaise")]
    [InlineData("""{"countedCashPaise":100,"reason":5}""", "reason")]
    public void Close_rejects_bad_input(string json, string field)
    {
        Assert.Contains(field, DayCloseValidation.CheckClose(J(json), 200).Keys);
    }

    [Fact]
    public void Close_rejects_overlong_reason()
    {
        var body = J(JsonSerializer.Serialize(new { countedCashPaise = 1, reason = new string('x', 21) }));
        Assert.Contains("reason", DayCloseValidation.CheckClose(body, 20).Keys);
    }

    [Fact]
    public void Settlements_accept_card_upi_and_bank_per_account()
    {
        var body = J("""{"items":[{"mode":"card","settledPaise":30000},{"mode":"upi","settledPaise":19000,"reason":"Gateway fee deducted"},{"mode":"bank","paymentAccountId":"7a1b2c3d-0000-4000-8000-000000000001","settledPaise":0}]}""");
        Assert.Empty(DayCloseValidation.CheckSettlements(body, 200));
    }

    [Theory]
    [InlineData("""{"items":[]}""", "items")]
    [InlineData("""{}""", "items")]
    [InlineData("""{"items":[{"mode":"cash","settledPaise":1}]}""", "items[0].mode")]
    [InlineData("""{"items":[{"mode":"card","settledPaise":-1}]}""", "items[0].settledPaise")]
    [InlineData("""{"items":[{"mode":"card","paymentAccountId":"nope","settledPaise":1}]}""", "items[0].paymentAccountId")]
    [InlineData("""{"items":[{"mode":"card","settledPaise":1},{"mode":"card","settledPaise":2}]}""", "items[1]")]
    public void Settlements_reject_bad_lines(string json, string field)
    {
        Assert.Contains(field, DayCloseValidation.CheckSettlements(J(json), 200).Keys);
    }

    [Fact]
    public void Summary_carries_configured_reasons_and_labels()
    {
        var options = new DayCloseOptions
        {
            VarianceReasons = ["Counting error"],
            MethodLabels = new(StringComparer.Ordinal) { ["bank"] = "Bank / cheque" },
        };
        using var doc = JsonDocument.Parse(DayCloseEndpoints.Decorate("""{"date":"2026-01-01","methods":[]}""", options));
        Assert.Equal("Counting error", doc.RootElement.GetProperty("varianceReasons")[0].GetString());
        Assert.Equal("Bank / cheque", doc.RootElement.GetProperty("methodLabels").GetProperty("bank").GetString());
        Assert.Equal("2026-01-01", doc.RootElement.GetProperty("date").GetString());
    }

    [Fact]
    public void Defaults_come_from_appsettings_not_code()
    {
        var path = Path.Combine(FindRoot(), "services", "billing", "Hms.Billing.Api", "appsettings.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var section = doc.RootElement.GetProperty(DayCloseOptions.Section);
        Assert.True(section.GetProperty("VarianceReasons").GetArrayLength() > 0);
        Assert.Equal(JsonValueKind.String, section.GetProperty("MethodLabels").GetProperty("upi").ValueKind);
    }

    private static string FindRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Hms.slnx")))
        {
            dir = dir.Parent;
        }

        return dir?.FullName ?? throw new InvalidOperationException("Hms.slnx not found");
    }
}
