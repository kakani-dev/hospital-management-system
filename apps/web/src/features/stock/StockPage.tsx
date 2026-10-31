import { useId, useState, type FormEvent, type ReactNode, type SelectHTMLAttributes } from 'react'
import { useSearchParams } from 'react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { FormField } from '../../components/ui/FormField'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import type { StockItem, StockLowAlert, StockOnHandRow, StockStore, StockUom } from '../../lib/api/types'
import { formatPaise, parseRupeesToPaise } from '../billing/money'
import { useBranches } from '../../lib/api/hooks'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { ScanInput } from '../../components/scan/ScanInput'
import type { Gs1Scan } from '../../lib/gs1'

const selectClass = 'mt-1 min-h-11 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700'

const ITEM_KINDS = [
  { value: 'drug', label: 'Drug' },
  { value: 'consumable', label: 'Consumable' },
] as const

const SCHEDULES = ['OTC', 'G', 'H', 'H1', 'X', 'NDPS'] as const

const GST_RATES = [
  { bp: 0, label: '0%' },
  { bp: 500, label: '5%' },
  { bp: 1200, label: '12%' },
  { bp: 1800, label: '18%' },
  { bp: 2800, label: '28%' },
] as const

const STORE_KINDS = [
  { value: 'main', label: 'Main store' },
  { value: 'op_pharmacy', label: 'Pharmacy' },
  { value: 'ward', label: 'Ward store' },
] as const

const STORE_LABEL: Record<string, string> = {
  main: 'Main store',
  op_pharmacy: 'Pharmacy',
  ip_pharmacy: 'Inpatient pharmacy',
  ward: 'Ward store',
  ot: 'Operating theatre',
  lab: 'Lab',
  asset_spares: 'Asset spares',
}

const EXPIRY_LABEL = { expired: 'Expired', soon: 'Use soon', ok: 'In date' } as const

const EXPIRY_ROW = {
  expired: 'bg-red-50 text-red-950 dark:bg-red-950/40 dark:text-red-100',
  soon: 'bg-amber-50 text-amber-950 dark:bg-amber-950/30 dark:text-amber-100',
  ok: '',
} as const

type Tab = 'alerts' | 'items' | 'stores' | 'opening' | 'onhand'

function problemText(error: unknown): string {
  if (error instanceof ApiError) return error.problem?.detail ?? error.message
  return 'Something went wrong. Try again.'
}

function SelectField({ label, children, ...props }: { label: string; children: ReactNode } & SelectHTMLAttributes<HTMLSelectElement>) {
  const id = useId()
  return (
    <label htmlFor={id} className="block text-sm font-medium text-gray-800 dark:text-dark-100">
      {label}
      <select id={id} className={selectClass} {...props}>
        {children}
      </select>
    </label>
  )
}

function kindLabel(kind: string) {
  return ITEM_KINDS.find((k) => k.value === kind)?.label ?? kind
}

function gstLabel(bp: number) {
  return GST_RATES.find((r) => r.bp === bp)?.label ?? `${bp / 100}%`
}

export function StockPage() {
  const { has } = useCurrentContext()
  const canEdit = has('stock.edit')
  const canOpen = has('stock.open') && has('stock.approve')
  const [params, setParams] = useSearchParams()
  const requested = params.get('tab')
  const tab: Tab = requested === 'alerts' || requested === 'stores' || requested === 'onhand' || (requested === 'opening' && canOpen) ? requested : 'items'

  const setTab = (next: Tab) => {
    const nextParams = new URLSearchParams(params)
    nextParams.set('tab', next)
    setParams(nextParams, { replace: true })
  }

  const items = useQuery({ queryKey: ['inventory', 'items'], queryFn: () => apiClient.inventory.items() })
  const stores = useQuery({ queryKey: ['inventory', 'stores'], queryFn: () => apiClient.inventory.stores() })
  const branches = useBranches()

  const canSettings = has('admin.settings')
  const tabs: { id: Tab; label: string }[] = [
    { id: 'alerts', label: 'Alerts' },
    { id: 'items', label: 'Items' },
    { id: 'stores', label: 'Stores' },
    ...(canOpen ? [{ id: 'opening' as const, label: 'Opening stock' }] : []),
    { id: 'onhand', label: 'Stock on hand' },
  ]

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <header>
        <h1 className="text-xl font-medium text-gray-900 dark:text-dark-50">Stock</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-dark-200">Medicines and supplies, the places they are kept, and what is on the shelf.</p>
      </header>
      <div role="tablist" aria-label="Stock sections" className="flex flex-wrap gap-2">
        {tabs.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={tab === t.id}
            className={`min-h-11 rounded-lg px-4 text-sm ${tab === t.id ? 'bg-primary-600 text-white' : 'bg-gray-100 text-gray-800 dark:bg-dark-600 dark:text-dark-100'}`}
            onClick={() => setTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'alerts' && (
        <AlertsPanel
          branches={(branches.data ?? []).map((b) => ({ id: b.id, name: b.name }))}
          canEdit={canEdit}
          canSettings={canSettings}
        />
      )}
      {tab === 'items' && <ItemsPanel catalog={items.data} loading={items.isPending} error={items.error} canEdit={canEdit} stores={stores.data ?? []} uoms={items.data?.uoms ?? []} />}
      {tab === 'stores' && (
        <StoresPanel
          stores={stores.data}
          loading={stores.isPending}
          error={stores.error}
          canEdit={canEdit}
          branchName={(id) => branches.data?.find((b) => b.id === id)?.name ?? 'Branch'}
          branches={(branches.data ?? []).map((b) => ({ id: b.id, name: b.name }))}
        />
      )}
      {tab === 'opening' && canOpen && <OpeningPanel items={items.data?.items ?? []} stores={stores.data ?? []} />}
      {tab === 'onhand' && <OnHandPanel items={items.data?.items ?? []} stores={stores.data ?? []} />}
    </div>
  )
}

