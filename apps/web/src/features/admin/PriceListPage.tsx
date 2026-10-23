import { useEffect, useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Badge } from '@tailux/components/ui'
import { Drawer } from '@tailux/components/shared/Drawer'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import { ApiError, apiClient } from '../../lib/api/client'
import type { Branch, Practitioner, PriceImportRow, PriceListSummary, ServiceItem } from '../../lib/api/types'
import { useAdminPractitioners, useBranches } from '../../lib/api/hooks'
import { localToday } from '../../lib/dates'
import { formatPaise, parseRupeesToPaise } from '../billing/money'
import { PRICE_CSV_TEMPLATE, SERVICE_CATEGORIES, parsePriceCsv, type ParsedPriceRow } from './priceCsv'
import { categoryLabel, formatIsoDate, formatPricePeriod, formatServiceTax } from './priceFormat'
import {
  priceEntrySchema,
  serviceItemEditSchema,
  serviceItemSchema,
  type PriceEntryValues,
  type ServiceItemEditValues,
  type ServiceItemValues,
} from './priceListSchema'

type Message = { tone: 'info' | 'error'; text: string }

const EMPTY_ITEM: ServiceItemValues = { code: '', name: '', category: 'procedure', taxCodeId: '' }

function problemText(error: unknown, fallback: string): string {
  if (!(error instanceof ApiError)) return fallback
  if (error.problem?.code === 'price_overlap') return error.problem.detail || 'That price overlaps an existing effective period.'
  if (error.status === 409) return 'That code is already in the price list.'
  return error.problem?.detail || fallback
}

function branchName(branches: Branch[], id: string | null): string {
  if (!id) return 'Hospital'
  return branches.find((b) => b.id === id)?.name ?? 'Branch'
}

function practitionerName(practitioners: Practitioner[], id: string | null): string {
  if (!id) return 'Any practitioner'
  return practitioners.find((p) => p.id === id)?.displayName ?? 'Practitioner'
}

