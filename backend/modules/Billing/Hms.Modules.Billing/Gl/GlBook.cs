using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Xml;

namespace Hms.Modules.Billing.Gl;

internal sealed record GlEntry(GlLedger Ledger, long AmountPaise);

internal sealed record GlVoucher(
    string Id, string Type, string VoucherType, string Number, DateOnly Date, string? Against, bool Advance, IReadOnlyList<GlEntry> Entries)
{
    internal long DebitPaise => Entries.Where(e => e.AmountPaise > 0).Sum(e => e.AmountPaise);

    internal bool Balanced => Entries.Sum(e => e.AmountPaise) == 0;
}

/// <summary>
/// #62: turns the database voucher feed (ledger keys, + debit / - credit paise) into named ledgers,
/// and renders Tally XML (vouchers or ledger masters) and a flat CSV journal. No patient names leave:
/// narration carries document numbers only.
/// </summary>
internal static class GlBook
{
    internal static (IReadOnlyList<GlVoucher> Vouchers, int SkippedZero) Build(JsonElement feed, GlLedgers ledgers)
    {
        var list = new List<GlVoucher>();
        foreach (var v in feed.GetProperty("vouchers").EnumerateArray())
        {
            var merged = new Dictionary<string, (GlLedger Ledger, long Amount)>(StringComparer.Ordinal);
            var order = new List<string>();
            foreach (var e in v.GetProperty("entries").EnumerateArray())
            {
                int? rate = e.TryGetProperty("rateBp", out var r) && r.ValueKind == JsonValueKind.Number ? r.GetInt32() : null;
                var mode = e.TryGetProperty("mode", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() : null;
                var ledger = ledgers.Resolve(e.GetProperty("key").GetString()!, rate, mode);
                var amount = e.GetProperty("amountPaise").GetInt64();
                if (merged.TryGetValue(ledger.Name, out var have))
                {
                    merged[ledger.Name] = (have.Ledger, have.Amount + amount);
                }
                else
                {
                    merged[ledger.Name] = (ledger, amount);
                    order.Add(ledger.Name);
                }
            }

            var entries = order.Select(n => merged[n]).Where(x => x.Amount != 0).Select(x => new GlEntry(x.Ledger, x.Amount)).ToList();
            if (entries.Count == 0)
            {
                continue;
            }

            var type = v.GetProperty("type").GetString()!;
            list.Add(new GlVoucher(
                v.GetProperty("id").GetString()!,
                type,
                ledgers.VoucherType(type),
                v.GetProperty("number").GetString() ?? "",
                DateOnly.ParseExact(v.GetProperty("date").GetString()!, "yyyy-MM-dd", CultureInfo.InvariantCulture),
                v.TryGetProperty("against", out var a) && a.ValueKind == JsonValueKind.String ? a.GetString() : null,
                v.TryGetProperty("advance", out var adv) && adv.ValueKind == JsonValueKind.True,
                entries));
        }

        var skipped = feed.TryGetProperty("skippedZero", out var s) && s.ValueKind == JsonValueKind.Number ? s.GetInt32() : 0;
        return (list, skipped);
    }

    internal static string Narration(GlVoucher v) => v.Type switch
    {
        "sales" => $"Bill {v.Number}",
        "credit_note" => v.Against is null ? $"Credit note {v.Number}" : $"Credit note {v.Number} against bill {v.Against}",
        "refund" => v.Against is null ? $"Refund {v.Number}" : $"Refund {v.Number} of receipt {v.Against}",
        _ => v.Advance ? $"Advance receipt {v.Number}" : $"Receipt {v.Number}",
    };

    internal static string Amount(long paise) => (paise / 100m).ToString("0.00", CultureInfo.InvariantCulture);

    internal static byte[] Csv(IReadOnlyList<GlVoucher> vouchers)
    {
        var sb = new StringBuilder();
        sb.Append("Date,Voucher Type,Voucher No,Reference,Ledger,Group,Debit,Credit,Narration\r\n");
        foreach (var v in vouchers)
        {
            foreach (var e in v.Entries)
            {
                sb.Append(v.Date.ToString("dd-MM-yyyy", CultureInfo.InvariantCulture)).Append(',')
                  .Append(Cell(v.VoucherType)).Append(',').Append(Cell(v.Number)).Append(',').Append(Cell(v.Against ?? "")).Append(',')
                  .Append(Cell(e.Ledger.Name)).Append(',').Append(Cell(e.Ledger.Group ?? "")).Append(',')
                  .Append(e.AmountPaise > 0 ? Amount(e.AmountPaise) : "").Append(',')
                  .Append(e.AmountPaise < 0 ? Amount(-e.AmountPaise) : "").Append(',')
                  .Append(Cell(Narration(v))).Append("\r\n");
            }
        }

        return Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(sb.ToString())).ToArray();
    }

