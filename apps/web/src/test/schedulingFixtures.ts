import { ALPHA_MAIN, ALPHA_EAST } from './fakes'
import { localToday, zonedTimeToInstant } from '../lib/dates'
import type { Appointment, Practitioner, Schedule } from '../lib/api/types'

export const TZ = 'Asia/Kolkata'
export const today = () => localToday(new Date(), TZ)
export const at = (date: string, time: string) => zonedTimeToInstant(date, time, TZ)

export const DR_RAO = 'd0000000-0000-4000-8000-000000000001'
export const DR_IYER = 'd0000000-0000-4000-8000-000000000002'
export const PATIENT_ID = 'aa000000-0000-4000-8000-000000000001'

export const branchesResponse = [
  { id: ALPHA_MAIN, code: 'main', name: 'Alpha Main', timezone: TZ, isActive: true },
  { id: ALPHA_EAST, code: 'east', name: 'Alpha East', timezone: TZ, isActive: true },
]

export const practitioners: Practitioner[] = [
  { id: DR_RAO, userId: null, displayName: 'Dr. Rao (synthetic)', specialty: 'General medicine', isActive: true },
  { id: DR_IYER, userId: null, displayName: 'Dr. Iyer (synthetic)', specialty: 'Paediatrics', isActive: true },
]

/** Dr. Rao works every weekday morning at Alpha Main; Dr. Iyer Saturdays at Alpha East. */
export const schedules: Schedule[] = [
  ...[1, 2, 3, 4, 5].map((weekday) => ({
    id: `s-rao-${weekday}`,
    practitionerId: DR_RAO,
    branchId: ALPHA_MAIN,
    weekday,
    startTime: '09:00',
    endTime: '13:00',
    slotMinutes: 15,
    validFrom: '2026-01-01',
    validTo: null,
    isActive: true,
  })),
  {
    id: 's-iyer-6',
    practitionerId: DR_IYER,
    branchId: ALPHA_EAST,
    weekday: 6,
    startTime: '10:00',
    endTime: '12:00',
    slotMinutes: 20,
    validFrom: '2026-01-01',
    validTo: null,
    isActive: true,
  },
]

export const patientDetail = {
  id: PATIENT_ID,
  mrn: 'ALP-0001',
  firstName: 'Asha',
  lastName: 'Synthetic-Alpha',
  dateOfBirth: '1990-01-01',
  sex: 'female',
  registeredBranchId: ALPHA_MAIN,
  phone: null,
  email: null,
  deletedAt: null,
}

export function appointment(overrides: Partial<Appointment> = {}): Appointment {
  const d = today()
  return {
    id: 'ap000000-0000-4000-8000-000000000001',
    branchId: ALPHA_MAIN,
    practitionerId: DR_RAO,
    patientId: PATIENT_ID,
    startsAt: at(d, '09:30'),
    endsAt: at(d, '09:45'),
    status: 'booked',
    reason: null,
    ...overrides,
  }
}

export const paged = <T,>(items: T[]) => ({ items, page: 1, pageSize: 100, totalCount: items.length })
