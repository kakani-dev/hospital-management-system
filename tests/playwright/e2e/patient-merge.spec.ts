import { expect, test, type APIRequestContext } from '@playwright/test'
import { bearer, ids, signIn, tokenFor, unique, users } from './helpers'

/**
 * #77 / REG-018 patient merge through the UI. API + SQL tests already cover the data rules; this proves the
 * screen: only an admin sees "Merge patient", the dialog demands a duplicate and a reason, a merge hides the
 * duplicate (404) and fills the survivor's blank fields from it. Fixtures are fresh Zz-E2E patients.
 */

async function newPatient(request: APIRequestContext, h: Record<string, string>, lastName: string, extra: Record<string, unknown> = {}) {
  const res = await request.post('/api/v1/patients', {
    headers: h,
    data: { firstName: 'Merge', lastName, registeredBranchId: ids.alphaMain, sex: 'female', ageYears: 52, noPhoneReason: 'test fixture', ...extra },
  })
  expect(res.ok()).toBeTruthy()
  return (await res.json()) as { id: string; mrn: string }
}

test('admin merges a duplicate chart from the patient screen; reception cannot', async ({ page, request }) => {
  const admin = bearer(await tokenFor(request, users.alphaAdmin))
  const tag = unique('Mrg')
  const survivor = await newPatient(request, admin, `Zz-E2E-Keep-${tag}`)
  const email = `${tag.toLowerCase()}@example.test`
  const duplicate = await newPatient(request, admin, `Zz-E2E-Dup-${tag}`, { email })

  // Reception sees the chart but no merge action.
  await signIn(page, users.alphaReception)
  await page.goto(`/patients/${survivor.id}`)
  await expect(page.getByRole('button', { name: 'Edit patient' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Merge patient' })).toHaveCount(0)
  await page.context().clearCookies()
  await page.evaluate(() => sessionStorage.clear())

  await signIn(page, users.alphaAdmin)
  await page.goto(`/patients/${survivor.id}`)
  await page.getByRole('button', { name: 'Merge patient' }).click()
  const dialog = page.getByRole('alertdialog')
  await expect(dialog).toContainText(survivor.mrn)

  // No duplicate chosen: refused, nothing merged.
  await dialog.getByRole('button', { name: 'Merge patient' }).click()
  await expect(page.getByText('Choose the duplicate chart to merge into this one.')).toBeVisible()

  await dialog.getByLabel('Duplicate chart').fill(`Zz-E2E-Dup-${tag}`)
  await page.getByTestId('patient-option').filter({ hasText: duplicate.mrn }).click()
  await expect(dialog.getByTestId('picked-patient')).toContainText(duplicate.mrn)

  // Duplicate chosen but no reason: refused.
  await dialog.getByRole('button', { name: 'Merge patient' }).click()
  await expect(page.getByText('A reason is required.')).toBeVisible()
  expect((await request.get(`/api/v1/patients/${duplicate.id}`, { headers: admin })).status()).toBe(200)

  await dialog.getByLabel('Reason').fill('Same person registered twice (e2e)')
  await dialog.getByRole('button', { name: 'Merge patient' }).click()
  await expect(page).toHaveURL(/\/patients$/)

  // Duplicate is hidden; survivor kept its id and picked up the blank email from the duplicate.
  expect((await request.get(`/api/v1/patients/${duplicate.id}`, { headers: admin })).status()).toBe(404)
  const kept = (await (await request.get(`/api/v1/patients/${survivor.id}`, { headers: admin })).json()) as { email: string | null; mrn: string }
  expect(kept.mrn).toBe(survivor.mrn)
  expect(kept.email).toBe(email)
  const search = (await (await request.get(`/api/v1/patients?q=${encodeURIComponent(`Zz-E2E-Dup-${tag}`)}`, { headers: admin })).json()) as { items: { id: string }[] }
  expect(search.items.map((p) => p.id)).not.toContain(duplicate.id)

  await page.goto(`/patients/${survivor.id}`)
  await expect(page.getByRole('main')).toContainText(email)
})
