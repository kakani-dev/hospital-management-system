using System.Text.Json;

namespace Hms.Modules.Billing.DayClose;

/// <summary>#65: request shape checks before the database (which re-checks every rule).</summary>
internal static class DayCloseValidation
{
    private static readonly string[] SettleModes = ["card", "upi", "bank"];

    public static Dictionary<string, string[]> CheckClose(JsonElement body, int maxReason)
    {
        var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);
        if (body.ValueKind != JsonValueKind.Object)
        {
            errors["body"] = ["Send a JSON object."];
            return errors;
        }

        if (!TryPaise(body, "countedCashPaise", out var counted))
        {
            errors["countedCashPaise"] = ["Counted cash must be zero or more (in paise)."];
        }

        if (body.TryGetProperty("handoverPaise", out var h) && h.ValueKind != JsonValueKind.Null
            && (!TryPaise(body, "handoverPaise", out var handover) || (errors.Count == 0 && handover > counted)))
        {
            errors["handoverPaise"] = ["Cash handed over must be between zero and the counted cash."];
        }

        CheckText(body, "reason", maxReason, errors);
        CheckText(body, "note", maxReason, errors);
        return errors;
    }

    public static Dictionary<string, string[]> CheckSettlements(JsonElement body, int maxReason)
    {
        var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty("items", out var items)
            || items.ValueKind != JsonValueKind.Array || items.GetArrayLength() == 0)
        {
            errors["items"] = ["Send at least one settlement line."];
            return errors;
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var i = 0;
        foreach (var item in items.EnumerateArray())
        {
            var key = $"items[{i}]";
            if (item.ValueKind != JsonValueKind.Object)
            {
                errors[key] = ["Each line must be an object."];
                i++;
                continue;
            }

            var mode = item.TryGetProperty("mode", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() ?? "" : "";
            if (Array.IndexOf(SettleModes, mode) < 0)
            {
                errors[key + ".mode"] = ["Mode must be card, upi or bank (cash is counted per drawer)."];
            }

            var account = "";
            if (item.TryGetProperty("paymentAccountId", out var a) && a.ValueKind != JsonValueKind.Null)
            {
                if (a.ValueKind != JsonValueKind.String || !Guid.TryParse(a.GetString(), out _))
                {
                    errors[key + ".paymentAccountId"] = ["Payment account must be a UUID."];
                }
                else
                {
                    account = a.GetString()!.ToLowerInvariant();
                }
            }

            if (!seen.Add(mode + "|" + account))
            {
                errors[key] = ["The same method and account appears twice."];
            }

            if (!TryPaise(item, "settledPaise", out _))
            {
                errors[key + ".settledPaise"] = ["Settled amount must be zero or more (in paise)."];
            }

            CheckText(item, "reason", maxReason, errors, key + ".");
            i++;
        }

        return errors;
    }

    public static bool TryPaise(JsonElement obj, string name, out long value)
    {
        value = 0;
        return obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out value) && value >= 0;
    }

    private static void CheckText(JsonElement obj, string name, int max, Dictionary<string, string[]> errors, string prefix = "")
    {
        if (!obj.TryGetProperty(name, out var v) || v.ValueKind == JsonValueKind.Null)
        {
            return;
        }

        if (v.ValueKind != JsonValueKind.String || (v.GetString() ?? "").Trim().Length > max)
        {
            errors[prefix + name] = [$"Must be text of {max} characters or fewer."];
        }
    }
}
