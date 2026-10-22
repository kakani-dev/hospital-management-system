import { useCallback, useMemo, useState, type ReactNode } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { createContext, useContext } from 'react'
import { prefetchPatientWorkspace } from '../patients/prefetchPatient'

/** Enough to title the panel before the detail request returns. */
export interface PatientSeed {
  id: string
  mrn: string
  firstName: string
  lastName: string
}

export interface FollowUpIntent {
  practitionerId?: string | null
  parentAppointmentId?: string | null
}

export interface WorkspaceIntent {
  mode: 'overview' | 'book'
  followUp?: FollowUpIntent
}

interface Workspace {
  patient: PatientSeed | null
  intent: WorkspaceIntent
  openPatient: (patient: PatientSeed, intent?: Partial<WorkspaceIntent>) => void
  closePatient: () => void
  setIntent: (intent: WorkspaceIntent) => void
  /** Bumped to open the calendar's booking drawer without a navigation. */
  bookingTick: number
  requestBooking: () => void
  paletteOpen: boolean
  setPaletteOpen: (open: boolean) => void
}

const EMPTY_INTENT: WorkspaceIntent = { mode: 'overview' }

const fallback: Workspace = {
  patient: null,
  intent: EMPTY_INTENT,
  openPatient: () => {},
  closePatient: () => {},
  setIntent: () => {},
  bookingTick: 0,
  requestBooking: () => {},
  paletteOpen: false,
  setPaletteOpen: () => {},
}

const WorkspaceContext = createContext<Workspace | null>(null)

export function useWorkspace(): Workspace {
  return useContext(WorkspaceContext) ?? fallback
}

/** Patient panel, command palette and "book here" signal. Mounted once under the router. */
export function WorkspaceProvider({ children }: { children: ReactNode }) {
  const navigate = useNavigate()
  const location = useLocation()
  const [patient, setPatient] = useState<PatientSeed | null>(null)
  const [intent, setIntent] = useState<WorkspaceIntent>(EMPTY_INTENT)
  const [bookingTick, setBookingTick] = useState(0)
  const [paletteOpen, setPaletteOpen] = useState(false)

  const openPatient = useCallback((next: PatientSeed, partial?: Partial<WorkspaceIntent>) => {
    prefetchPatientWorkspace()
    setPatient(next)
    setIntent({ mode: partial?.mode ?? 'overview', followUp: partial?.followUp })
  }, [])

  const closePatient = useCallback(() => {
    setPatient(null)
    setIntent(EMPTY_INTENT)
  }, [])

  const requestBooking = useCallback(() => {
    if (location.pathname === '/appointments') setBookingTick((n) => n + 1)
    else navigate('/appointments', { state: { openBooking: true } })
  }, [location.pathname, navigate])

  const value = useMemo(
    () => ({ patient, intent, openPatient, closePatient, setIntent, bookingTick, requestBooking, paletteOpen, setPaletteOpen }),
    [patient, intent, openPatient, closePatient, bookingTick, requestBooking, paletteOpen],
  )

  return <WorkspaceContext.Provider value={value}>{children}</WorkspaceContext.Provider>
}
