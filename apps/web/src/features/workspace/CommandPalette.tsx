import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { Dialog, DialogPanel, DialogTitle } from '@headlessui/react'
import { useNavigate } from 'react-router'
import { Input } from '@tailux/components/ui'
import { PATIENT_SEARCH_DEBOUNCE_MS, PATIENT_SEARCH_MAX_LENGTH, usePatients } from '../../lib/api/hooks'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import type { Capability } from '../../lib/permissions'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { PATIENT_PICKER_MIN_CHARS } from '../patients/patientLabel'
import { prefetchPatientRecord } from '../patients/prefetchPatient'
import { useQueryClient } from '@tanstack/react-query'
import { useWorkspace, type PatientSeed } from './WorkspaceProvider'

interface Action {
  id: string
  label: string
  hint: string
  capability?: Capability
  /** Platform operators only (no hospital capability). */
  platform?: boolean
  run: 'book' | 'navigate' | 'bill'
  path?: string
  state?: object
}

const ACTIONS: Action[] = [
  { id: 'book', label: 'Book appointment', hint: 'Open the booking drawer', capability: 'appointments.book', run: 'book' },
  { id: 'op-consult', label: 'OP consult bill', hint: 'Consultation on the open patient', capability: 'billing.bill', run: 'bill' },
  { id: 'check-in', label: 'Reception check-in', hint: 'Today’s appointments', capability: 'queue.checkIn', run: 'navigate', path: '/reception/check-in' },
  { id: 'queue', label: 'OPD queue', hint: 'Today’s tokens', capability: 'queue.view', run: 'navigate', path: '/queue' },
  { id: 'patients', label: 'Patients', hint: 'Search the registry', capability: 'patients.view', run: 'navigate', path: '/patients' },
  { id: 'desk', label: 'Invite staff and branches', hint: 'Hospital desk', capability: 'admin.members', run: 'navigate', path: '/admin/desk' },
  { id: 'price-list', label: 'Price list', hint: 'Services and rates', capability: 'admin.pricelist', run: 'navigate', path: '/admin/price-list' },
  { id: 'stock', label: 'Stock', hint: 'Items, stores, and quantities on hand', capability: 'stock.view', run: 'navigate', path: '/stock' },
  { id: 'consent', label: 'Consent', hint: 'What this person has allowed', capability: 'privacy.view', run: 'navigate', path: '/privacy' },
  { id: 'data-requests', label: 'Data requests', hint: 'Access, correction, and erasure', capability: 'privacy.desk', run: 'navigate', path: '/compliance/requests' },
  { id: 'privacy-notices', label: 'Privacy notices', hint: 'Draft and publish the notice', capability: 'privacy.notice', run: 'navigate', path: '/admin/privacy-notices' },
  { id: 'create-hospital', label: 'Create hospital', hint: 'Platform: hospital and first admin invite', platform: true, run: 'navigate', path: '/platform', state: { openCreate: true } },
]

/**
 * Ctrl+K command palette (Headless UI Dialog, the same shell as ShortcutHelp). Type a patient
 * (the existing search) or an action. Choosing a patient opens the context panel on the current
 * page; actions that are already on screen stay there.
 */
