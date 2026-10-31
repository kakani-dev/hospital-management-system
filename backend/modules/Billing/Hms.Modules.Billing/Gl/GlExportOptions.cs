namespace Hms.Modules.Billing.Gl;

/// <summary>
/// #62: default ledger names and Tally voucher types. A tenant's own mapping (billing.gl_ledger_map) wins.
/// Defaults live in configuration (GlExport section), not in code. Keys: party:self|corporate|insurer,
/// sales:&lt;category&gt;, gst:cgst|sgst|igst, discount, round_off, tender:&lt;mode&gt;; "sales:*" is the
/// fallback for any category. Names may use {rate} (GST percent) and {category}.
/// </summary>
public sealed class GlExportOptions
{
    public const string Section = "GlExport";

    public Dictionary<string, GlLedgerDefault> Ledgers { get; init; } = new(StringComparer.Ordinal);

    public Dictionary<string, string> VoucherTypes { get; init; } = new(StringComparer.Ordinal);
}

public sealed class GlLedgerDefault
{
    public string Name { get; init; } = "";

    public string? Group { get; init; }
}