/** Hospital price list: services beyond the consultation, with rates at hospital, branch or practitioner level. */
export function PriceListPage() {
  const qc = useQueryClient()
  const items = useQuery({
    queryKey: ['billing', 'service-items', 'admin'],
    queryFn: () => apiClient.billing.serviceItems({ includeInactive: true }),
    staleTime: 60_000,
  })
  const taxCodes = useQuery({
    queryKey: ['billing', 'tax-codes'],
    queryFn: () => apiClient.billing.taxCodes(),
    enabled: items.isSuccess,
    staleTime: 60_000,
  })
  const lists = useQuery({
    queryKey: ['billing', 'price-lists'],
    queryFn: () => apiClient.billing.priceLists(),
    enabled: items.isSuccess,
    staleTime: 60_000,
  })
  const branches = useBranches()
  const practitioners = useAdminPractitioners()
  const [search, setSearch] = useState('')
  const [showInactive, setShowInactive] = useState(false)
  const [message, setMessage] = useState<Message | null>(null)
  const [opened, setOpened] = useState<ServiceItem | null>(null)

  const saveItem = useMutation({
    mutationFn: apiClient.billing.saveServiceItem,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['billing', 'service-items'] })
    },
  })

  const liveBranches = (branches.data ?? []).filter((b) => b.isActive && !b.isDeleted)
  const livePractitioners = (practitioners.data ?? []).filter((p) => p.isActive && !p.isDeleted)
  const selected = (items.data ?? []).find((item) => item.id === opened?.id) ?? opened
  const needle = search.trim().toLowerCase()
  const rows = (items.data ?? []).filter((item) => {
    if (!showInactive && !item.isActive) return false
    if (!needle) return true
    return [item.code, item.name, item.category, item.sacHsnCode, categoryLabel(item.category)].some((value) => value.toLowerCase().includes(needle))
  })

  const toggleActive = (item: ServiceItem) => {
    setMessage(null)
    saveItem.mutate(
      { id: item.id, isActive: !item.isActive },
      {
        onSuccess: () =>
          setMessage({
            tone: 'info',
            text: item.isActive
              ? `${item.name} is now inactive. Turn on "Show inactive" to bring it back.`
              : `${item.name} is active again.`,
          }),
        onError: (error) => setMessage({ tone: 'error', text: problemText(error, `Could not change ${item.name}.`) }),
      },
    )
  }

  const columns: ColumnDef<ServiceItem, unknown>[] = [
    { id: 'code', accessorKey: 'code', header: 'Code' },
    { id: 'name', accessorKey: 'name', header: 'Name' },
    { id: 'category', accessorFn: (item) => categoryLabel(item.category), header: 'Category' },
    {
      id: 'tax',
      accessorFn: (item) => formatServiceTax(item.taxRateBp, item.sacHsnCode, item.isExempt),
      header: 'SAC / GST',
    },
    {
      id: 'rate',
      accessorFn: (item) => (item.hospitalPricePaise == null ? '' : item.hospitalPricePaise),
      header: 'Hospital rate',
      cell: ({ row: { original: item } }) => (
        <span className="font-mono">{item.hospitalPricePaise == null ? '—' : formatPaise(item.hospitalPricePaise)}</span>
      ),
    },
    {
      id: 'status',
      accessorFn: (item) => (item.isActive ? 'Active' : 'Inactive'),
      header: 'Status',
      cell: ({ row: { original: item } }) => (
        <Badge color={item.isActive ? 'success' : 'neutral'} variant="soft">
          {item.isActive ? 'Active' : 'Inactive'}
        </Badge>
      ),
    },
    {
      id: 'actions',
      enableSorting: false,
      header: () => <span className="sr-only">Actions</span>,
      cell: ({ row: { original: item } }) => (
        <div className="flex flex-wrap justify-end gap-2">
          <Button variant="secondary" className="h-11 sm:h-8" aria-label={`Edit ${item.name}`} onClick={() => setOpened(item)}>
            Edit
          </Button>
          <Button
            variant="secondary"
            className="h-11 sm:h-8"
            disabled={saveItem.isPending}
            aria-label={`${item.isActive ? 'Deactivate' : 'Activate'} ${item.name}`}
            onClick={() => toggleActive(item)}
          >
            {item.isActive ? 'Deactivate' : 'Activate'}
          </Button>
        </div>
      ),
    },
  ]

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Price list</h1>
        <p className="mt-1 text-sm text-gray-500 dark:text-dark-300">
          Practitioner rates override the branch, which overrides the hospital. Amounts are entered in rupees.
        </p>
      </div>
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      <Card title="Add service">
        <AddServiceForm
          taxCodes={taxCodes.data ?? []}
          taxLoading={!taxCodes.isSuccess}
          onCreated={(item) => {
            setOpened(item)
            setMessage({ tone: 'info', text: `${item.name} added. Set the rate in the panel.` })
          }}
          onMessage={setMessage}
        />
      </Card>
      <Card>
        <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <FormField
            label="Search services"
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Code, name, category or SAC"
            autoComplete="off"
          />
          <label className="flex min-h-11 items-center gap-2 text-sm text-gray-700 dark:text-dark-100">
            <input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} />
            Show inactive
          </label>
        </div>
        {items.isError && <Alert tone="error">Could not load services.</Alert>}
        <DataTable
          data={rows}
          columns={columns}
          caption="Billable services"
          isLoading={items.isPending}
          empty={needle ? 'No services match that search.' : 'No services yet. Add a dressing, certificate or procedure above.'}
          getRowId={(item) => item.id}
          getRowProps={(row) => ({ 'data-testid': 'service-item-row', 'data-code': row.original.code })}
        />
      </Card>
      <div className="grid gap-4 lg:grid-cols-2">
        <CopyPriceList
          lists={(lists.data ?? []).filter((list) => list.isActive)}
          branches={liveBranches}
          onMessage={setMessage}
        />
        <ImportPrices branches={liveBranches} onMessage={setMessage} />
      </div>
      {selected && (
        <Drawer open onClose={() => setOpened(null)} title={selected.name} closeLabel={`Close ${selected.name}`} testId="price-drawer" className="max-w-lg!">
          <PriceDrawer
            key={selected.id}
            item={selected}
            branches={liveBranches}
            practitioners={livePractitioners}
            taxCodes={taxCodes.data ?? []}
            onMessage={setMessage}
            onClose={() => setOpened(null)}
          />
        </Drawer>
      )}
    </div>
  )
}

