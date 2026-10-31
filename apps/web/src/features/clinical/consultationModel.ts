import type { Consultation, FoodTiming, PrescriptionLine, SaveConsultationRequest } from '../../lib/api/types'

export const FOOD_LABEL: Record<FoodTiming, string> = { before_food: 'Before food', after_food: 'After food', with_food: 'With food', any: 'Any time' }

export type Draft = Omit<SaveConsultationRequest, 'rowVersion'>

export const emptyLine = (): PrescriptionLine => ({
  medicineName: '',
  strength: null,
  dose: null,
  frequency: '',
  durationDays: null,
  route: null,
  foodTiming: null,
  instructions: null,
})

export const toDraft = (c: Consultation): Draft => ({
  chiefComplaint: c.chiefComplaint,
  notes: c.notes,
  diagnosisText: c.diagnosisText,
  diagnosisCode: c.diagnosisCode,
  followUpDate: c.followUpDate,
  advice: c.advice,
  lines: c.lines.map((l) => ({ ...l, lineNo: undefined })),
})

/** Client-side checks that mirror the server (which stays the authority). Keys: `line-<i>-<field>`. */
export function validateLines(lines: PrescriptionLine[]): Record<string, string> {
  const errors: Record<string, string> = {}
  lines.forEach((l, i) => {
    if (!l.medicineName.trim()) errors[`line-${i}-medicineName`] = 'Medicine is required.'
    if (!l.frequency.trim()) errors[`line-${i}-frequency`] = 'Frequency is required.'
    if (l.durationDays !== null && (!Number.isInteger(l.durationDays) || l.durationDays < 1 || l.durationDays > 365))
      errors[`line-${i}-durationDays`] = 'Duration must be 1–365 days.'
  })
  return errors
}


/**
 * One-tap choices on the consultation screen. These are UI shortcuts only: every value stays editable in
 * the field next to it, and the server validates what is saved.
 */
export const FREQUENCY_CHOICES = ['1-0-1', '1-1-1', '1-0-0', '0-0-1', 'SOS'] as const
export const DURATION_CHOICES_DAYS = [3, 5, 7, 10] as const
export const FOLLOW_UP_CHOICES_DAYS = [3, 5, 7, 14] as const
