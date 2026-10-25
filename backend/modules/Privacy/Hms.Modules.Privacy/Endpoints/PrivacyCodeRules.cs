using System.Text.Json;

namespace Hms.Modules.Privacy.Endpoints;

/// <summary>
/// Notice versions, rights-request numbers, and record ids are allocated in the database.
/// A client never supplies one.
/// </summary>
internal static class PrivacyCodeRules
{
    public const string ClientSuppliedCodeDetail =
        "Codes are generated automatically; leave this field empty.";

    private static readonly string[] Forbidden = ["code", "version", "id", "tenantId", "tenant_id"];

    public static bool HasClientSuppliedCode(JsonElement body) => HasAny(body, Forbidden);

    public static bool HasPublicTenant(JsonElement body) => HasAny(body, ["tenantId", "tenant_id", "patientId"]);

    private static bool HasAny(JsonElement body, string[] names)
    {
        if (body.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        foreach (var name in names)
        {
            if (body.TryGetProperty(name, out var value)
                && value.ValueKind is not JsonValueKind.Null and not JsonValueKind.Undefined)
            {
                return true;
            }
        }

        return false;
    }
}
