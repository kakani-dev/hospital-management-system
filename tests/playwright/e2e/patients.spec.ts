import { expect, test } from '@playwright/test'
import { bearer, searchPatients, signIn, tokenFor, unique, users } from './helpers'

test.describe('patient registration', () => {
  test('receptionist registers a patient (MRN generated, WhatsApp same as phone); other tenant cannot see it', async ({ page, browser }) => {
    const lastName = `Synthetic-E2E-${unique('P').slice(2)}`
    const digits = String(Date.now()).slice(-5)
    await signIn(page, users.alphaReception)
    await page.getByRole('link', { name: 'Patients' }).click()
    await page.getByRole('link', { name: 'Register patient' }).click()

    await expect(page.getByLabel('MRN')).toHaveCount(0) // server-generated, never typed
    await page.getByLabel('First name').fill('Playwright')
    await page.getByLabel('Last name').fill(lastName)
    await page.getByLabel('Date of birth').fill('1991-02-03')
    await page.getByLabel('Sex').selectOption('female')
    await page.getByLabel('Phone (optional)').fill(`98451 ${digits}`)
    await expect(page.getByRole('checkbox', { name: 'Same as phone number' })).toBeChecked()
    await expect(page.getByLabel('Registered branch')).toHaveValue('a1111111-0000-4000-8000-000000000001')
    const createdResponse = page.waitForResponse((r) => r.url().endsWith('/api/v1/patients') && r.request().method() === 'POST')
    await page.getByRole('button', { name: 'Register patient' }).click()

    const created = (await (await createdResponse).json()) as { id: string; mrn: string; phones: { number: string; isPrimary: boolean; isWhatsapp: boolean }[]; whatsappSameAsPhone: boolean }
    expect(created.mrn).toMatch(/^DEMO-ALPHA-\d{6}$/)
    expect(created.phones).toEqual([{ number: `+9198451${digits}`, isPrimary: true, isWhatsapp: true }])
    expect(created.whatsappSameAsPhone).toBe(true)
    const mrn = created.mrn
    await expect(page.getByText(`Patient registered. MRN ${mrn}`)).toBeVisible() // toast
    await expect(page.getByText(`Patient ${mrn} registered.`)).toBeVisible()
    // Search goes in a POST body (review Minor 5): the MRN must never appear in a request URL.
    const urlsWithTerm: string[] = []
    page.on('request', (r) => {
      if (r.url().includes(mrn)) urlsWithTerm.push(r.url())
    })
    const searched = page.waitForResponse((r) => r.url().endsWith('/api/v1/patients/search') && r.request().method() === 'POST')
    await page.getByLabel('Search patients').fill(mrn)
    expect((await searched).status()).toBe(200)
    await expect(page.getByTestId('patient-row').filter({ hasText: mrn })).toBeVisible()
    expect(urlsWithTerm).toEqual([])

    // Detail: WhatsApp badge on the phone; the MRN is read-only on edit.
    await page.goto(`/patients/${created.id}`)
    await expect(page.getByTestId('whatsapp-same-badge')).toBeVisible()
    await page.getByRole('button', { name: 'Edit patient' }).click()
    const form = page.getByRole('form', { name: 'Edit patient' })
    await expect(form.getByTestId('edit-mrn')).toContainText(mrn)
    await form.getByRole('checkbox', { name: 'Same as phone number' }).uncheck()
    await form.getByLabel('WhatsApp number').fill('+971 50 123 4567')
    await form.getByRole('button', { name: 'Save changes' }).click()
    await expect(page.getByText('Changes saved.')).toBeVisible()
    await expect(page.getByTestId('patient-whatsapp')).toContainText('+971501234567')

    // Beta admin (separate browser context) cannot find it.
    const other = await browser.newContext()
    const betaPage = await other.newPage()
    await signIn(betaPage, users.betaAdmin)
    await betaPage.goto('/patients')
    await betaPage.getByLabel('Search patients').fill(mrn)
    await expect(betaPage.getByTestId('patients-empty')).toBeVisible()
    await other.close()
  })

  test('API: a client MRN is ignored on create and refused on update; WhatsApp numbers are E.164', async ({ request }) => {
    const token = await tokenFor(request, users.alphaReception)
    const response = await request.post('/api/v1/patients', {
      headers: bearer(token),
      data: { mrn: 'CLIENT-0001', firstName: 'Mrn', lastName: `Synthetic-E2E-${unique('M').slice(2)}`, registeredBranchId: 'a1111111-0000-4000-8000-000000000001', phone: '098452 00011', whatsapp: { sameAsPhone: false, number: '0091 98452 00012' } },
    })
    expect(response.status()).toBe(201)
    const created = (await response.json()) as { id: string; mrn: string; phones: { number: string; isPrimary: boolean; isWhatsapp: boolean }[]; whatsappSameAsPhone: boolean }
    expect(created.mrn).toMatch(/^DEMO-ALPHA-\d{6}$/)
    expect(created.phones).toEqual(
      expect.arrayContaining([
        { number: '+919845200011', isPrimary: true, isWhatsapp: false },
        { number: '+919845200012', isPrimary: false, isWhatsapp: true },
      ]),
    )
    expect(created.whatsappSameAsPhone).toBe(false)
    const patch = await request.patch(`/api/v1/patients/${created.id}`, { headers: bearer(token), data: { mrn: 'DEMO-ALPHA-999999' } })
    expect(patch.status()).toBe(400)
    const bad = await request.post('/api/v1/patients', {
      headers: bearer(token),
      data: { firstName: 'Bad', lastName: 'Synthetic-E2E', registeredBranchId: 'a1111111-0000-4000-8000-000000000001', phone: '98452 00013', whatsapp: { sameAsPhone: false, number: '12' } },
    })
    expect(bad.status()).toBe(400)
    expect(((await bad.json()) as { errors: Record<string, string[]> }).errors).toHaveProperty('whatsapp')
  })

  test('GET ?search= is refused; POST /api/v1/patients/search is tenant-scoped', async ({ request }) => {
    const token = await tokenFor(request, users.alphaReception)
    expect((await request.get('/api/v1/patients?search=ALP', { headers: bearer(token) })).status()).toBe(400)
    const response = await searchPatients(request, token, 'synthetic', 100)
    expect(response.status()).toBe(200)
    const body = (await response.json()) as { items: { lastName: string }[] }
    expect(body.items.some((p) => p.lastName === 'Synthetic-Alpha')).toBe(true)
    expect(body.items.some((p) => p.lastName === 'Synthetic-Beta')).toBe(false)
  })

  test('client-side validation blocks bad input', async ({ page }) => {
    await signIn(page, users.alphaAdmin)
    await page.goto('/patients/new')
    await page.getByLabel('Phone (optional)').fill('call me')
    await page.getByRole('button', { name: 'Register patient' }).click()
    await expect(page.getByText(/Enter a valid phone number/)).toBeVisible()
    await expect(page.getByText('First name is required')).toBeVisible()
  })

  test('lab technician cannot read the patient registry', async ({ page }) => {
    await signIn(page, users.alphaLab)
    await page.goto('/patients')
    await expect(page.getByText('does not include access to the patient registry')).toBeVisible()
    await expect(page.getByRole('link', { name: 'Register patient' })).toHaveCount(0)
  })
})
