import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { ApiError, apiClient } from '../../lib/api/client'
import type { GlLastExport, GlLedgerRow } from '../../lib/api/types'
import { formatPaise } from './money'

const TYPE_LABELS: Record<string, string> = {
  sales: 'Sales',
  credit_note: 'Credit notes',
  receipt: 'Receipts',
  refund: 'Refunds',
  journal: 'Journals',
}

function overlaps(last: GlLastExport | null | undefined, from: string, to: string) {
  return Boolean(last && last.from <= to && last.to >= from)
}

function save(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}

/**
 * #62 Tally / GL export for the period already chosen on the Earnings page. The preview loads on its
 * own; three small buttons download Tally vouchers, Tally ledger masters, or a CSV journal. Ledger
 * names come from the hospital's mapping (editable inline), falling back to configured defaults.
 */
export function GlExportPanel({ from, to, branchId }: { from: string; to: string; branchId: string | null }) {
  const [editing, setEditing] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const queryClient = useQueryClient()
  const query = { from, to, branchId: branchId ?? undefined }
  const preview = useQuery({
    queryKey: ['billing', 'gl', 'preview', from, to, branchId],
    queryFn: () => apiClient.billing.glPreview(query),
    enabled: Boolean(from && to),
  })
  const data = preview.data
  const repeat = overlaps(data?.lastExport, from, to)
  const unmapped = data?.ledgers.filter((l) => l.unmapped) ?? []

  async function download(kind: 'vouchers' | 'masters', format: 'xml' | 'csv') {
    const id = `${kind}-${format}`
    setBusy(id)
    setError(null)
    try {
      const file = await apiClient.billing.glExport({ ...query, kind, format })
      save(file.blob, file.filename)
      if (kind === 'vouchers') void queryClient.invalidateQueries({ queryKey: ['billing', 'gl'] })
    } catch (e) {
      setError(e instanceof ApiError && e.problem?.detail ? e.problem.detail : 'The export could not be made. Try again.')
    } finally {
      setBusy(null)
    }
  }

  return (
    <section data-testid="gl-export-panel" className="space-y-3 rounded-lg border border-gray-200 p-3 dark:border-dark-500">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="font-medium">Tally / GL export</h2>
          <p className="text-xs text-gray-500">Finalized bills, credit notes, receipts and refunds for {from} to {to}. Re-importing the same vouchers updates them in Tally; it does not duplicate.</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="primary" className="px-2 py-1 text-xs" data-testid="gl-export-vouchers-xml" disabled={!data || data.vouchers === 0 || data.unbalanced > 0 || busy !== null} onClick={() => void download('vouchers', 'xml')}>
            {busy === 'vouchers-xml' ? 'Preparing…' : 'Vouchers XML'}
          </Button>
          <Button variant="secondary" className="px-2 py-1 text-xs" data-testid="gl-export-masters-xml" disabled={!data || data.vouchers === 0 || busy !== null} onClick={() => void download('masters', 'xml')}>
            Ledgers XML
          </Button>
          <Button variant="secondary" className="px-2 py-1 text-xs" data-testid="gl-export-csv" disabled={!data || data.vouchers === 0 || data.unbalanced > 0 || busy !== null} onClick={() => void download('vouchers', 'csv')}>
            CSV journal
          </Button>
          <Button variant="ghost" className="px-2 py-1 text-xs" data-testid="gl-ledger-map-toggle" aria-expanded={editing} onClick={() => setEditing((v) => !v)}>
            {editing ? 'Close mapping' : 'Ledger mapping'}
          </Button>
        </div>
      </div>

      {preview.isPending && <p className="text-sm text-gray-500" data-testid="gl-preview-loading">Checking the period…</p>}
      {preview.isError && <Alert tone="error">The export preview could not be loaded. Check your connection and try again.</Alert>}
      {error && <Alert tone="error">{error}</Alert>}
      {data && (
        <div className="space-y-2" data-testid="gl-preview">
          <div className="flex flex-wrap gap-3 text-sm">
            {data.vouchers === 0 && <span data-testid="gl-preview-empty">No finalized entries in this period.</span>}
            {Object.entries(data.counts).map(([type, count]) => (
              <span key={type} data-testid={`gl-count-${type.replace('_', '-')}`}>{TYPE_LABELS[type] ?? type}: <strong>{count}</strong></span>
            ))}
            {data.vouchers > 0 && <span data-testid="gl-debit-total">Debits: <strong>{formatPaise(data.debitPaise)}</strong></span>}
            {data.skippedZero > 0 && <span className="text-gray-500" data-testid="gl-skipped-zero">{data.skippedZero} zero-value skipped</span>}
          </div>
          {data.unbalanced > 0 && <Alert tone="error">{data.unbalanced} voucher(s) do not balance, so nothing can be exported. Contact support.</Alert>}
          {unmapped.length > 0 && (
            <Alert tone="warning">
              <span data-testid="gl-unmapped">No ledger set for: {unmapped.map((l) => l.name).join(', ')}. Set them under Ledger mapping or create them in Tally first.</span>
            </Alert>
          )}
          {repeat && data.lastExport && (
            <Alert tone="warning">
              <span data-testid="gl-repeat-warning">
                This period overlaps an export on {data.lastExport.at.slice(0, 10)} ({data.lastExport.from} to {data.lastExport.to}, {data.lastExport.vouchers} vouchers). Tally will update those vouchers, but a CSV re-import would post them twice.
              </span>
            </Alert>
          )}
        </div>
      )}

      {editing && <LedgerMapEditor />}
    </section>
  )
}

