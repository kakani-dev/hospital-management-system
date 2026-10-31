using System.Globalization;
using System.Text.Json;

namespace Hms.Modules.Billing.Gl;

/// <summary>Resolves a ledger key (plus GST rate / tender mode) to the tenant's ledger name and group.</summary>
internal sealed class GlLedgers
{
    private readonly Dictionary<string, (string Name, string? Group)> _overrides;
    private readonly GlExportOptions _options;

    internal GlLedgers(GlExportOptions options, IEnumerable<(string Key, string Name, string? Group)> overrides)
    {
        _options = options;
        _overrides = new Dictionary<string, (string, string?)>(StringComparer.Ordinal);
        foreach (var (key, name, group) in overrides)
        {
            _overrides[key] = (name, group);
        }
    }

    internal static GlLedgers FromMapJson(GlExportOptions options, JsonElement map)
    {
        var list = new List<(string, string, string?)>();
        if (map.ValueKind == JsonValueKind.Object && map.TryGetProperty("overrides", out var items) && items.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in items.EnumerateArray())
            {
                var group = item.TryGetProperty("group", out var g) && g.ValueKind == JsonValueKind.String ? g.GetString() : null;
                list.Add((item.GetProperty("key").GetString()!, item.GetProperty("name").GetString()!, group));
            }
        }

        return new GlLedgers(options, list);
    }

    internal string? Company => _overrides.TryGetValue("company", out var c) ? c.Name : null;

    internal string VoucherType(string type) =>
        _overrides.TryGetValue("vchtype:" + type, out var o) ? o.Name
        : _options.VoucherTypes.TryGetValue(type, out var name) && !string.IsNullOrWhiteSpace(name) ? name
        : type;

    /// <summary>Returns the ledger; IsDefault is false when the tenant mapped it; Unmapped when nothing matched.</summary>
    internal GlLedger Resolve(string key, int? rateBp = null, string? mode = null)
    {
        // A specific bank/UPI account falls back to its tender mode.
        if (key.StartsWith("payacct:", StringComparison.Ordinal) && !_overrides.ContainsKey(key) && mode is not null)
        {
            key = "tender:" + mode;
        }

        var category = key.StartsWith("sales:", StringComparison.Ordinal) ? key["sales:".Length..] : "";
        if (_overrides.TryGetValue(key, out var mine))
        {
            return new GlLedger(key, Fill(mine.Name, rateBp, category), mine.Group, false, false);
        }

        if (_options.Ledgers.TryGetValue(key, out var def) && !string.IsNullOrWhiteSpace(def.Name))
        {
            return new GlLedger(key, Fill(def.Name, rateBp, category), def.Group, true, false);
        }

        var wildcard = key.Contains(':', StringComparison.Ordinal) ? key[..key.IndexOf(':', StringComparison.Ordinal)] + ":*" : null;
        if (wildcard is not null && _overrides.TryGetValue(wildcard, out var mineWild))
        {
            return new GlLedger(key, Fill(mineWild.Name, rateBp, category), mineWild.Group, false, false);
        }

        if (wildcard is not null && _options.Ledgers.TryGetValue(wildcard, out var defWild) && !string.IsNullOrWhiteSpace(defWild.Name))
        {
            return new GlLedger(key, Fill(defWild.Name, rateBp, category), defWild.Group, true, false);
        }

        return new GlLedger(key, key, null, true, true);
    }

    private static string Fill(string template, int? rateBp, string category)
    {
        var rate = rateBp is null ? "" : (rateBp.Value / 100m).ToString("0.##", CultureInfo.InvariantCulture);
        var cat = category.Length == 0 ? "" : char.ToUpperInvariant(category[0]) + category[1..].Replace('_', ' ');
        return template.Replace("{rate}", rate, StringComparison.Ordinal).Replace("{category}", cat, StringComparison.Ordinal).Trim();
    }
}

internal sealed record GlLedger(string Key, string Name, string? Group, bool IsDefault, bool Unmapped);