function AddServiceForm({
  taxCodes,
  taxLoading,
  onCreated,
  onMessage,
}: {
  taxCodes: { id: string; code: string; sacHsnCode: string; rateBp: number; isExempt: boolean }[]
  taxLoading: boolean
  onCreated: (item: ServiceItem) => void
  onMessage: (message: Message | null) => void
}) {
  const qc = useQueryClient()
  const save = useMutation({
    mutationFn: apiClient.billing.saveServiceItem,
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['billing', 'service-items'] }),
  })
  const form = useForm<ServiceItemValues>({ resolver: zodResolver(serviceItemSchema), defaultValues: EMPTY_ITEM })
  useEffect(() => {
    if (taxCodes[0] && !form.getValues('taxCodeId')) form.setValue('taxCodeId', taxCodes[0].id)
  }, [taxCodes, form])

  const onSubmit = async (values: ServiceItemValues) => {
    onMessage(null)
    try {
      const created = await save.mutateAsync({
        code: values.code.trim(),
        name: values.name.trim(),
        category: values.category,
        taxCodeId: values.taxCodeId,
      })
      const tax = taxCodes.find((code) => code.id === values.taxCodeId)
      form.reset({ ...EMPTY_ITEM, taxCodeId: taxCodes[0]?.id ?? '' })
      onCreated({
        id: created.id,
        code: values.code.trim(),
        name: values.name.trim(),
        category: values.category,
        taxCodeId: values.taxCodeId,
        sacHsnCode: tax?.sacHsnCode ?? '',
        taxRateBp: tax?.rateBp ?? 0,
        isExempt: tax?.isExempt ?? false,
        isActive: true,
        isStockTracked: false,
        hospitalPricePaise: null,
      })
    } catch (error) {
      onMessage({ tone: 'error', text: problemText(error, 'Could not add the service.') })
    }
  }

  return (
    <form noValidate aria-label="Add service" onSubmit={form.handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5 lg:items-start">
      <FormField label="Code" hint="e.g. DRESS. It cannot be changed later." error={form.formState.errors.code?.message} autoComplete="off" {...form.register('code')} />
      <FormField label="Name" hint="Shown on the bill." error={form.formState.errors.name?.message} {...form.register('name')} />
      <SelectField label="Category" error={form.formState.errors.category?.message} {...form.register('category')}>
        {SERVICE_CATEGORIES.map((category) => (
          <option key={category} value={category}>
            {categoryLabel(category)}
          </option>
        ))}
      </SelectField>
      <SelectField label="SAC / GST" error={form.formState.errors.taxCodeId?.message} disabled={taxLoading} {...form.register('taxCodeId')}>
        {taxCodes.length === 0 && <option value="">{taxLoading ? 'Loading tax codes' : 'No tax code yet'}</option>}
        {taxCodes.map((code) => (
          <option key={code.id} value={code.id}>
            {formatServiceTax(code.rateBp, code.sacHsnCode, code.isExempt)}
          </option>
        ))}
      </SelectField>
      <div className="sm:pt-7">
        <Button type="submit" className="min-h-11 w-full sm:w-auto" disabled={form.formState.isSubmitting || taxLoading}>
          Add service
        </Button>
      </div>
    </form>
  )
}

