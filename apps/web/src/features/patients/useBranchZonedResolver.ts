import { useEffect, useMemo, useRef } from 'react'
import { zodResolver } from '@hookform/resolvers/zod'
import type { FieldValues, Resolver } from 'react-hook-form'
import type { z } from 'zod'
import { latestToday, localToday } from '../../lib/dates'
import { useBranchTimeZones } from '../../lib/useBranchTimeZone'
import type { TimeZoneGetter } from './patientSchema'

/**
 * react-hook-form resolver whose "today" (DOB ≤ today) is evaluated in the time zone of the
 * branch chosen in the form (`registeredBranchId`) — the same zone the API validates in — rather
 * than the workstation's. While no zone is known only "not after the latest date anywhere" is checked.
 */
export function useBranchZonedResolver<T extends FieldValues & { registeredBranchId: string }>(
  makeSchema: (getTimeZone: TimeZoneGetter) => z.ZodType<T, T>,
): Resolver<T> {
  const { zoneFor } = useBranchTimeZones()
  const zoneForRef = useRef(zoneFor)
  useEffect(() => {
    zoneForRef.current = zoneFor
  })
  const makeRef = useRef(makeSchema)
  return useMemo<Resolver<T>>(
    () => (values, context, options) =>
      zodResolver(makeRef.current(() => zoneForRef.current(values.registeredBranchId)))(values, context, options),
    [],
  )
}

/** "Today" (YYYY-MM-DD) at a branch, for date inputs' `max`. */
export function useBranchToday(branchId: string | null | undefined): string {
  const { zoneFor } = useBranchTimeZones()
  const zone = zoneFor(branchId)
  return zone ? localToday(new Date(), zone) : latestToday()
}
