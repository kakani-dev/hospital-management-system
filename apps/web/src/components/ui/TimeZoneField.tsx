import { useId, useMemo, type ComponentProps } from 'react'
import { FormField } from './FormField'
import { ianaZones } from '../../lib/timeZones'

/**
 * FormField (Tailux Input) with the browser's IANA zone list as native suggestions (datalist).
 * Composition only: free text stays possible and the server is the validator.
 */
export function TimeZoneField(props: Omit<ComponentProps<typeof FormField>, 'list'>) {
  const listId = useId()
  const zones = useMemo(() => ianaZones(), [])
  return (
    <>
      <FormField list={listId} autoComplete="off" spellCheck={false} {...props} />
      <datalist id={listId}>
        {zones.map((z) => (
          <option key={z} value={z} />
        ))}
      </datalist>
    </>
  )
}