function PriceDrawer({
  item,
  branches,
  practitioners,
  taxCodes,
  onMessage,
  onClose,
}: {
  item: ServiceItem
  branches: Branch[]
  practitioners: Practitioner[]
  taxCodes: { id: string; code: string; sacHsnCode: string; rateBp: number; isExempt: boolean }[]
  onMessage: (message: Message) => void
  onClose: () => void
}) {
  const qc = useQueryClient()
  const prices = useQuery({
    queryKey: ['billing', 'prices', item.id],
    queryFn: () => apiClient.billing.prices(item.id),
    staleTime: 60_000,
  })
  const saveItem = useMutation({
    mutationFn: apiClient.billing.saveServiceItem,
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['billing', 'service-items'] }),
  })
  const addPrice = useMutation({
    mutationFn: apiClient.billing.addPrice,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['billing', 'prices', item.id] })
      void qc.invalidateQueries({ queryKey: ['billing', 'service-items'] })
      void qc.invalidateQueries({ queryKey: ['billing', 'price-lists'] })
    },
  })
  const details = useForm<ServiceItemEditValues>({
    resolver: zodResolver(serviceItemEditSchema),
    defaultValues: { name: item.name, category: item.category as ServiceItemEditValues['category'], taxCodeId: item.taxCodeId },
  })
  const price = useForm<PriceEntryValues>({
    resolver: zodResolver(priceEntrySchema),
    defaultValues: { scope: 'tenant', branchId: '', practitionerId: '', rupees: '', effectiveFrom: localToday(), effectiveTo: '' },
  })
  const scope = useWatch({ control: price.control, name: 'scope' })
  const [priceError, setPriceError] = useState<string | null>(null)

  const saveDetails = async (values: ServiceItemEditValues) => {
    try {
      await saveItem.mutateAsync({ id: item.id, name: values.name.trim(), category: values.category, taxCodeId: values.taxCodeId })
      onMessage({ tone: 'info', text: `${values.name.trim()} saved.` })
    } catch (error) {
      onMessage({ tone: 'error', text: problemText(error, 'Could not save the service.') })
    }
  }

  const savePrice = async (values: PriceEntryValues) => {
    setPriceError(null)
    const paise = parseRupeesToPaise(values.rupees)
    if (paise === null) return
    try {
      await addPrice.mutateAsync({
        serviceItemId: item.id,
        unitPricePaise: paise,
        effectiveFrom: values.effectiveFrom,
        ...(values.effectiveTo ? { effectiveTo: values.effectiveTo } : {}),
        ...(values.scope !== 'tenant' && values.branchId ? { branchId: values.branchId } : {}),
        ...(values.scope === 'practitioner' ? { practitionerId: values.practitionerId } : {}),
      })
      price.reset({ ...values, rupees: '' })
      const where =
        values.scope === 'practitioner'
          ? practitionerName(practitioners, values.practitionerId)
          : values.scope === 'branch'
            ? branchName(branches, values.branchId)
            : 'the hospital'
      onMessage({ tone: 'info', text: `${formatPaise(paise)} saved for ${item.name} at ${where}, from ${formatIsoDate(values.effectiveFrom)}.` })
    } catch (error) {
      const text = problemText(error, 'Could not save the price.')
      setPriceError(text)
      onMessage({ tone: 'error', text })
    }
  }

  return (
    <div className="space-y-8">
      <p className="font-mono text-sm text-gray-500">{item.code}</p>
      <form noValidate aria-label="Edit service" onSubmit={details.handleSubmit(saveDetails)} className="space-y-4">
        <FormField label="Name" error={details.formState.errors.name?.message} {...details.register('name')} />
        <SelectField label="Category" error={details.formState.errors.category?.message} {...details.register('category')}>
          {SERVICE_CATEGORIES.map((category) => (
            <option key={category} value={category}>
              {categoryLabel(category)}
            </option>
          ))}
        </SelectField>
        <SelectField label="SAC / GST" error={details.formState.errors.taxCodeId?.message} {...details.register('taxCodeId')}>
          {taxCodes.map((code) => (
            <option key={code.id} value={code.id}>
              {formatServiceTax(code.rateBp, code.sacHsnCode, code.isExempt)}
            </option>
          ))}
        </SelectField>
        <Button type="submit" variant="secondary" className="min-h-11" disabled={details.formState.isSubmitting}>
          Save service
        </Button>
      </form>
      <section aria-label="Current prices" className="space-y-2">
        <h3 className="text-sm font-medium text-gray-800 dark:text-dark-100">Current prices</h3>
        {prices.isPending && <p className="text-sm text-gray-500">Loading prices…</p>}
        {prices.isError && <Alert tone="error">Could not load prices.</Alert>}
        {prices.data?.length === 0 && <p className="text-sm text-gray-500">No rate yet. The one you save below is the first.</p>}
        <ul className="divide-y divide-gray-200 dark:divide-dark-500">
          {prices.data?.map((row) => (
            <li key={row.id} className="flex flex-wrap items-baseline justify-between gap-2 py-2 text-sm" data-testid="price-row">
              <span>
                {row.practitionerId ? `${practitionerName(practitioners, row.practitionerId)} · ` : ''}
                {branchName(branches, row.branchId)}
                <span className="mt-0.5 block text-xs text-gray-500">{formatPricePeriod(row.effectiveFrom, row.effectiveTo)}</span>
              </span>
              <span className="font-mono">{formatPaise(row.unitPricePaise)}</span>
            </li>
          ))}
        </ul>
      </section>
      <form noValidate aria-label="Set a price" onSubmit={price.handleSubmit(savePrice)} className="space-y-4">
        <h3 className="text-sm font-medium text-gray-800 dark:text-dark-100">Set a price</h3>
        <p className="text-sm text-gray-500 dark:text-dark-300">A practitioner rate wins over the branch rate, which wins over the hospital rate. Leave the end date blank to keep this rate until the next one.</p>
        <SelectField label="Applies to" {...price.register('scope')}>
          <option value="tenant">Hospital</option>
          <option value="branch">One branch</option>
          <option value="practitioner">One practitioner</option>
        </SelectField>
        {scope !== 'tenant' && (
          <SelectField label="Branch" error={price.formState.errors.branchId?.message} {...price.register('branchId')}>
            <option value="">{scope === 'practitioner' ? 'Hospital list' : 'Choose a branch'}</option>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </SelectField>
        )}
        {scope === 'practitioner' && (
          <SelectField label="Practitioner" error={price.formState.errors.practitionerId?.message} {...price.register('practitionerId')}>
            <option value="">Choose a practitioner</option>
            {practitioners.map((person) => (
              <option key={person.id} value={person.id}>
                {person.displayName}
              </option>
            ))}
          </SelectField>
        )}
        <FormField label="Amount (rupees)" inputMode="decimal" autoComplete="off" error={price.formState.errors.rupees?.message} {...price.register('rupees')} />
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField label="Effective from" type="date" error={price.formState.errors.effectiveFrom?.message} {...price.register('effectiveFrom')} />
          <FormField label="Effective to (optional)" type="date" error={price.formState.errors.effectiveTo?.message} {...price.register('effectiveTo')} />
        </div>
        {priceError && <Alert tone="error">{priceError}</Alert>}
        <div className="flex flex-wrap gap-2">
          <Button type="submit" className="min-h-11" disabled={price.formState.isSubmitting}>
            Save price
          </Button>
          <Button variant="secondary" className="min-h-11" onClick={onClose}>
            Close
          </Button>
        </div>
      </form>
    </div>
  )
}