function ItemsPanel({
  catalog,
  loading,
  error,
  canEdit,
  stores,
  uoms,
}: {
  catalog: { items: StockItem[] } | undefined
  loading: boolean
  error: unknown
  canEdit: boolean
  stores: StockStore[]
  uoms: StockUom[]
}) {
  if (loading) return <LoadingBlock label="Loading items" />
  if (error) return <Alert tone="error">{problemText(error)}</Alert>
  const rows = catalog?.items ?? []
  return (
    <div className="space-y-4">
      <Card title="Item list">
        {rows.length === 0 ? (
          <p className="text-sm text-gray-600 dark:text-dark-200">No items yet.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead>
                <tr className="text-gray-500">
                  <th className="py-2 pr-3 font-medium">Code</th>
                  <th className="py-2 pr-3 font-medium">Name</th>
                  <th className="py-2 pr-3 font-medium">Kind</th>
                  <th className="py-2 pr-3 font-medium">Generic</th>
                  <th className="py-2 pr-3 font-medium">Schedule</th>
                  <th className="py-2 pr-3 font-medium">HSN</th>
                  <th className="py-2 font-medium">GST</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((item) => (
                  <tr key={item.id} className="border-t border-gray-100 dark:border-dark-500" data-testid="stock-item-row" data-item-code={item.code}>
                    <td className="py-2 pr-3">{item.code}</td>
                    <td className="py-2 pr-3">
                      {item.brandName}
                      {item.strength ? ` ${item.strength}` : ''}
                      {item.dosageForm ? `, ${item.dosageForm}` : ''}
                    </td>
                    <td className="py-2 pr-3">{kindLabel(item.itemKind)}</td>
                    <td className="py-2 pr-3">{item.genericName ?? '—'}</td>
                    <td className="py-2 pr-3">{item.scheduleCode ?? '—'}</td>
                    <td className="py-2 pr-3">{item.hsnCode}</td>
                    <td className="py-2">{gstLabel(item.gstRateBp)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
      {canEdit && <ItemForm stores={stores} uoms={uoms} />}
    </div>
  )
}

function ItemForm({ stores, uoms }: { stores: StockStore[]; uoms: StockUom[] }) {
  const qc = useQueryClient()
  const [kind, setKind] = useState('drug')
  const [brand, setBrand] = useState('')
  const [generic, setGeneric] = useState('')
  const [strength, setStrength] = useState('')
  const [form, setForm] = useState('')
  const [route, setRoute] = useState('')
  const [maker, setMaker] = useState('')
  const [schedule, setSchedule] = useState('')
  const [hsn, setHsn] = useState('')
  const [gst, setGst] = useState('')
  const [base, setBase] = useState('')
  const [packUom, setPackUom] = useState('')
  const [units, setUnits] = useState('')
  const [purchase, setPurchase] = useState(true)
  const [sale, setSale] = useState(true)
  const [cold, setCold] = useState(false)
  const [high, setHigh] = useState(false)
  const [lasa, setLasa] = useState(false)
  const [storeId, setStoreId] = useState('')
  const [reorder, setReorder] = useState('')
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const save = useMutation({
    mutationFn: apiClient.inventory.createItem,
    onSuccess: async (item) => {
      setNotice(`Saved. The item code is ${item.code}.`)
      setError(null)
      setBrand('')
      setGeneric('')
      setStrength('')
      setForm('')
      setHsn('')
      await qc.invalidateQueries({ queryKey: ['inventory', 'items'] })
    },
  })

  const onSubmit = (event: FormEvent) => {
    event.preventDefault()
    setNotice(null)
    if (!brand.trim() || !maker.trim() || !hsn.trim() || !base || gst === '') {
      setError('Fill in the name, maker, HSN, GST, and base unit.')
      return
    }
    if (kind === 'drug' && !generic.trim()) {
      setError('A drug needs a generic name.')
      return
    }
    if (!/^[0-9]{4,8}$/.test(hsn.trim())) {
      setError('HSN is 4 to 8 digits.')
      return
    }
    const packUnits = units.trim() === '' ? null : Number(units)
    if (packUnits !== null && (!Number.isInteger(packUnits) || packUnits <= 1 || !packUom || packUom === base)) {
      setError('A pack uses a different unit from the base unit, and holds more than one.')
      return
    }
    const reorderQty = reorder.trim() === '' ? null : Number(reorder)
    if ((storeId === '') !== (reorderQty === null) || (reorderQty !== null && (!Number.isInteger(reorderQty) || reorderQty < 0))) {
      setError('Choose a store and a reorder quantity together, or leave both blank.')
      return
    }
    setError(null)
    save.mutate(
      {
        itemKind: kind,
        brandName: brand.trim(),
        ...(generic.trim() ? { genericName: generic.trim() } : {}),
        ...(strength.trim() ? { strength: strength.trim() } : {}),
        ...(form.trim() ? { dosageForm: form.trim() } : {}),
        ...(route.trim() ? { route: route.trim() } : {}),
        manufacturerName: maker.trim(),
        ...(kind === 'drug' && schedule ? { scheduleCode: schedule } : {}),
        hsnCode: hsn.trim(),
        gstRateBp: Number(gst),
        baseUomCode: base,
        ...(packUnits !== null
          ? { packs: [{ uomCode: packUom, unitsPerPack: packUnits, isPurchase: purchase, isSale: sale }] }
          : {}),
        isColdChain: cold,
        isHighAlert: high,
        isLasa: lasa,
        ...(storeId && reorderQty !== null ? { storeId, reorderLevel: reorderQty } : {}),
      },
      { onError: (err) => setError(problemText(err)) },
    )
  }

  return (
    <Card title="Add an item">
      <form className="grid gap-3 sm:grid-cols-2" onSubmit={onSubmit}>
        <p className="sm:col-span-2 text-sm text-gray-600 dark:text-dark-200">The item code is assigned when you save.</p>
        {notice && (
          <div className="sm:col-span-2">
            <Alert>{notice}</Alert>
          </div>
        )}
        {error && (
          <div className="sm:col-span-2">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        <SelectField label="Kind" value={kind} onChange={(e) => setKind(e.target.value)}>
          {ITEM_KINDS.map((k) => (
            <option key={k.value} value={k.value}>
              {k.label}
            </option>
          ))}
        </SelectField>
        <FormField label="Brand name" value={brand} onChange={(e) => setBrand(e.target.value)} autoComplete="off" />
        <FormField label="Generic name" value={generic} onChange={(e) => setGeneric(e.target.value)} autoComplete="off" hint={kind === 'drug' ? 'Required for a drug' : undefined} />
        <FormField label="Strength" value={strength} onChange={(e) => setStrength(e.target.value)} autoComplete="off" />
        <FormField label="Form" value={form} onChange={(e) => setForm(e.target.value)} autoComplete="off" />
        <FormField label="Route" value={route} onChange={(e) => setRoute(e.target.value)} autoComplete="off" />
        <FormField label="Maker" value={maker} onChange={(e) => setMaker(e.target.value)} autoComplete="off" />
        {kind === 'drug' && (
          <SelectField label="Schedule" value={schedule} onChange={(e) => setSchedule(e.target.value)}>
            <option value="">No schedule</option>
            {SCHEDULES.map((code) => (
              <option key={code} value={code}>
                {code}
              </option>
            ))}
          </SelectField>
        )}
        <FormField label="HSN" value={hsn} onChange={(e) => setHsn(e.target.value)} inputMode="numeric" autoComplete="off" />
        <SelectField label="GST" value={gst} onChange={(e) => setGst(e.target.value)}>
          <option value="">Choose a rate</option>
          {GST_RATES.map((rate) => (
            <option key={rate.bp} value={rate.bp}>
              {rate.label}
            </option>
          ))}
        </SelectField>
        <SelectField label="Base unit" value={base} onChange={(e) => setBase(e.target.value)}>
          <option value="">Choose a unit</option>
          {uoms.map((u) => (
            <option key={u.code} value={u.code}>
              {u.name} ({u.code})
            </option>
          ))}
        </SelectField>
        <SelectField label="Pack unit" value={packUom} onChange={(e) => setPackUom(e.target.value)}>
          <option value="">No pack</option>
          {uoms.map((u) => (
            <option key={u.code} value={u.code}>
              {u.name} ({u.code})
            </option>
          ))}
        </SelectField>
        <FormField label="Units in a pack" value={units} onChange={(e) => setUnits(e.target.value)} inputMode="numeric" autoComplete="off" hint="Leave blank when you are not adding a pack" />
        <SelectField label="Reorder at store" value={storeId} onChange={(e) => setStoreId(e.target.value)}>
          <option value="">No reorder level</option>
          {stores.map((store) => (
            <option key={store.id} value={store.id}>
              {store.name} ({store.code})
            </option>
          ))}
        </SelectField>
        <FormField label="Reorder when quantity falls below" value={reorder} onChange={(e) => setReorder(e.target.value)} inputMode="numeric" autoComplete="off" />
        <div className="flex flex-wrap gap-4 sm:col-span-2 text-sm">
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={purchase} onChange={(e) => setPurchase(e.target.checked)} /> Bought in this pack
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={sale} onChange={(e) => setSale(e.target.checked)} /> Sold in this pack
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={cold} onChange={(e) => setCold(e.target.checked)} /> Keep cold
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={high} onChange={(e) => setHigh(e.target.checked)} /> High-alert medicine
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={lasa} onChange={(e) => setLasa(e.target.checked)} /> Look-alike or sound-alike
          </label>
        </div>
        <div className="sm:col-span-2">
          <Button type="submit" disabled={save.isPending}>
            Save item
          </Button>
        </div>
      </form>
    </Card>
  )
}

function StoresPanel({
  stores,
  loading,
  error,
  canEdit,
  branchName,
  branches,
}: {
  stores: StockStore[] | undefined
  loading: boolean
  error: unknown
  canEdit: boolean
  branchName: (id: string) => string
  branches: { id: string; name: string }[]
}) {
  if (loading) return <LoadingBlock label="Loading stores" />
  if (error) return <Alert tone="error">{problemText(error)}</Alert>
  const rows = stores ?? []
  return (
    <div className="space-y-4">
      <Card title="Store list">
        {rows.length === 0 ? (
          <p className="text-sm text-gray-600 dark:text-dark-200">No stores yet.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead>
                <tr className="text-gray-500">
                  <th className="py-2 pr-3 font-medium">Code</th>
                  <th className="py-2 pr-3 font-medium">Name</th>
                  <th className="py-2 pr-3 font-medium">Kind</th>
                  <th className="py-2 pr-3 font-medium">Branch</th>
                  <th className="py-2 font-medium">Licence</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((store) => (
                  <tr key={store.id} className="border-t border-gray-100 dark:border-dark-500" data-testid="stock-store-row" data-store-code={store.code}>
                    <td className="py-2 pr-3">{store.code}</td>
                    <td className="py-2 pr-3">{store.name}</td>
                    <td className="py-2 pr-3">{STORE_LABEL[store.storeKind] ?? store.storeKind}</td>
                    <td className="py-2 pr-3">{branchName(store.branchId)}</td>
                    <td className="py-2">{store.drugLicenceNo ? `${store.drugLicenceNo} until ${store.licenceValidTo}` : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
      {canEdit && <StoreForm branches={branches} />}
    </div>
  )
}

function StoreForm({ branches }: { branches: { id: string; name: string }[] }) {
  const qc = useQueryClient()
  const [branchId, setBranchId] = useState(branches[0]?.id ?? '')
  const [name, setName] = useState('')
  const [kind, setKind] = useState('main')
  const [licence, setLicence] = useState('')
  const [until, setUntil] = useState('')
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const pharmacy = kind === 'op_pharmacy'

  const save = useMutation({
    mutationFn: apiClient.inventory.createStore,
    onSuccess: async (store) => {
      setNotice(`Saved. The store code is ${store.code}.`)
      setError(null)
      setName('')
      await qc.invalidateQueries({ queryKey: ['inventory', 'stores'] })
    },
  })

  const onSubmit = (event: FormEvent) => {
    event.preventDefault()
    setNotice(null)
    if (!branchId || !name.trim()) {
      setError('Choose a branch and name the store.')
      return
    }
    if (pharmacy && (!licence.trim() || !until)) {
      setError('A pharmacy needs a licence number and the date it is valid until.')
      return
    }
    setError(null)
    save.mutate(
      {
        branchId,
        name: name.trim(),
        storeKind: kind,
        ...(pharmacy ? { drugLicenceNo: licence.trim(), licenceValidTo: until } : {}),
      },
      { onError: (err) => setError(problemText(err)) },
    )
  }

  return (
    <Card title="Add a store">
      <form className="grid gap-3 sm:grid-cols-2" onSubmit={onSubmit}>
        <p className="sm:col-span-2 text-sm text-gray-600 dark:text-dark-200">The store code is assigned when you save.</p>
        {notice && (
          <div className="sm:col-span-2">
            <Alert>{notice}</Alert>
          </div>
        )}
        {error && (
          <div className="sm:col-span-2">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        <SelectField label="Branch" value={branchId} onChange={(e) => setBranchId(e.target.value)}>
          {branches.map((branch) => (
            <option key={branch.id} value={branch.id}>
              {branch.name}
            </option>
          ))}
        </SelectField>
        <FormField label="Store name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="off" />
        <SelectField label="Store kind" value={kind} onChange={(e) => setKind(e.target.value)}>
          {STORE_KINDS.map((k) => (
            <option key={k.value} value={k.value}>
              {k.label}
            </option>
          ))}
        </SelectField>
        {pharmacy && (
          <>
            <FormField label="Drug licence number" value={licence} onChange={(e) => setLicence(e.target.value)} autoComplete="off" />
            <FormField label="Licence valid until" type="date" value={until} onChange={(e) => setUntil(e.target.value)} />
          </>
        )}
        <div className="sm:col-span-2">
          <Button type="submit" disabled={save.isPending}>
            Save store
          </Button>
        </div>
      </form>
    </Card>
  )
}

function OpeningPanel({ items, stores }: { items: StockItem[]; stores: StockStore[] }) {
  const qc = useQueryClient()
  const [key, setKey] = useState(() => crypto.randomUUID())
  const [storeId, setStoreId] = useState(stores[0]?.id ?? '')
  const [itemId, setItemId] = useState(items[0]?.id ?? '')
  const [batch, setBatch] = useState('')
  const [expiry, setExpiry] = useState('')
  const [mfg, setMfg] = useState('')
  const [mrp, setMrp] = useState('')
  const [cost, setCost] = useState('')
  const [qty, setQty] = useState('')
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [scanNote, setScanNote] = useState<string | null>(null)
  const [unlinked, setUnlinked] = useState<Gs1Scan | null>(null)
  const [linkItemId, setLinkItemId] = useState('')

  const applyScan = (scan: Gs1Scan, item: StockItem) => {
    setItemId(item.id)
    if (scan.batch) setBatch(scan.batch)
    if (scan.expiry) setExpiry(scan.expiry)
    setUnlinked(null)
    const filled = ['item', scan.batch && 'batch', scan.expiry && 'expiry'].filter(Boolean).join(', ')
    setScanNote(`Scanned ${item.brandName}: filled ${filled}. Check the prices and quantity, then save.`)
  }

  const onScan = async (scan: Gs1Scan) => {
    setScanNote(null)
    setError(null)
    try {
      const link = await apiClient.inventory.resolveGtin(scan.gtin!)
      if (link.item) {
        applyScan(scan, link.item)
      } else {
        setUnlinked(scan)
        setLinkItemId(itemId)
      }
    } catch (err) {
      setError(problemText(err))
    }
  }

  const link = useMutation({
    mutationFn: (body: { gtin: string; itemId: string }) => apiClient.inventory.linkGtin(body),
    onSuccess: (res) => {
      if (unlinked && res.item) applyScan(unlinked, res.item)
    },
    onError: (err) => setError(problemText(err)),
  })

  const save = useMutation({
    mutationFn: (body: { storeId: string; lines: Parameters<typeof apiClient.inventory.opening>[1]['lines'] }) =>
      apiClient.inventory.opening(key, body),
    onSuccess: async (doc) => {
      setNotice(`Saved. Opening stock ${doc.docNo} records you as the approver.`)
      setError(null)
      setBatch('')
      setQty('')
      setKey(crypto.randomUUID())
      await qc.invalidateQueries({ queryKey: ['inventory', 'stock'] })
    },
  })

  const onSubmit = (event: FormEvent) => {
    event.preventDefault()
    setNotice(null)
    const mrpPaise = parseRupeesToPaise(mrp)
    const costPaise = parseRupeesToPaise(cost)
    const quantity = Number(qty)
    if (!storeId || !itemId || !batch.trim() || !expiry || mrpPaise === null || costPaise === null || !Number.isInteger(quantity) || quantity < 1) {
      setError('Choose a store and an item, then enter the batch, expiry, prices, and a quantity of at least 1.')
      return
    }
    setError(null)
    save.mutate(
      {
        storeId,
        lines: [
          {
            itemId,
            batchNo: batch.trim(),
            expiryDate: expiry,
            ...(mfg ? { mfgDate: mfg } : {}),
            mrpPaise,
            purchaseRatePaise: costPaise,
            qtyBase: quantity,
          },
        ],
      },
      { onError: (err) => setError(problemText(err)) },
    )
  }

  return (
    <Card title="Opening stock">
      <form className="grid gap-3 sm:grid-cols-2" onSubmit={onSubmit}>
        <p className="sm:col-span-2 text-sm text-gray-600 dark:text-dark-200">
          The document number is assigned when you save. You are recorded as the approver.
        </p>
        {notice && (
          <div className="sm:col-span-2">
            <Alert>{notice}</Alert>
          </div>
        )}
        {error && (
          <div className="sm:col-span-2">
            <Alert tone="error">{error}</Alert>
          </div>
        )}
        <div className="sm:col-span-2">
          <ScanInput testId="opening-scan" label="Scan the pack barcode (fills item, batch and expiry)" onScan={(scan) => void onScan(scan)} />
          {scanNote && (
            <p className="mt-1 text-sm text-green-800 dark:text-green-300" data-testid="opening-scan-filled">
              {scanNote}
            </p>
          )}
        </div>
        {unlinked && (
          <div className="sm:col-span-2 rounded-md border border-amber-300 bg-amber-50 p-3 dark:border-amber-700 dark:bg-dark-700" data-testid="gtin-link-prompt">
            <p className="text-sm">
              Barcode <span className="font-mono">{unlinked.gtin}</span> is new in this hospital. Choose the catalogue item it belongs to. You do this once per product.
            </p>
            <div className="mt-2 flex flex-wrap items-end gap-2">
              <SelectField label="Catalogue item" value={linkItemId} onChange={(e) => setLinkItemId(e.target.value)} data-testid="gtin-link-item">
                <option value="">Choose an item</option>
                {items.map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.brandName} ({item.code})
                  </option>
                ))}
              </SelectField>
              <Button
                type="button"
                data-testid="gtin-link-save"
                disabled={!linkItemId || link.isPending}
                onClick={() => link.mutate({ gtin: unlinked.gtin!, itemId: linkItemId })}
              >
                Link barcode
              </Button>
              <Button type="button" variant="secondary" data-testid="gtin-link-cancel" onClick={() => setUnlinked(null)}>
                Not now
              </Button>
            </div>
          </div>
        )}
        <SelectField label="Store" value={storeId} onChange={(e) => setStoreId(e.target.value)}>
          {stores.map((store) => (
            <option key={store.id} value={store.id}>
              {store.name}
            </option>
          ))}
        </SelectField>
        <SelectField label="Item" value={itemId} onChange={(e) => setItemId(e.target.value)}>
          {items.map((item) => (
            <option key={item.id} value={item.id}>
              {item.brandName} ({item.code})
            </option>
          ))}
        </SelectField>
        <FormField label="Batch number on the pack" value={batch} onChange={(e) => setBatch(e.target.value)} autoComplete="off" />
        <FormField label="Expiry" type="date" value={expiry} onChange={(e) => setExpiry(e.target.value)} />
        <FormField label="Made on" type="date" value={mfg} onChange={(e) => setMfg(e.target.value)} hint="Optional" />
        <FormField label="MRP (rupees)" value={mrp} onChange={(e) => setMrp(e.target.value)} inputMode="decimal" autoComplete="off" />
        <FormField label="Purchase rate (rupees)" value={cost} onChange={(e) => setCost(e.target.value)} inputMode="decimal" autoComplete="off" />
        <FormField label="Quantity" value={qty} onChange={(e) => setQty(e.target.value)} inputMode="numeric" autoComplete="off" hint="In the base unit" />
        <div className="sm:col-span-2">
          <Button type="submit" disabled={save.isPending}>
            Save opening stock
          </Button>
        </div>
      </form>
    </Card>
  )
}

function OnHandPanel({ items, stores }: { items: StockItem[]; stores: StockStore[] }) {
  const [storeId, setStoreId] = useState('')
  const [itemId, setItemId] = useState('')
  const [lowOnly, setLowOnly] = useState(false)
  const stock = useQuery({
    queryKey: ['inventory', 'stock', storeId, itemId, lowOnly],
    queryFn: () => apiClient.inventory.stock({ storeId: storeId || undefined, itemId: itemId || undefined, lowStock: lowOnly }),
  })

  return (
    <Card title="Stock on hand">
      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <SelectField label="Store" value={storeId} onChange={(e) => setStoreId(e.target.value)}>
          <option value="">All stores</option>
          {stores.map((store) => (
            <option key={store.id} value={store.id}>
              {store.name}
            </option>
          ))}
        </SelectField>
        <SelectField label="Item" value={itemId} onChange={(e) => setItemId(e.target.value)}>
          <option value="">All items</option>
          {items.map((item) => (
            <option key={item.id} value={item.id}>
              {item.brandName}
            </option>
          ))}
        </SelectField>
        <label className="flex items-center gap-2 text-sm sm:col-span-2">
          <input type="checkbox" checked={lowOnly} onChange={(e) => setLowOnly(e.target.checked)} />
          Below reorder level
        </label>
      </div>
      {stock.isPending && <LoadingBlock label="Loading stock" />}
      {stock.error && <Alert tone="error">{problemText(stock.error)}</Alert>}
      {stock.data && stock.data.length === 0 && <p className="text-sm text-gray-600 dark:text-dark-200">Nothing is on the shelf for this filter.</p>}
      {stock.data && stock.data.length > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="text-gray-500">
                <th className="py-2 pr-3 font-medium">Store</th>
                <th className="py-2 pr-3 font-medium">Item</th>
                <th className="py-2 pr-3 font-medium">Batch</th>
                <th className="py-2 pr-3 font-medium">Expiry</th>
                <th className="py-2 pr-3 font-medium">Status</th>
                <th className="py-2 pr-3 font-medium">Quantity</th>
                <th className="py-2 pr-3 font-medium">MRP</th>
                <th className="py-2 font-medium">Purchase rate</th>
              </tr>
            </thead>
            <tbody>
              {stock.data.map((row) => (
                <StockRow key={`${row.storeId}-${row.batchId}`} row={row} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}

function StockRow({ row }: { row: StockOnHandRow }) {
  return (
    <tr className={`border-t border-gray-100 dark:border-dark-500 ${EXPIRY_ROW[row.expiryState]}`} data-expiry={row.expiryState} data-testid="stock-row" data-batch={row.batchNo}>
      <td className="py-2 pr-3">{row.storeName}</td>
      <td className="py-2 pr-3">
        {row.brandName} ({row.itemCode})
        {row.lowStock && (
          <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-900" data-testid="low-stock">
            Low stock{row.minQty != null ? ` · reorder ${row.minQty}` : ''}
          </span>
        )}
      </td>
      <td className="py-2 pr-3">{row.batchNo}</td>
      <td className="py-2 pr-3">{row.expiryDate}</td>
      <td className="py-2 pr-3">{EXPIRY_LABEL[row.expiryState]}</td>
      <td className="py-2 pr-3">
        {row.onHandBase} {row.baseUomCode}
      </td>
      <td className="py-2 pr-3">{formatPaise(row.mrpPaise)}</td>
      <td className="py-2">{formatPaise(row.purchaseRatePaise)}</td>
    </tr>
  )
}

function AlertsPanel({ branches, canEdit, canSettings }: { branches: { id: string; name: string }[]; canEdit: boolean; canSettings: boolean }) {
  const [branchId, setBranchId] = useState('')
  const alerts = useQuery({
    queryKey: ['inventory', 'alerts', branchId || 'all'],
    queryFn: () => apiClient.inventory.alerts(branchId || undefined),
  })
  const data = alerts.data
  const expired = data?.expiry.filter((e) => e.kind === 'expired') ?? []
  const nearing = data?.expiry.filter((e) => e.kind === 'near_expiry') ?? []

  return (
    <Card title="Stock alerts">
      <div className="mb-4 flex flex-wrap items-end gap-3">
        {branches.length > 1 && (
          <div className="w-56">
            <SelectField label="Branch" value={branchId} onChange={(e) => setBranchId(e.target.value)} data-testid="alerts-branch">
              <option value="">All my branches</option>
              {branches.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name}
                </option>
              ))}
            </SelectField>
          </div>
        )}
        {data && (
          <div className="flex flex-wrap gap-2 text-xs" data-testid="alert-counts">
            <span className="rounded-full bg-red-100 px-2 py-1 font-medium text-red-900">Expired {data.counts.expired}</span>
            <span className="rounded-full bg-amber-100 px-2 py-1 font-medium text-amber-900">
              Expiring in {data.nearExpiryDays} days {data.counts.nearExpiry}
            </span>
            <span className="rounded-full bg-sky-100 px-2 py-1 font-medium text-sky-900">Below reorder {data.counts.lowStock}</span>
          </div>
        )}
        {canSettings && data && <NearExpiryWindow days={data.nearExpiryDays} />}
      </div>
      {alerts.isPending && <LoadingBlock label="Loading alerts" />}
      {alerts.error && <Alert tone="error">{problemText(alerts.error)}</Alert>}
      {data && data.lowStock.length === 0 && data.expiry.length === 0 && (
        <p className="text-sm text-gray-600 dark:text-dark-200" data-testid="alerts-empty">
          No alerts. Everything is above its reorder level and nothing expires in the next {data.nearExpiryDays} days.
        </p>
      )}
      {data && expired.length > 0 && (
        <section className="mb-4" aria-label="Expired batches">
          <h3 className="mb-1 text-sm font-medium text-red-800">Expired: remove from the shelf (cannot be dispensed)</h3>
          <ExpiryTable rows={expired} />
        </section>
      )}
      {data && nearing.length > 0 && (
        <section className="mb-4" aria-label="Near-expiry batches">
          <h3 className="mb-1 text-sm font-medium text-amber-800">Expiring soon: dispensed first (FEFO)</h3>
          <ExpiryTable rows={nearing} />
        </section>
      )}
      {data && data.lowStock.length > 0 && (
        <section aria-label="Below reorder level">
          <h3 className="mb-1 text-sm font-medium text-gray-800 dark:text-dark-100">Below reorder level</h3>
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead>
                <tr className="text-gray-500">
                  <th className="py-2 pr-3 font-medium">Store</th>
                  <th className="py-2 pr-3 font-medium">Item</th>
                  <th className="py-2 pr-3 font-medium">On hand</th>
                  <th className="py-2 pr-3 font-medium">Reorder level</th>
                  <th className="py-2 font-medium">Order</th>
                </tr>
              </thead>
              <tbody>
                {data.lowStock.map((row) => (
                  <LowStockRow key={`${row.storeId}-${row.itemId}`} row={row} canEdit={canEdit} />
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </Card>
  )
}

function ExpiryTable({ rows }: { rows: { batchId: string; storeId: string; storeName: string; brandName: string; itemCode: string; batchNo: string; expiryDate: string; daysLeft: number; onHandBase: number; baseUomCode: string; valuePaise: number; kind: string }[] }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left text-sm">
        <thead>
          <tr className="text-gray-500">
            <th className="py-2 pr-3 font-medium">Store</th>
            <th className="py-2 pr-3 font-medium">Item</th>
            <th className="py-2 pr-3 font-medium">Batch</th>
            <th className="py-2 pr-3 font-medium">Expiry</th>
            <th className="py-2 pr-3 font-medium">Quantity</th>
            <th className="py-2 font-medium">MRP value</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={`${r.storeId}-${r.batchId}`} className="border-t border-gray-100 dark:border-dark-500" data-testid="expiry-alert" data-kind={r.kind} data-batch={r.batchNo}>
              <td className="py-2 pr-3">{r.storeName}</td>
              <td className="py-2 pr-3">
                {r.brandName} ({r.itemCode})
              </td>
              <td className="py-2 pr-3">{r.batchNo}</td>
              <td className="py-2 pr-3">
                {r.expiryDate}{' '}
                <span className="text-xs text-gray-500">
                  {r.daysLeft < 0 ? `${-r.daysLeft} days ago` : r.daysLeft === 0 ? 'today' : `in ${r.daysLeft} days`}
                </span>
              </td>
              <td className="py-2 pr-3">
                {r.onHandBase} {r.baseUomCode}
              </td>
              <td className="py-2">{formatPaise(r.valuePaise)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function LowStockRow({ row, canEdit }: { row: StockLowAlert; canEdit: boolean }) {
  const qc = useQueryClient()
  const [editing, setEditing] = useState(false)
  const [level, setLevel] = useState(String(row.reorderLevel))
  const [qty, setQty] = useState(row.reorderQty == null ? '' : String(row.reorderQty))
  const save = useMutation({
    mutationFn: () =>
      apiClient.inventory.setReorder(row.storeId, row.itemId, {
        reorderLevel: Number(level),
        reorderQty: qty.trim() === '' ? null : Number(qty),
      }),
    onSuccess: () => {
      setEditing(false)
      void qc.invalidateQueries({ queryKey: ['inventory'] })
    },
  })
  const valid = /^\d+$/.test(level.trim()) && (qty.trim() === '' || (/^\d+$/.test(qty.trim()) && Number(qty) > 0))
  return (
    <tr className="border-t border-gray-100 dark:border-dark-500" data-testid="low-stock-alert" data-item={row.itemCode}>
      <td className="py-2 pr-3">{row.storeName}</td>
      <td className="py-2 pr-3">
        {row.brandName} ({row.itemCode})
      </td>
      <td className="py-2 pr-3">
        {row.onHandBase} {row.baseUomCode}
      </td>
      <td className="py-2 pr-3">
        {editing ? (
          <span className="flex flex-wrap items-center gap-1">
            <input
              aria-label="Reorder level"
              className="w-20 rounded border border-gray-300 px-2 py-1 text-sm dark:border-dark-450 dark:bg-dark-800"
              inputMode="numeric"
              value={level}
              onChange={(e) => setLevel(e.target.value)}
              data-testid="reorder-level-input"
            />
            <input
              aria-label="Order quantity"
              placeholder="Order qty"
              className="w-24 rounded border border-gray-300 px-2 py-1 text-sm dark:border-dark-450 dark:bg-dark-800"
              inputMode="numeric"
              value={qty}
              onChange={(e) => setQty(e.target.value)}
              data-testid="reorder-qty-input"
            />
            <button type="button" className="rounded bg-primary-600 px-2 py-1 text-xs text-white disabled:opacity-50" disabled={!valid || save.isPending} onClick={() => save.mutate()} data-testid="reorder-save">
              Save
            </button>
            <button type="button" className="rounded px-2 py-1 text-xs text-gray-700 dark:text-dark-100" onClick={() => setEditing(false)}>
              Cancel
            </button>
            {save.error && <span className="text-xs text-red-700">{problemText(save.error)}</span>}
          </span>
        ) : (
          <span className="flex items-center gap-2">
            {row.reorderLevel} {row.baseUomCode}
            {canEdit && (
              <button type="button" className="rounded px-1.5 py-0.5 text-xs text-primary-700 hover:bg-gray-100 dark:text-primary-300" onClick={() => setEditing(true)} data-testid="reorder-edit">
                Change
              </button>
            )}
          </span>
        )}
      </td>
      <td className="py-2" data-testid="suggested-qty">
        {row.suggestedQty} {row.baseUomCode}
      </td>
    </tr>
  )
}

function NearExpiryWindow({ days }: { days: number }) {
  const qc = useQueryClient()
  const [value, setValue] = useState(String(days))
  const save = useMutation({
    mutationFn: () => apiClient.inventory.saveSettings({ nearExpiryDays: Number(value) }),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['inventory', 'alerts'] }),
  })
  const n = Number(value)
  const valid = /^\d+$/.test(value.trim()) && n >= 1 && n <= 365
  return (
    <div className="ml-auto flex items-center gap-1 text-xs">
      <label htmlFor="near-expiry-days">Warn before expiry (days)</label>
      <input
        id="near-expiry-days"
        className="w-16 rounded border border-gray-300 px-2 py-1 text-sm dark:border-dark-450 dark:bg-dark-800"
        inputMode="numeric"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        data-testid="near-expiry-days"
      />
      <button
        type="button"
        className="rounded bg-primary-600 px-2 py-1 text-xs text-white disabled:opacity-50"
        disabled={!valid || n === days || save.isPending}
        onClick={() => save.mutate()}
        data-testid="near-expiry-save"
      >
        Save
      </button>
      {!valid && <span className="text-red-700">1 to 365</span>}
      {save.error && <span className="text-red-700">{problemText(save.error)}</span>}
    </div>
  )
}