export function CommandPalette({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { has, me } = useCurrentContext()
  const { openPatient, requestBooking, patient, setIntent } = useWorkspace()
  const [term, setTerm] = useState('')
  const [active, setActive] = useState(0)
  const [activeFor, setActiveFor] = useState(term)
  if (term !== activeFor) {
    setActiveFor(term)
    setActive(0)
  }
  const inputRef = useRef<HTMLInputElement>(null)
  useEffect(() => {
    inputRef.current?.focus()
  }, [])
  const debounced = useDebouncedValue(term, PATIENT_SEARCH_DEBOUNCE_MS)
  const listId = useId()
  const searching = debounced.trim().length >= PATIENT_PICKER_MIN_CHARS
  const results = usePatients(debounced, { enabled: searching && has('patients.view') })
  const patients = searching && debounced === term ? (results.data?.items ?? []) : []
  const needle = term.trim().toLowerCase()
  const actions = useMemo(
    () =>
      ACTIONS.filter((a) => {
        if (a.platform) return me.data?.isPlatformAdmin === true
        if (a.capability && !has(a.capability)) return false
        // Hospital desk needs both admin capabilities; members-only staff keep the members page.
        if (a.id === 'desk' && !has('admin.branches')) return false
        return !needle || a.label.toLowerCase().includes(needle)
      }),
    // `has` derives from me.data.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [me.data, needle],
  )
  const options = [
    ...patients.map((p) => ({ kind: 'patient' as const, id: p.id, patient: p })),
    ...actions.map((a) => ({ kind: 'action' as const, id: a.id, action: a })),
  ]

  const choose = (index: number) => {
    const option = options[index]
    if (!option) return
    if (option.kind === 'patient') {
      const seed: PatientSeed = { id: option.patient.id, mrn: option.patient.mrn, firstName: option.patient.firstName, lastName: option.patient.lastName }
      openPatient(seed)
      onClose()
      return
    }
    onClose()
    if (option.action.run === 'book') requestBooking()
    else if (option.action.run === 'bill') {
      if (patient) setIntent({ mode: 'bill' })
      else navigate('/patients')
    } else if (option.action.path) navigate(option.action.path, option.action.state ? { state: option.action.state } : undefined)
  }

  return (
    <Dialog open onClose={onClose} className="fixed inset-0 z-200 flex items-start justify-center px-4 pt-[12vh]">
      <div aria-hidden="true" className="absolute inset-0 bg-gray-900/50 dark:bg-black/40" />
      <DialogPanel
        data-testid="command-palette"
        className="relative w-full max-w-lg rounded-lg bg-white text-gray-700 shadow-lg dark:bg-dark-700 dark:text-dark-200"
      >
        <DialogTitle className="sr-only">Search patients and actions</DialogTitle>
        <div className="border-b border-gray-200 p-3 dark:border-dark-500">
          <Input
            label="Search"
            classNames={{ label: 'sr-only' }}
            data-testid="command-palette-input"
            ref={inputRef}
            role="combobox"
            aria-expanded
            aria-controls={listId}
            aria-autocomplete="list"
            aria-activedescendant={options[active] ? `${listId}-opt-${active}` : undefined}
            type="search"
            placeholder="Patient, or an action…"
            maxLength={PATIENT_SEARCH_MAX_LENGTH}
            value={term}
            autoComplete="off"
            onChange={(e) => setTerm(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault()
                setActive((i) => Math.min(i + 1, Math.max(options.length - 1, 0)))
              } else if (e.key === 'ArrowUp') {
                e.preventDefault()
                setActive((i) => Math.max(i - 1, 0))
              } else if (e.key === 'Enter' && options.length) {
                e.preventDefault()
                choose(active)
              }
            }}
          />
        </div>
        <ul id={listId} role="listbox" aria-label="Search results" className="max-h-80 overflow-y-auto py-1">
          {searching && results.isPending && (
            <li className="px-4 py-2 text-sm text-gray-500" role="status">
              Searching…
            </li>
          )}
          {options.length === 0 && !results.isPending && <li className="px-4 py-3 text-sm text-gray-500">No matches.</li>}
          {options.map((option, i) => (
            <li
              key={`${option.kind}-${option.id}`}
              id={`${listId}-opt-${i}`}
              role="option"
              aria-selected={i === active}
              data-testid={option.kind === 'patient' ? 'command-patient' : 'command-action'}
              className={`cursor-pointer px-4 py-2 text-sm ${i === active ? 'bg-primary-600 text-white' : 'hover:bg-gray-100 dark:hover:bg-dark-600'}`}
              onMouseEnter={() => {
                setActive(i)
                if (option.kind === 'patient') prefetchPatientRecord(qc, option.patient.id)
              }}
              onMouseDown={(e) => e.preventDefault()}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault()
                  choose(i)
                }
              }}
              onClick={() => choose(i)}
            >
              {option.kind === 'patient' ? (
                <>
                  <span className="font-medium">
                    {option.patient.lastName}, {option.patient.firstName}
                  </span>{' '}
                  <span className="font-mono text-xs opacity-80">{option.patient.mrn}</span>
                </>
              ) : (
                <>
                  <span className="font-medium">{option.action.label}</span>
                  <span className="ml-2 text-xs opacity-80">{option.action.hint}</span>
                </>
              )}
            </li>
          ))}
        </ul>
        <p className="border-t border-gray-200 px-4 py-2 text-xs text-gray-500 dark:border-dark-500">
          <kbd className="font-mono">Ctrl+K</kbd> opens this. ↑↓ move, Enter chooses, Esc closes. Patients open here — the page stays.
        </p>
      </DialogPanel>
    </Dialog>
  )
}
