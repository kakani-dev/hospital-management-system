import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { TimeZoneField } from './TimeZoneField'
import { DEFAULT_ZONE, FALLBACK_ZONES, defaultZone, filterZones, ianaZones, matchZone, resetZoneCache, zoneOffsetLabel } from '../../lib/timeZones'
import { restoreWorkstation, workstationAt } from '../../test/timeZones'

function Harness({ initial = 'Asia/Kolkata', onChange = () => {} }: { initial?: string; onChange?: (z: string) => void }) {
  const [zone, setZone] = useState(initial)
  return (
    <>
      <TimeZoneField
        label="Hospital time zone"
        hint="Pick a zone"
        value={zone}
        onChange={(z) => {
          setZone(z)
          onChange(z)
        }}
      />
      <input aria-label="Next field" />
    </>
  )
}

afterEach(() => {
  restoreWorkstation()
  vi.unstubAllGlobals()
  resetZoneCache()
})

describe('TimeZoneField (searchable IANA picker)', () => {
  it('is a labelled combobox that lists every zone from Intl.supportedValuesOf, with UTC offsets', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    const box = screen.getByRole('combobox', { name: 'Hospital time zone' })
    expect(box).toHaveValue('Asia/Kolkata')
    expect(box).toHaveAccessibleDescription('Pick a zone')
    expect(document.querySelector('datalist')).toBeNull()
    await user.click(box)
    const options = await screen.findAllByRole('option')
    expect(options.length).toBe(ianaZones().length)
    expect(options.length).toBeGreaterThan(300)
    expect(screen.getByRole('option', { name: /^Asia\/Kolkata\s*UTC\+05:30$/, selected: true })).toBeInTheDocument()
  })

  it('opens from the chevron button (touch) and selects a tapped option', async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<Harness onChange={onChange} />)
    await user.click(screen.getByRole('button', { name: 'Show list' }))
    expect((await screen.findAllByRole('option')).length).toBe(ianaZones().length)
    const dubai = screen.getByRole('option', { name: /^Asia\/Dubai/ })
    await user.click(dubai)
    expect(onChange).toHaveBeenCalledWith('Asia/Dubai')
    expect(screen.getByRole('combobox')).toHaveValue('Asia/Dubai')
    expect(screen.queryByRole('option')).not.toBeInTheDocument()
  })

  it('searches by city, by spaces for underscores and by offset', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    const box = screen.getByRole('combobox')
    await user.type(box, 'new york')
    expect(screen.getAllByRole('option').map((o) => o.textContent)).toEqual([expect.stringMatching(/^America\/New_York/)])
    await user.clear(box)
    await user.type(box, '+05:45')
    expect(screen.getAllByRole('option').map((o) => o.textContent)).toEqual([expect.stringMatching(/^Asia\/Kathmandu/)])
  })

  it('keyboard: arrow + Enter selects; typing the exact id and leaving selects it; other text reverts', async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<Harness onChange={onChange} />)
    const box = screen.getByRole('combobox')
    await user.type(box, 'Asia/Tok')
    await user.keyboard('{ArrowDown}{Enter}')
    expect(box).toHaveValue('Asia/Tokyo')
    await user.click(screen.getByLabelText('Next field'))
    await user.type(box, 'europe/london')
    await user.click(screen.getByLabelText('Next field'))
    expect(box).toHaveValue('Europe/London')
    await user.type(box, 'Mars/Olympus')
    expect(screen.getByText('No time zone matches “Mars/Olympus”.')).toBeInTheDocument()
    await user.click(screen.getByLabelText('Next field'))
    expect(box).toHaveValue('Europe/London')
    expect(onChange.mock.calls.map((c) => c[0])).toEqual(['Asia/Tokyo', 'Europe/London'])
  })

  it('shows the error with role=alert and marks the input invalid', () => {
    render(<TimeZoneField label="Time zone" value="" onChange={() => {}} error="Choose the hospital time zone" />)
    expect(screen.getByRole('combobox', { name: 'Time zone' })).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Choose the hospital time zone')
  })
})

describe('time zone list and default', () => {
  it('falls back to a static list when Intl.supportedValuesOf is missing or empty', () => {
    vi.stubGlobal('Intl', { ...Intl, supportedValuesOf: undefined })
    resetZoneCache()
    expect(ianaZones()).toEqual([...new Set(FALLBACK_ZONES)].sort())
    expect(ianaZones()).toContain('Asia/Kolkata')
    vi.stubGlobal('Intl', { ...Intl, supportedValuesOf: () => [] })
    resetZoneCache()
    expect(ianaZones()).toContain('America/New_York')
  })

  it('canonicalises legacy ids and always offers UTC', () => {
    vi.stubGlobal('Intl', { ...Intl, supportedValuesOf: () => ['Asia/Calcutta', 'Europe/Kiev', 'Asia/Saigon'] })
    resetZoneCache()
    expect(ianaZones()).toEqual(['Asia/Ho_Chi_Minh', 'Asia/Kolkata', 'Europe/Kiev', 'UTC'])
  })

  it('defaults to the browser zone when it is listed, else Asia/Kolkata', () => {
    workstationAt('America/New_York')
    expect(defaultZone()).toBe('America/New_York')
    workstationAt('Asia/Calcutta')
    expect(defaultZone()).toBe('Asia/Kolkata')
    expect(defaultZone(['Europe/London', 'UTC'])).toBe(DEFAULT_ZONE)
  })

  it('matches exact ids loosely and filters by id or offset', () => {
    expect(matchZone(' asia/kolkata ')).toBe('Asia/Kolkata')
    expect(matchZone('America/New York')).toBe('America/New_York')
    expect(matchZone('Asia/Calcutta')).toBe('Asia/Kolkata')
    expect(matchZone('Mars/Olympus')).toBeNull()
    expect(matchZone('')).toBeNull()
    expect(filterZones('', ['A/B', 'C/D'])).toEqual(['A/B', 'C/D'])
    expect(filterZones('utc+04', ['Asia/Dubai', 'Asia/Kolkata'], new Map([['Asia/Dubai', 'UTC+04:00'], ['Asia/Kolkata', 'UTC+05:30']]))).toEqual(['Asia/Dubai'])
    expect(zoneOffsetLabel('Asia/Kolkata')).toBe('UTC+05:30')
    expect(zoneOffsetLabel('UTC')).toBe('UTC+00:00')
    expect(zoneOffsetLabel('America/New_York', new Date('2026-01-15T12:00:00Z'))).toBe('UTC-05:00')
    expect(zoneOffsetLabel('Not/AZone')).toBe('')
  })
})
