using System.Text.Json;
using Hms.Modules.Billing.Endpoints;

namespace Hms.UnitTests;

public class ServiceCodeRulesTests
{
    [Theory]
    [InlineData("""{"name":"Dressing","category":"procedure"}""", false)]
    [InlineData("""{"name":"Dressing","code":null}""", false)]
    [InlineData("""{"name":"Dressing","code":""}""", false)]
    [InlineData("""{"name":"Dressing","code":"  "}""", false)]
    [InlineData("""{"name":"Dressing","code":"LEGACY"}""", true)]
    [InlineData("""{"id":"d1111111-0000-4000-8000-000000000001","code":"CONSULT","name":"OP consultation"}""", true)]
    [InlineData("""{"name":"Dressing","code":1}""", true)]
    public void A_non_blank_code_is_a_client_supplied_code(string json, bool supplied)
    {
        using var doc = JsonDocument.Parse(json);
        Assert.Equal(supplied, ServiceCodeRules.HasClientSuppliedCode(doc.RootElement));
    }

    [Fact]
    public void Import_drops_a_code_column_and_keeps_name_category_and_price()
    {
        const string raw = """
            {"dryRun":true,"rows":[
              {"clientIndex":0,"code":"CONSULT","name":"OP consultation","category":"consultation","sac":"9993","unitPricePaise":60000,"effectiveFrom":"2026-04-01"},
              {"clientIndex":1,"name":"Suture","category":"procedure","unitPricePaise":25000,"effectiveFrom":"2026-04-01"}
            ]}
            """;

        using var doc = JsonDocument.Parse(ServiceCodeRules.WithoutImportCodes(raw));
        Assert.True(doc.RootElement.GetProperty("dryRun").GetBoolean());
        var rows = doc.RootElement.GetProperty("rows");
        Assert.Equal(2, rows.GetArrayLength());
        Assert.False(rows[0].TryGetProperty("code", out _));
        Assert.Equal("OP consultation", rows[0].GetProperty("name").GetString());
        Assert.Equal("consultation", rows[0].GetProperty("category").GetString());
        Assert.Equal("9993", rows[0].GetProperty("sac").GetString());
        Assert.Equal(60000, rows[0].GetProperty("unitPricePaise").GetInt32());
        Assert.False(rows[1].TryGetProperty("code", out _));
        Assert.Equal("Suture", rows[1].GetProperty("name").GetString());
    }

    [Fact]
    public void Import_without_rows_is_left_for_the_database_to_reject()
    {
        const string raw = """{"dryRun":true}""";
        Assert.Equal(raw, ServiceCodeRules.WithoutImportCodes(raw));
    }
}
