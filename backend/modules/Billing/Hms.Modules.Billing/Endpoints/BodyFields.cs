using System.Text.Json;
using Hms.Platform.Http;
using Microsoft.AspNetCore.Http;

namespace Hms.Modules.Billing.Endpoints;

/// <summary>
/// Reads required fields from a JSON request body so a missing or malformed field
/// becomes a 400 invalid_parameter instead of an unhandled 500.
/// </summary>
public static class BodyFields
{
    public static bool TryGuid(JsonElement body, string name, out Guid value)
    {
        value = Guid.Empty;
        return body.ValueKind == JsonValueKind.Object
            && body.TryGetProperty(name, out var p)
            && p.ValueKind == JsonValueKind.String
            && p.TryGetGuid(out value);
    }

    public static bool TryString(JsonElement body, string name, out string value)
    {
        value = "";
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty(name, out var p) || p.ValueKind != JsonValueKind.String)
            return false;
        value = p.GetString() ?? "";
        return value.Trim().Length > 0;
    }

    public static bool TryObject(JsonElement body, string name, out string raw)
    {
        raw = "";
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty(name, out var p) || p.ValueKind != JsonValueKind.Object)
            return false;
        raw = p.GetRawText();
        return true;
    }

    public static Task<IResult> Invalid(string name, string kind) =>
        Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, $"{name} must be {kind}."));
}
