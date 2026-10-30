using System.Text.Json;
using Hms.Modules.Inventory.Endpoints;

namespace Hms.UnitTests;

public class InventoryCodeRulesTests
{
    [Theory]
    [InlineData("""{"brandName":"Crocin"}""", false)]
    [InlineData("""{"brandName":"Crocin","code":null}""", false)]
    [InlineData("""{"brandName":"Crocin","code":""}""", false)]
    [InlineData("""{"brandName":"Crocin","code":"  "}""", false)]
    [InlineData("""{"brandName":"Crocin","code":"ITM-9"}""", true)]
    [InlineData("""{"storeCode":"MAIN"}""", true)]
    [InlineData("""{"docNo":"OPN-1"}""", true)]
    [InlineData("""{"documentNumber":"OPN-1"}""", true)]
    [InlineData("""{"id":"d1111111-0000-4000-8000-000000000001"}""", true)]
    [InlineData("""{"id":1}""", true)]
    public void A_supplied_code_or_id_is_rejected(string json, bool supplied)
    {
        using var doc = JsonDocument.Parse(json);
        Assert.Equal(supplied, InventoryCodeRules.HasClientSuppliedCode(doc.RootElement));
    }

    [Theory]
    [InlineData(1, false)]
    [InlineData(500, false)]
    [InlineData(501, true)]
    public void Opening_stock_accepts_at_most_500_lines(int count, bool tooMany)
    {
        var lines = string.Join(",", Enumerable.Repeat("""{"qtyBase":1}""", count));
        using var doc = JsonDocument.Parse("{\"lines\":[" + lines + "]}");
        Assert.Equal(tooMany, InventoryCodeRules.HasTooManyOpeningLines(doc.RootElement));
    }

    [Theory]
    [InlineData("""{}""")]
    [InlineData("""{"lines":"x"}""")]
    [InlineData("""[]""")]
    public void A_missing_or_malformed_lines_field_is_left_to_the_database_checks(string json)
    {
        using var doc = JsonDocument.Parse(json);
        Assert.False(InventoryCodeRules.HasTooManyOpeningLines(doc.RootElement));
    }
}
