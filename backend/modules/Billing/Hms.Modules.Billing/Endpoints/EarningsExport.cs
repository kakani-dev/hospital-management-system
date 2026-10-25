using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;

namespace Hms.Modules.Billing.Endpoints;

/// <summary>
/// CSV and a minimal XLSX workbook for the CA registers. No spreadsheet package: the repo has
/// none, and the file is headers plus numbers. Amounts are rupees with two decimals (paise / 100).
/// </summary>
internal static class EarningsExport
{
    internal static readonly string[] Sections =
    [
        "summary", "branches", "doctors", "services", "modes", "gst", "hsn",
        "sales", "credits", "refunds", "receipts", "cash", "ageing",
    ];

    internal static bool Known(string? section) =>
        section is not null && Sections.Contains(section, StringComparer.Ordinal);

    internal static byte[] Csv(JsonElement report, string section)
    {
        var (headers, rows) = Table(report, section);
        var sb = new StringBuilder();
        sb.Append(string.Join(',', headers.Select(CsvCell))).Append('\n');
        foreach (var row in rows)
        {
            sb.Append(string.Join(',', row.Select(CsvCell))).Append('\n');
        }

        var preamble = Encoding.UTF8.GetPreamble();
        var body = Encoding.UTF8.GetBytes(sb.ToString());
        var bytes = new byte[preamble.Length + body.Length];
        preamble.CopyTo(bytes, 0);
        body.CopyTo(bytes, preamble.Length);
        return bytes;
    }