function CopyPriceList({
  lists,
  branches,
  onMessage,
}: {
  lists: PriceListSummary[]
  branches: Branch[]
  onMessage: (message: Message) => void
}) {
  const qc = useQueryClient()
  const hospital = lists.find((list) => list.branchId === null) ?? lists[0]
  const [sourceId, setSourceId] = useState('')
  const [branchId, setBranchId] = useState('')
  const [effectiveFrom, setEffectiveFrom] = useState(localToday())
  const source = lists.find((list) => list.id === (sourceId || hospital?.id))
  const copy = useMutation({
    mutationFn: apiClient.billing.copyPriceList,
    onSuccess: (result) => {
      if (!result.dryRun) {
        void qc.invalidateQueries({ queryKey: ['billing', 'price-lists'] })
        void qc.invalidateQueries({ queryKey: ['billing', 'prices'] })
        void qc.invalidateQueries({ queryKey: ['billing', 'service-items'] })
      }
    },
  })
  const targets = branches.filter((branch) => branch.id !== source?.branchId)

  const run = (dryRun: boolean) => {
    if (!source || !branchId) return
    copy.mutate(
      { sourcePriceListId: source.id, branchId, effectiveFrom, dryRun },
      {
        onSuccess: (result) => {
          if (dryRun) return
          const skipped = result.conflicts.length
          onMessage({
            tone: 'info',
            text: `Copied ${result.copied} ${result.copied === 1 ? 'rate' : 'rates'} to ${branchName(branches, branchId)}.${skipped ? ` ${skipped} overlapping ${skipped === 1 ? 'rate was' : 'rates were'} left unchanged.` : ''}`,
          })
        },
        onError: (error) => onMessage({ tone: 'error', text: problemText(error, 'Could not copy the price list.') }),
      },
    )
  }

  const preview = copy.data?.dryRun ? copy.data : null
  return (
    <Card title="Copy to a branch">
      <form
        className="space-y-4"
        aria-label="Copy price list"
        onSubmit={(event) => {
          event.preventDefault()
          run(true)
        }}
      >
        <p className="text-sm text-gray-500 dark:text-dark-300">
          Copies the rates in force on the date onto that branch. Services stay shared. Overlapping periods are skipped and listed before anything is written.
        </p>
        <SelectField label="Source list" value={source?.id ?? ''} onChange={(event) => { setSourceId(event.target.value); copy.reset() }}>
          {lists.map((list) => (
            <option key={list.id} value={list.id}>
              {list.name} · {branchName(branches, list.branchId)}
            </option>
          ))}
        </SelectField>
        <SelectField label="Copy to branch" value={branchId} onChange={(event) => { setBranchId(event.target.value); copy.reset() }}>
          <option value="">Choose a branch</option>
          {targets.map((branch) => (
            <option key={branch.id} value={branch.id}>
              {branch.name}
            </option>
          ))}
        </SelectField>
        <FormField label="Rates in force on" type="date" value={effectiveFrom} onChange={(event) => { setEffectiveFrom(event.target.value); copy.reset() }} />
        {preview && (
          <p role="status" className="text-sm">
            {preview.copied} {preview.copied === 1 ? 'rate' : 'rates'} will copy.
            {preview.conflicts.length > 0 && ` ${preview.conflicts.length} overlap and will be skipped: ${preview.conflicts.map((row) => row.code).join(', ')}.`}
          </p>
        )}
        {copy.isError && <Alert tone="error">{problemText(copy.error, 'Could not preview the copy.')}</Alert>}
        <div className="flex flex-wrap gap-2">
          <Button type="submit" variant="secondary" className="min-h-11" disabled={!source || !branchId || copy.isPending}>
            Preview copy
          </Button>
          <Button type="button" className="min-h-11" disabled={!preview || preview.copied === 0 || copy.isPending} onClick={() => run(false)}>
            Copy prices
          </Button>
        </div>
      </form>
    </Card>
  )
}

