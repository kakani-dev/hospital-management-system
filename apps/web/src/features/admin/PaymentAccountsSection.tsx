import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Badge } from '@tailux/components/ui'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { FormField } from '../../components/ui/FormField'
import { ApiError, apiClient } from '../../lib/api/client'
import type { AddPaymentAccountRequest, PaymentAccount, PaymentAccountMode } from '../../lib/api/types'

const modes: { value: PaymentAccountMode; label: string }[] = [
  { value: 'upi', label: 'UPI' },
  { value: 'bank', label: 'Bank' },
  { value: 'card', label: 'Card terminal' },
]

function detail(a: PaymentAccount) {
  if (a.mode === 'upi') return a.vpa
  if (a.mode === 'bank') return [a.bankName, a.maskedAccount, a.ifsc].filter(Boolean).join(' · ')
  return `MID ${a.mid} · TID ${a.tid}`
}

/** Admin-only: the accounts a branch receives money into. One default per mode. */
export function PaymentAccountsSection({ branchId }: { branchId: string }) {
  const client = useQueryClient()
  const key = ['billing', 'payment-accounts', branchId]
  const accounts = useQuery({ queryKey: key, queryFn: () => apiClient.billing.paymentAccounts(branchId) })
  const [mode, setMode] = useState<PaymentAccountMode>('upi')
  const [form, setForm] = useState<Record<string, string>>({})
  const [error, setError] = useState<string | null>(null)
  const [removing, setRemoving] = useState<PaymentAccount | null>(null)
  const done = { onSuccess: () => client.invalidateQueries({ queryKey: key }), onError: (e: unknown) => setError(e instanceof ApiError ? e.message : 'Could not save') }
  const add = useMutation({ mutationFn: (body: AddPaymentAccountRequest) => apiClient.billing.addPaymentAccount(body), ...done })
  const update = useMutation({ mutationFn: (v: { id: string; body: { isActive?: boolean; isDefault?: boolean } }) => apiClient.billing.updatePaymentAccount(v.id, v.body), ...done })
  const remove = useMutation({ mutationFn: (id: string) => apiClient.billing.deletePaymentAccount(id), ...done })
  const field = (name: string, label: string, hint?: string) => (
    <FormField label={label} hint={hint} value={form[name] ?? ''} onChange={(e) => setForm({ ...form, [name]: e.target.value })} />
  )

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError(null)
    const trimmed = Object.fromEntries(Object.entries(form).map(([k, v]) => [k, v.trim()]).filter(([, v]) => v))
    await add.mutateAsync({ branchId, mode, label: trimmed.label ?? '', ...trimmed }).then(() => setForm({})).catch(() => undefined)
  }

  return (
    <section aria-label="Payment accounts" className="space-y-3 border-t pt-4">
      <h3 className="font-medium">Payment accounts</h3>
      {error && <Alert tone="error">{error}</Alert>}
      {accounts.data?.length === 0 && <Alert tone="info">No accounts yet. UPI QR codes stay off until a UPI ID is added.</Alert>}
      <ul className="space-y-2">
        {accounts.data?.map((a) => (
          <li key={a.id} data-testid="payment-account" className="flex flex-wrap items-center gap-2 text-sm">
            <span className="font-medium">{a.label}</span>
            <span className="text-gray-600 dark:text-dark-200">{detail(a)}</span>
            {a.isDefault && <Badge color="primary">Default</Badge>}
            {!a.isActive && <Badge>Inactive</Badge>}
            {a.isActive && !a.isDefault && (
              <Button variant="ghost" onClick={() => update.mutate({ id: a.id, body: { isDefault: true } })}>Make default</Button>
            )}
            <Button variant="ghost" onClick={() => update.mutate({ id: a.id, body: { isActive: !a.isActive } })}>
              {a.isActive ? 'Deactivate' : 'Activate'}
            </Button>
            <Button variant="ghost" onClick={() => setRemoving(a)}>Remove</Button>
          </li>
        ))}
      </ul>
      <form noValidate aria-label="Add payment account" onSubmit={submit} className="space-y-3">
        <label className="block text-sm">
          Type
          <select className="ml-2 rounded border px-2 py-1" value={mode} onChange={(e) => setMode(e.target.value as PaymentAccountMode)}>
            {modes.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
          </select>
        </label>
        {field('label', 'Account label')}
        {mode === 'upi' && <>{field('vpa', 'UPI ID', 'e.g. clinic@okaxis')}{field('payeeName', 'Payee name', 'Optional')}</>}
        {mode === 'bank' && <>{field('bankName', 'Bank')}{field('accountNumber', 'Account number', 'Only the last 4 digits are kept')}{field('ifsc', 'IFSC')}</>}
        {mode === 'card' && <>{field('mid', 'MID')}{field('tid', 'TID')}</>}
        <Button type="submit" disabled={add.isPending}>Add account</Button>
      </form>
      <ConfirmDialog
        open={removing !== null}
        title="Remove payment account?"
        confirmLabel="Remove"
        busy={remove.isPending}
        onCancel={() => setRemoving(null)}
        onConfirm={() => { if (removing) remove.mutate(removing.id); setRemoving(null) }}
      >
        Past payments keep this account. If it is the default, the next active account takes over.
      </ConfirmDialog>
    </section>
  )
}