    internal static byte[] Xlsx(JsonElement report, string? section)
    {
        var names = section is null ? Sections : [section];
        using var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            Write(zip, "[Content_Types].xml", ContentTypes(names.Length));
            Write(zip, "_rels/.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
                </Relationships>
                """);
            Write(zip, "xl/workbook.xml", Workbook(names));
            Write(zip, "xl/_rels/workbook.xml.rels", WorkbookRels(names.Length));
            for (var i = 0; i < names.Length; i++)
            {
                var (headers, rows) = Table(report, names[i]);
                Write(zip, $"xl/worksheets/sheet{i + 1}.xml", Sheet(headers, rows));
            }
        }

        return stream.ToArray();
    }

    internal static string Inr(long paise) =>
        (paise / 100m).ToString("0.00", CultureInfo.InvariantCulture);

    private static (string[] Headers, List<string[]> Rows) Table(JsonElement report, string section)
    {
        var focus = report.GetProperty("focus");
        return section switch
        {
            "summary" => Summary(focus, report.GetProperty("trend")),
            "branches" => Objects(report.GetProperty("branches"),
                ["Branch", "GSTIN", "Rank", "Share percent", "Gross billed", "Collected", "Net earnings", "Outstanding", "Bills", "Growth percent", "Direction"],
                b =>
                [
                    Text(b, "name"), Text(b, "gstin"), Text(b, "rank"), Text(b, "sharePct"),
                    Inr(Long(b, "grossBilledPaise")), Inr(Long(b, "collectedPaise")), Inr(Long(b, "netEarningsPaise")),
                    Inr(Long(b, "outstandingPaise")), Text(b, "billCount"), Change(b, "periodGrowthPct"), Text(b, "direction"),
                ]),
            "doctors" => Objects(report.GetProperty("doctors"),
                ["Doctor", "Rank", "Revenue (INR)", "Visits"],
                d => [Text(d, "name"), Text(d, "rank"), Inr(Long(d, "revenuePaise")), Text(d, "visits")]),
            "services" => Objects(report.GetProperty("services"),
                ["Service", "Code", "HSN/SAC", "Revenue (INR)", "Share percent"],
                s => [Text(s, "name"), Text(s, "code"), Text(s, "sac"), Inr(Long(s, "revenuePaise")), Text(s, "sharePct")]),
            "modes" => Objects(report.GetProperty("paymentModes"),
                ["Mode", "Collected (INR)", "Refunds (INR)", "Share percent"],
                m => [Text(m, "mode"), Inr(Long(m, "collectedPaise")), Inr(Long(m, "refundsPaise")), Text(m, "sharePct")]),
            "gst" => Gst(report),
            "hsn" => Objects(report.GetProperty("hsn"),
                ["HSN/SAC", "Taxable value", "CGST", "SGST", "IGST", "Quantity"],
                h => [Text(h, "sac"), Inr(Long(h, "taxablePaise")), Inr(Long(h, "cgstPaise")), Inr(Long(h, "sgstPaise")), Inr(Long(h, "igstPaise")), Text(h, "quantity")]),
            "sales" => Objects(report.GetProperty("sales"),
                ["Invoice number", "Date", "Party", "Supply", "GSTIN", "Taxable value", "CGST", "SGST", "IGST", "Tax", "Total"],
                s =>
                [
                    Text(s, "invoiceNumber"), Text(s, "date"), Text(s, "party"), Text(s, "supply"), Text(s, "gstin"),
                    Inr(Long(s, "taxablePaise")), Inr(Long(s, "cgstPaise")), Inr(Long(s, "sgstPaise")), Inr(Long(s, "igstPaise")),
                    Inr(Long(s, "taxPaise")), Inr(Long(s, "totalPaise")),
                ]),
            "credits" => Objects(report.GetProperty("creditNotes"),
                ["Credit note number", "Date", "Original invoice", "Party", "GSTIN", "Taxable value", "Tax", "Total"],
                s =>
                [
                    Text(s, "creditNoteNumber"), Text(s, "date"), Text(s, "originalInvoice"), Text(s, "party"), Text(s, "gstin"),
                    Inr(Long(s, "taxablePaise")), Inr(Long(s, "taxPaise")), Inr(Long(s, "totalPaise")),
                ]),
            "refunds" => Objects(report.GetProperty("refunds"),
                ["Receipt number", "Date", "Mode", "Amount (INR)", "Credit note number"],
                s => [Text(s, "receiptNumber"), Text(s, "date"), Text(s, "mode"), Inr(Long(s, "amountPaise")), Text(s, "creditNoteNumber")]),
            "receipts" => Objects(report.GetProperty("receipts"),
                ["Receipt number", "Date", "Mode", "Kind", "Amount (INR)"],
                s => [Text(s, "receiptNumber"), Text(s, "date"), Text(s, "mode"), Text(s, "kind"), Inr(Long(s, "amountPaise"))]),
            "cash" => Objects(report.GetProperty("dayEndCash"),
                ["Date", "Cash in", "Cash out", "Net cash", "Card", "UPI", "Bank"],
                s =>
                [
                    Text(s, "date"), Inr(Long(s, "cashInPaise")), Inr(Long(s, "cashOutPaise")), Inr(Long(s, "netCashPaise")),
                    Inr(Long(s, "cardPaise")), Inr(Long(s, "upiPaise")), Inr(Long(s, "bankPaise")),
                ]),
            "ageing" => Ageing(report.GetProperty("ageing")),
            _ => throw new ArgumentException($"Unknown section '{section}'."),
        };
    }

    private static (string[] Headers, List<string[]> Rows) Summary(JsonElement focus, JsonElement trend)
    {
        var rows = new List<string[]>
        {
            Metric("Gross billed", Inr(Long(focus, "grossBilledPaise")), focus, "grossBilled"),
            Metric("Collected", Inr(Long(focus, "collectedPaise")), focus, "collected"),
            Metric("Refunds", Inr(Long(focus, "refundsPaise")), focus, "refunds"),
            Metric("Net earnings", Inr(Long(focus, "netEarningsPaise")), focus, "netEarnings"),
            Metric("Outstanding", Inr(Long(focus, "outstandingPaise")), focus, null),
            Metric("Discount", Inr(Long(focus, "discountPaise")), focus, null),
            Metric("CGST", Inr(Long(focus, "cgstPaise")), focus, null),
            Metric("SGST", Inr(Long(focus, "sgstPaise")), focus, null),
            Metric("IGST", Inr(Long(focus, "igstPaise")), focus, null),
            Metric("Bills", Text(focus, "billCount"), focus, "billCount"),
            Metric("Average bill", MoneyOrBlank(focus, "averageBillPaise"), focus, "averageBill"),
            Metric("Collection efficiency", Text(focus, "collectionEfficiencyPct"), focus, "collectionEfficiency"),
            Metric("Refund rate", Text(focus, "refundRatePct"), focus, "refundRate"),
            Metric("Discount rate", Text(focus, "discountRatePct"), focus, null),
            Metric("Period growth", Change(focus, "periodGrowthPct"), focus, "grossBilled"),
            Metric("Month on month", Change(Delta(focus, "mom"), "pct"), focus, "mom"),
            Metric("Year on year", Change(Delta(focus, "yoy"), "pct"), focus, "yoy"),
        };
        rows.Add([]);
        rows.Add(["Bucket", "Gross billed", "Collected", "Net earnings"]);
        foreach (var bucket in trend.EnumerateArray())
        {
            rows.Add([Text(bucket, "bucket"), Inr(Long(bucket, "grossBilledPaise")), Inr(Long(bucket, "collectedPaise")), Inr(Long(bucket, "netEarningsPaise"))]);
        }

        return (["Metric", "Amount (INR)", "Direction", "Change percent"], rows);
    }

    private static (string[] Headers, List<string[]> Rows) Gst(JsonElement report)
    {
        var rows = new List<string[]>();
        foreach (var row in report.GetProperty("gstr1").EnumerateArray())
        {
            rows.Add(GstRow("GSTR-1", row, "B2C", "b2cTaxablePaise", "b2cCgstPaise", "b2cSgstPaise", "b2cIgstPaise", "b2cInvoices"));
            rows.Add(GstRow("GSTR-1", row, "B2B", "b2bTaxablePaise", "b2bCgstPaise", "b2bSgstPaise", "b2bIgstPaise", "b2bInvoices"));
            rows.Add(GstRow("GSTR-1", row, "Credit notes", "creditNoteTaxablePaise", "creditNoteCgstPaise", "creditNoteSgstPaise", "creditNoteIgstPaise", "creditNoteCount"));
        }

        foreach (var row in report.GetProperty("gstr3b").EnumerateArray())
        {
            rows.Add(["GSTR-3B", Text(row, "gstin"), Text(row, "month"), "Outward taxable", Inr(Long(row, "outwardTaxablePaise")), Inr(Long(row, "cgstPaise")), Inr(Long(row, "sgstPaise")), Inr(Long(row, "igstPaise")), ""]);
            rows.Add(["GSTR-3B", Text(row, "gstin"), Text(row, "month"), "Exempt outward", Inr(Long(row, "exemptOutwardPaise")), "0.00", "0.00", "0.00", ""]);
            rows.Add(["GSTR-3B", Text(row, "gstin"), Text(row, "month"), "Credit notes", Inr(Long(row, "creditTaxablePaise")), Inr(Long(row, "creditCgstPaise")), Inr(Long(row, "creditSgstPaise")), Inr(Long(row, "creditIgstPaise")), ""]);
            rows.Add(["GSTR-3B", Text(row, "gstin"), Text(row, "month"), "Net tax", "0.00", Inr(Long(row, "netCgstPaise")), Inr(Long(row, "netSgstPaise")), Inr(Long(row, "netIgstPaise")), ""]);
        }

        return (["Return", "GSTIN", "Month", "Supply", "Taxable value (INR)", "CGST", "SGST", "IGST", "Invoices"], rows);
    }

    private static string[] GstRow(string ret, JsonElement row, string supply, string taxable, string cgst, string sgst, string igst, string count) =>
        [ret, Text(row, "gstin"), Text(row, "month"), supply, Inr(Long(row, taxable)), Inr(Long(row, cgst)), Inr(Long(row, sgst)), Inr(Long(row, igst)), Text(row, count)];

    private static (string[] Headers, List<string[]> Rows) Ageing(JsonElement ageing) =>
    (
        ["Bucket", "Amount (INR)"],
        [
            ["0-30", Inr(Long(ageing, "b0To30Paise"))],
            ["31-60", Inr(Long(ageing, "b31To60Paise"))],
            ["61-90", Inr(Long(ageing, "b61To90Paise"))],
            ["90+", Inr(Long(ageing, "b90PlusPaise"))],
        ]
    );

    private static (string[] Headers, List<string[]> Rows) Objects(JsonElement array, string[] headers, Func<JsonElement, string[]> map)
    {
        var rows = new List<string[]>();
        foreach (var item in array.EnumerateArray())
        {
            rows.Add(map(item));
        }

        return (headers, rows);
    }

    private static string[] Metric(string name, string amount, JsonElement focus, string? delta)
    {
        if (delta is null)
        {
            return [name, amount, "", ""];
        }

        var move = Delta(focus, delta);
        return [name, amount, Text(move, "direction"), Change(move, "pct")];
    }

    private static JsonElement Delta(JsonElement focus, string name) =>
        focus.GetProperty("deltas").GetProperty(name);

    private static string MoneyOrBlank(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number ? Inr(value.GetInt64()) : "";

    private static string Change(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDecimal().ToString(CultureInfo.InvariantCulture)
            : "";

    private static long Long(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetInt64() : 0;

    private static string Text(JsonElement item, string name)
    {
        if (!item.TryGetProperty(name, out var value) || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return "";
        }

        return value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : value.ToString();
    }

    private static string CsvCell(string value)
    {
        if (value.Contains('"') || value.Contains(',') || value.Contains('\n') || value.Contains('\r'))
        {
            return "\"" + value.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
        }

        return value;
    }

    private static void Write(ZipArchive zip, string name, string xml)
    {
        var entry = zip.CreateEntry(name, CompressionLevel.Fastest);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        writer.Write(xml);
    }

    private static string ContentTypes(int sheets)
    {
        var sb = new StringBuilder();
        sb.Append("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            """);
        for (var i = 1; i <= sheets; i++)
        {
            sb.Append($"""<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>""");
        }

        sb.Append("</Types>");
        return sb.ToString();
    }

