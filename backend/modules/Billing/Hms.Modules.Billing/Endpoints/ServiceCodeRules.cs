using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hms.Modules.Billing.Endpoints;

/// <summary>
/// Service codes are allocated by <c>billing.allocate_service_code</c>. A client never supplies one.
/// </summary>
internal static class ServiceCodeRules
{
    public const string ClientSuppliedCodeDetail =
        "Service codes are assigned by the server and cannot be supplied.";

    /// <summary>True when a create or update body carries a non-blank <c>code</c>.</summary>
    public static bool HasClientSuppliedCode(JsonElement body)
    {
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty("code", out var code))
        {
            return false;
        }

        return code.ValueKind switch
        {
            JsonValueKind.Null or JsonValueKind.Undefined => false,
            JsonValueKind.String => !string.IsNullOrWhiteSpace(code.GetString()),
            _ => true,
        };
    }

    /// <summary>
    /// Drops <c>code</c> from each import row. Matching and allocation happen in the database.
    /// </summary>
    public static string WithoutImportCodes(string rawBody)
    {
        var node = JsonNode.Parse(rawBody);
        if (node is not JsonObject root || root["rows"] is not JsonArray rows)
        {
            return rawBody;
        }

        foreach (var row in rows)
        {
            if (row is JsonObject obj)
            {
                obj.Remove("code");
            }
        }

        return root.ToJsonString();
    }
}