interface ImportViewRow extends ParsedPriceRow {
  clientIndex: number
  branchId: string
  status?: string
  detail?: string | null
}

function ImportPrices({ branches, onMessage }: { branches: Branch[]; onMessage: (message: Message) => void }) {
  const qc = useQueryClient()
  const [rows, setRows] = useState<ImportViewRow[] | null>(null)
  const [fileError, setFileError] = useState<string | null>(null)
  const preview = useMutation({ mutationFn: apiClient.billing.importPrices })
  const apply = useMutation({
    mutationFn: apiClient.billing.importPrices,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['billing', 'service-items'] })
      void qc.invalidateQueries({ queryKey: ['billing', 'prices'] })
      void qc.invalidateQueries({ queryKey: ['billing', 'price-lists'] })
    },
  })

  const readyRows = (rows ?? []).filter((row) => row.status === 'ready' && !row.error)
  const overlapCount = (rows ?? []).filter((row) => row.status === 'price_overlap' || row.error?.toLowerCase().includes('overlap')).length

  const toPayload = (source: ImportViewRow[]): PriceImportRow[] =>
    source
      .filter((row) => !row.error && row.unitPricePaise !== null)
      .map((row) => ({
        clientIndex: row.clientIndex,
        code: row.code,
        ...(row.name ? { name: row.name } : {}),
        category: row.category,
        sac: row.sac,
        unitPricePaise: row.unitPricePaise!,
        effectiveFrom: row.effectiveFrom,
        ...(row.effectiveTo ? { effectiveTo: row.effectiveTo } : {}),
        ...(row.branchId ? { branchId: row.branchId } : {}),
      }))

  const onFile = async (file: File | undefined) => {
    setFileError(null)
    apply.reset()
    if (!file) return
    const parsed = parsePriceCsv(await file.text())
    if (parsed.fileError) {
      setRows(null)
      setFileError(parsed.fileError)
      return
    }
    const view: ImportViewRow[] = parsed.rows.map((row, index) => {
      const branch = row.branchCode
        ? branches.find((item) => item.code.toLowerCase() === row.branchCode.toLowerCase())
        : undefined
      const branchError = row.branchCode && !branch ? `Unknown branch ${row.branchCode}.` : null
      return { ...row, clientIndex: index, branchId: branch?.id ?? '', error: row.error ?? branchError }
    })
    setRows(view)
    const payload = toPayload(view)
    if (payload.length === 0) return
    try {
      const result = await preview.mutateAsync({ dryRun: true, rows: payload })
      setRows((current) =>
        (current ?? view).map((row) => {
          const server = result.rows.find((item) => item.clientIndex === row.clientIndex)
          return server && !row.error ? { ...row, status: server.status, detail: server.detail } : row
        }),
      )
    } catch (error) {
      setFileError(problemText(error, 'Could not preview the file.'))
    }
  }

  const commit = async () => {
    if (!rows) return
    const payload = toPayload(rows.filter((row) => row.status === 'ready'))
    try {
      const result = await apply.mutateAsync({ dryRun: false, rows: payload })
      const written = result.rows.filter((row) => row.status === 'ready').length
      const skipped = rows.filter((row) => row.status === 'price_overlap' || row.error?.toLowerCase().includes('overlap')).length
      onMessage({
        tone: skipped ? 'error' : 'info',
        text: skipped
          ? `Imported ${written} ${written === 1 ? 'price' : 'prices'}. ${skipped} overlapping ${skipped === 1 ? 'period was' : 'periods were'} left unchanged.`
          : `Imported ${written} ${written === 1 ? 'price' : 'prices'}.`,
      })
      setRows(null)
    } catch (error) {
      onMessage({ tone: 'error', text: problemText(error, 'Could not import the prices.') })
    }
  }

  const downloadTemplate = () => {
    const url = URL.createObjectURL(new Blob([PRICE_CSV_TEMPLATE], { type: 'text/csv' }))
    const link = document.createElement('a')
    link.href = url
    link.download = 'price-list-template.csv'
    link.click()
    URL.revokeObjectURL(url)
  }

  return (
    <Card title="Import from CSV">
      <div className="space-y-4">
        <p className="text-sm text-gray-500 dark:text-dark-300">
          Preview the file before anything is saved. Rows that overlap an existing period are marked and are not imported. A blank branch code is the hospital rate.
        </p>
        <div className="flex flex-wrap gap-2">
          <Button type="button" variant="secondary" className="min-h-11" onClick={downloadTemplate}>
            Download template
          </Button>
        </div>
        <FormField label="CSV file" type="file" accept=".csv,text/csv" onChange={(event) => void onFile(event.target.files?.[0])} />
        {fileError && <Alert tone="error">{fileError}</Alert>}
        {overlapCount > 0 && <Alert tone="error">Some rows overlap an existing effective period and will not be imported.</Alert>}
        {rows && rows.length > 0 && (
          <ul className="divide-y divide-gray-200 dark:divide-dark-500" aria-label="Import preview">
            {rows.map((row) => (
              <li key={row.clientIndex} className="flex flex-wrap items-baseline justify-between gap-2 py-2 text-sm" data-testid="import-row">
                <span>
                  <span className="font-mono">{row.code || '—'}</span>
                  {row.name ? ` · ${row.name}` : ''}
                  <span className="mt-0.5 block text-xs text-gray-500">
                    {row.branchCode || 'Hospital'}
                    {row.unitPricePaise !== null ? ` · ${formatPaise(row.unitPricePaise)}` : ''}
                  </span>
                </span>
                <span>{row.error ?? row.detail ?? (row.status === 'ready' ? 'Ready' : preview.isPending ? 'Checking…' : 'Ready')}</span>
              </li>
            ))}
          </ul>
        )}
        <Button type="button" className="min-h-11" disabled={readyRows.length === 0 || apply.isPending || preview.isPending} onClick={() => void commit()}>
          Import {readyRows.length === 1 ? '1 ready price' : `${readyRows.length} ready prices`}
        </Button>
      </div>
    </Card>
  )
}