    // Spreadsheet formula injection guard plus RFC 4180 quoting.
    private static string Cell(string value)
    {
        var text = value.Length > 0 && "=+-@\t\r".Contains(value[0], StringComparison.Ordinal) ? "'" + value : value;
        return text.IndexOfAny([',', '"', '\n', '\r']) >= 0 ? "\"" + text.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"" : text;
    }

    /// <summary>Tally "Import Data" envelope with vouchers. REMOTEID is stable per document so a re-import alters, not duplicates.</summary>
    internal static byte[] TallyVouchers(IReadOnlyList<GlVoucher> vouchers, string? company)
    {
        return Envelope("Vouchers", company, w =>
        {
            foreach (var v in vouchers)
            {
                w.WriteStartElement("TALLYMESSAGE");
                w.WriteStartElement("VOUCHER");
                w.WriteAttributeString("REMOTEID", "hms-" + v.Id);
                w.WriteAttributeString("VCHTYPE", v.VoucherType);
                w.WriteAttributeString("ACTION", "Create");
                w.WriteElementString("DATE", v.Date.ToString("yyyyMMdd", CultureInfo.InvariantCulture));
                w.WriteElementString("VOUCHERTYPENAME", v.VoucherType);
                w.WriteElementString("VOUCHERNUMBER", v.Number);
                if (v.Against is not null)
                {
                    w.WriteElementString("REFERENCE", v.Against);
                }

                w.WriteElementString("NARRATION", Narration(v));
                w.WriteElementString("PERSISTEDVIEW", "Accounting Voucher View");
                foreach (var e in v.Entries)
                {
                    w.WriteStartElement("ALLLEDGERENTRIES.LIST");
                    w.WriteElementString("LEDGERNAME", e.Ledger.Name);
                    // Tally: debit = deemed positive with a negative amount; credit = positive amount.
                    w.WriteElementString("ISDEEMEDPOSITIVE", e.AmountPaise > 0 ? "Yes" : "No");
                    w.WriteElementString("AMOUNT", Amount(-e.AmountPaise));
                    w.WriteEndElement();
                }

                w.WriteEndElement();
                w.WriteEndElement();
            }
        });
    }

    /// <summary>Ledger masters (name + parent group) for every ledger the vouchers use, for a first import.</summary>
    internal static byte[] TallyMasters(IEnumerable<GlLedger> ledgers, string? company)
    {
        return Envelope("All Masters", company, w =>
        {
            foreach (var l in ledgers.GroupBy(x => x.Name, StringComparer.Ordinal).Select(g => g.First()).OrderBy(x => x.Name, StringComparer.Ordinal))
            {
                w.WriteStartElement("TALLYMESSAGE");
                w.WriteStartElement("LEDGER");
                w.WriteAttributeString("NAME", l.Name);
                w.WriteAttributeString("ACTION", "Create");
                w.WriteStartElement("NAME.LIST");
                w.WriteElementString("NAME", l.Name);
                w.WriteEndElement();
                if (l.Group is not null)
                {
                    w.WriteElementString("PARENT", l.Group);
                }

                w.WriteEndElement();
                w.WriteEndElement();
            }
        });
    }

    private static byte[] Envelope(string report, string? company, Action<XmlWriter> body)
    {
        using var ms = new MemoryStream();
        using (var w = XmlWriter.Create(ms, new XmlWriterSettings { Indent = true, Encoding = new UTF8Encoding(false) }))
        {
            w.WriteStartElement("ENVELOPE");
            w.WriteStartElement("HEADER");
            w.WriteElementString("TALLYREQUEST", "Import Data");
            w.WriteEndElement();
            w.WriteStartElement("BODY");
            w.WriteStartElement("IMPORTDATA");
            w.WriteStartElement("REQUESTDESC");
            w.WriteElementString("REPORTNAME", report);
            if (company is not null)
            {
                w.WriteStartElement("STATICVARIABLES");
                w.WriteElementString("SVCURRENTCOMPANY", company);
                w.WriteEndElement();
            }

            w.WriteEndElement();
            w.WriteStartElement("REQUESTDATA");
            body(w);
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteEndElement();
        }

        return ms.ToArray();
    }
}