    private static string Workbook(string[] names)
    {
        var sb = new StringBuilder();
        sb.Append("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets>
            """);
        for (var i = 0; i < names.Length; i++)
        {
            sb.Append($"""<sheet name="{XmlEscape(SheetName(names[i]))}" sheetId="{i + 1}" r:id="rId{i + 1}"/>""");
        }

        sb.Append("</sheets></workbook>");
        return sb.ToString();
    }

    private static string WorkbookRels(int sheets)
    {
        var sb = new StringBuilder();
        sb.Append("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            """);
        for (var i = 1; i <= sheets; i++)
        {
            sb.Append($"""<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>""");
        }

        sb.Append("</Relationships>");
        return sb.ToString();
    }

    private static string Sheet(string[] headers, List<string[]> rows)
    {
        var sb = new StringBuilder();
        sb.Append("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            """);
        WriteRow(sb, 1, headers, header: true);
        var excelRow = 2;
        foreach (var row in rows)
        {
            if (row.Length == 0)
            {
                excelRow++;
                continue;
            }

            WriteRow(sb, excelRow, row, header: false);
            excelRow++;
        }

        sb.Append("</sheetData></worksheet>");
        return sb.ToString();
    }

    private static void WriteRow(StringBuilder sb, int index, string[] cells, bool header)
    {
        sb.Append($"""<row r="{index}">""");
        for (var c = 0; c < cells.Length; c++)
        {
            var cell = cells[c] ?? "";
            var reference = Column(c) + index.ToString(CultureInfo.InvariantCulture);
            if (!header && decimal.TryParse(cell, NumberStyles.Number, CultureInfo.InvariantCulture, out var number) && cell.Length > 0 && cell != "-")
            {
                sb.Append($"""<c r="{reference}"><v>{number.ToString(CultureInfo.InvariantCulture)}</v></c>""");
            }
            else
            {
                sb.Append($"""<c r="{reference}" t="inlineStr"><is><t>{XmlEscape(cell)}</t></is></c>""");
            }
        }

        sb.Append("</row>");
    }

    private static string Column(int index)
    {
        var name = "";
        var n = index;
        do
        {
            name = (char)('A' + (n % 26)) + name;
            n = (n / 26) - 1;
        }
        while (n >= 0);
        return name;
    }

    private static string SheetName(string section) => section switch
    {
        "summary" => "Summary",
        "branches" => "Branches",
        "doctors" => "Doctors",
        "services" => "Services",
        "modes" => "Payment modes",
        "gst" => "GST summary",
        "hsn" => "HSN SAC",
        "sales" => "Sales register",
        "credits" => "Credit notes",
        "refunds" => "Refund register",
        "receipts" => "Receipts",
        "cash" => "Day-end cash",
        "ageing" => "Ageing",
        _ => "Sheet",
    };

    private static string XmlEscape(string value) =>
        value.Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal);
}
