import { expect, test } from '@playwright/test'
import { bearer, ids, signIn, tokenFor, unique, users } from './helpers'

/** Phase 2 screens through the edge: dashboard counts, practitioner and working-hours admin. */
test.describe('phase 2 admin screens', () => {
  test('dashboard "Registered today" counts a patient registered at the branch just now', async ({ page, request }) => {
    await signIn(page, users.alphaAdmin)
    await page.getByLabel('Showing branch').selectOption(ids.alphaMain)
    const stat = page.getByTestId('stat-registered')
    await expect(stat).toHaveText(/^\d+$/)
    const before = Number(await stat.textContent())

    const token = await tokenFor(request, users.alphaAdmin)
    const created = await request.post('/api/v1/patients', {
      headers: bearer(token),
      data: { mrn: unique('DS').toUpperCase(), firstName: 'Dash', lastName: `Zz-E2E-${unique('Stat')}`, registeredBranchId: ids.alphaMain, sex: 'unknown' },
    })
    expect(created.status()).toBe(201)

    await page.reload()
    await expect(stat).toHaveText(String(before + 1))
    await expect(page.getByTestId('stat-appointments')).toHaveText(/^\d+$/)
    await expect(page.getByTestId('stat-waiting')).toHaveText(/^\d+$/)
  })

  test('admin adds a practitioner and working hours, deletes and restores both', async ({ page, request }) => {
    const name = `Dr. ${unique('E2E')} (synthetic)`
    await signIn(page, users.alphaAdmin)
    await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Practitioners', exact: true }).click()
    await page.getByLabel('Display name').fill(name)
    await page.getByRole('button', { name: 'Add practitioner' }).click()
    await expect(page.getByText(`${name} added.`, { exact: false })).toBeVisible()

    await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Working hours', exact: true }).click()
    await page.getByLabel('Showing branch').selectOption(ids.alphaMain)
    const add = page.getByRole('form', { name: 'Add working hours' })
    await expect(add.getByRole('button', { name: 'Add hours' })).toBeEnabled()
    await add.getByLabel('Practitioner').selectOption({ label: name })
    await add.getByLabel('Weekday').selectOption('7')
    await add.getByLabel('Start time').fill('19:00')
    await add.getByLabel('End time').fill('20:00')
    await add.getByRole('button', { name: 'Add hours' }).click()
    const hours = `${name} on Sunday 19:00–20:00`
    await expect(page.getByText(`Added ${hours}.`)).toBeVisible()
    // Same hours again: 409 schedule_overlap from the scheduling service.
    await add.getByRole('button', { name: 'Add hours' }).click()
    await expect(page.getByText('These hours overlap another active schedule')).toBeVisible()

    await page.getByRole('button', { name: `Delete ${hours}` }).click()
    await page.getByRole('alertdialog').getByRole('button', { name: 'Delete' }).click()
    await expect(page.getByText(`Deleted ${hours}.`)).toBeVisible()
    await page.getByLabel('Show deleted').check()
    await page.getByRole('button', { name: `Restore ${hours}` }).click()
    await expect(page.getByText(`Restored ${hours}.`)).toBeVisible()

    await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Practitioners', exact: true }).click()
    await page.getByRole('button', { name: `Delete ${name}` }).click()
    await page.getByRole('alertdialog').getByRole('button', { name: 'Delete' }).click()
    await expect(page.getByText(`${name} was deleted.`, { exact: false })).toBeVisible()
    await page.getByLabel('Show deleted').check()
    const row = page.getByTestId('practitioner-row').filter({ hasText: name })
    await expect(row).toHaveAttribute('data-status', 'deleted')
    await page.getByRole('button', { name: `Restore ${name}` }).click()
    await expect(page.getByText(`${name} was restored as inactive.`, { exact: false })).toBeVisible()
    await expect(row).toHaveAttribute('data-status', 'inactive')
    await page.getByRole('button', { name: `Activate ${name}` }).click()
    await expect(row).toHaveAttribute('data-status', 'active')

    // Leave nothing bookable behind for the other specs.
    const token = await tokenFor(request, users.alphaAdmin)
    const all = (await (await request.get('/api/v1/practitioners?activeOnly=false', { headers: bearer(token) })).json()) as { id: string; displayName: string }[]
    const id = all.find((p) => p.displayName === name)!.id
    const schedules = (await (await request.get(`/api/v1/schedules?practitionerId=${id}`, { headers: bearer(token) })).json()) as { id: string }[]
    for (const s of schedules) expect((await request.delete(`/api/v1/schedules/${s.id}`, { headers: bearer(token) })).status()).toBe(204)
    expect((await request.delete(`/api/v1/practitioners/${id}`, { headers: bearer(token) })).status()).toBe(204)
  })

  test('hospital settings show the hospital zone from identity', async ({ page }) => {
    await signIn(page, users.alphaAdmin)
    await page.getByRole('navigation', { name: 'Primary' }).getByRole('link', { name: 'Hospital settings', exact: true }).click()
    await expect(page.getByLabel('Hospital time zone')).toHaveValue(/^[A-Za-z_]+\/[A-Za-z_]+/)
    await expect(page.getByLabel('Hospital name')).toHaveValue('Demo Alpha Hospital (synthetic)')
  })
})
