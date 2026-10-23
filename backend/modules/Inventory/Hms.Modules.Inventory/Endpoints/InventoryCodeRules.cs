using System.Text.Json;

namespace Hms.Modules.Inventory.Endpoints;

/// <summary>
/// Item codes, store codes, and document numbers are allocated in the database.
/// A client never supplies one, and a create never accepts an id.
/// </summary>
internal static class InventoryCodeRules
{
    public const string ClientSuppliedCodeDetail =
        "Item codes, store codes, and document numbers are assigned by the server and cannot be supplied.";

    private static readonly string[] Forbidden = ["code", "storeCode", "docNo", "documentNumber", "id"];

    public static bool HasClientSuppliedCode(JsonElement body)
    {
        if (body.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        foreach (var name in Forbidden)
        {
            if (!body.TryGetProperty(name, out var value))
            {
                continue;
            }

            var supplied = value.ValueKind switch
            {
                JsonValueKind.Null or JsonValueKind.Undefined => false,
                JsonValueKind.String => !string.IsNullOrWhiteSpace(value.GetString()),
                _ => true,
            };
            if (supplied)
            {
                return true;
            }
        }

        return false;
    }
}