function keyLabel(row: GlLedgerRow) {
  if (row.hint) return row.hint
  const [kind = '', rest] = row.key.split(':')
  const labels: Record<string, string> = {
    party: 'Debtor',
    sales: 'Income',
    gst: 'GST',
    tender: 'Tender',
    payacct: 'Account',
    vchtype: 'Voucher type',
    discount: 'Discount',
    round_off: 'Round-off',
    company: 'Tally company',
  }
  return rest ? `${labels[kind] ?? kind}: ${rest.replace('_', ' ')}` : labels[kind] ?? kind
}

/** Inline grid: change a name or group, blank a name to go back to the default, one Save for all. */
function LedgerMapEditor() {
  const queryClient = useQueryClient()
  const map = useQuery({ queryKey: ['billing', 'gl', 'ledgers'], queryFn: () => apiClient.billing.glLedgers() })
  const [draft, setDraft] = useState<Record<string, { name: string; group: string }>>({})
  const [saved, setSaved] = useState(false)

  const mutation = useMutation({
    mutationFn: () =>
      apiClient.billing.saveGlLedgers(Object.entries(draft).map(([key, v]) => ({ key, name: v.name.trim(), group: v.group.trim() || null }))),
    onSuccess: (data) => {
      queryClient.setQueryData(['billing', 'gl', 'ledgers'], data)
      void queryClient.invalidateQueries({ queryKey: ['billing', 'gl', 'preview'] })
      setDraft({})
      setSaved(true)
    },
  })

  if (map.isPending) return <p className="text-sm text-gray-500">Loading ledgers…</p>
  if (map.isError) return <Alert tone="error">The ledger mapping could not be loaded.</Alert>

  const dirty = Object.keys(draft).length > 0
  return (
    <form
      noValidate
      data-testid="gl-ledger-map"
      className="space-y-2"
      onSubmit={(e) => {
        e.preventDefault()
        if (dirty) mutation.mutate()
      }}
    >
      <p className="text-xs text-gray-500">Use the exact ledger names in your Tally company. Clear a name to go back to the default.</p>
      <div className="max-h-96 overflow-y-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr><th className="px-2 py-1">For</th><th className="px-2 py-1">Ledger name</th><th className="px-2 py-1">Under group</th></tr>
          </thead>
          <tbody>
            {map.data.ledgers.map((row) => {
              const edit = draft[row.key]
              const testKey = row.key.replace(/[^a-z0-9]+/g, '-')
              return (
                <tr key={row.key} data-testid={`gl-ledger-row-${testKey}`}>
                  <td className="px-2 py-1">
                    {keyLabel(row)}
                    {!row.isDefault && <span className="ml-1 text-xs text-primary-600">custom</span>}
                  </td>
                  <td className="px-2 py-1">
                    <input
                      aria-label={`Ledger name for ${keyLabel(row)}`}
                      data-testid={`gl-ledger-name-${testKey}`}
                      maxLength={100}
                      className="w-full rounded border border-gray-300 px-2 py-1 dark:border-dark-500 dark:bg-dark-700"
                      value={edit?.name ?? row.name}
                      onChange={(e) => setDraft((d) => ({ ...d, [row.key]: { name: e.target.value, group: d[row.key]?.group ?? row.group ?? '' } }))}
                    />
                  </td>
                  <td className="px-2 py-1">
                    {row.key === 'company' || row.key.startsWith('vchtype:') ? null : (
                      <input
                        aria-label={`Group for ${keyLabel(row)}`}
                        data-testid={`gl-ledger-group-${testKey}`}
                        maxLength={100}
                        className="w-full rounded border border-gray-300 px-2 py-1 dark:border-dark-500 dark:bg-dark-700"
                        value={edit?.group ?? row.group ?? ''}
                        onChange={(e) => setDraft((d) => ({ ...d, [row.key]: { name: d[row.key]?.name ?? row.name, group: e.target.value } }))}
                      />
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {mutation.isError && <Alert tone="error">{mutation.error instanceof ApiError && mutation.error.problem?.detail ? mutation.error.problem.detail : 'The mapping could not be saved.'}</Alert>}
      <div className="flex items-center gap-2">
        <Button type="submit" className="px-2 py-1 text-xs" data-testid="gl-ledger-map-save" disabled={!dirty || mutation.isPending}>
          {mutation.isPending ? 'Saving…' : 'Save mapping'}
        </Button>
        {dirty && <Button type="button" variant="ghost" className="px-2 py-1 text-xs" onClick={() => setDraft({})}>Discard</Button>}
        {saved && !dirty && <span className="text-xs text-green-700" data-testid="gl-ledger-map-saved">Saved</span>}
      </div>
    </form>
  )
}
