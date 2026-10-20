import { expect, test } from '@playwright/test'
import { acceptInvitation, ADD_MEMBER_GENERIC_MESSAGE, createSyntheticUser, ids, pendingInvitations, signIn, unique, users } from './helpers'

test.describe('tenant admin', () => {
  test('creates and deactivates a branch; duplicate code is rejected', async ({ page }) => {
    const code = unique('br').toLowerCase()
    await signIn(page, users.alphaAdmin)
    await page.getByRole('link', { name: 'Branches' }).click()
    await expect(page.getByTestId('branch-row').filter({ hasText: 'Alpha Main Campus' })).toBeVisible()
    await expect(page.getByTestId('branch-row').filter({ hasText: 'Beta Central' })).toHaveCount(0)

    await page.getByLabel('Code').fill(code)
    await page.getByLabel('Branch name').fill(`E2E ${code}`)
    await page.getByRole('button', { name: 'Add branch' }).click()
    const row = page.getByTestId('branch-row').filter({ hasText: code })
    await expect(row).toContainText('Active')

    await page.getByRole('button', { name: `Deactivate E2E ${code}` }).click()
    await expect(row).toContainText('Inactive')

    await page.getByLabel('Code').fill(code)
    await page.getByLabel('Branch name').fill('Again')
    await page.getByRole('button', { name: 'Add branch' }).click()
    await expect(page.getByText('A branch with this code already exists')).toBeVisible()
  })

  test('invites a member with branch scope; same 202 answer for known and unknown email; listed only after accept; then suspended', async ({ page, request }) => {
    // PR #1 B1 contract: POST /api/v1/members always answers 202 with one generic message, and the
    // membership stays 'invited' (not listed to admins) until the invitee accepts it.
    const email = await createSyntheticUser('newnurse')
    await signIn(page, users.alphaAdmin)
    await page.getByRole('link', { name: 'Members' }).click()
    await expect(page.getByTestId('member-row').filter({ hasText: users.alphaReception })).toBeVisible()
    await expect(page.getByTestId('member-row').filter({ hasText: users.betaAdmin })).toHaveCount(0)

    // The page also has the "Create invite link" form (same labels): scope to "Add member".
    const add = page.getByRole('form', { name: 'Add member' })
    const addMember = async (address: string) => {
      const answered = page.waitForResponse((r) => r.url().endsWith('/api/v1/members') && r.request().method() === 'POST')
      await add.getByLabel('Email').fill(address)
      await add.getByRole('button', { name: 'Add member' }).click()
      const response = await answered
      expect(response.status()).toBe(202)
      expect(await response.json()).toEqual({ message: ADD_MEMBER_GENERIC_MESSAGE })
      await expect(page.getByText(ADD_MEMBER_GENERIC_MESSAGE)).toBeVisible()
    }

    // Known account, branch-scoped invite.
    await add.getByLabel('Role', { exact: true }).selectOption('nurse')
    await add.getByLabel('Branch scope').selectOption({ label: 'Alpha East Clinic' })
    await addMember(email)
    const row = page.getByTestId('member-row').filter({ hasText: email })
    await expect(row).toHaveCount(0) // pending invites are not listed to admins

    // Unknown email: exactly the same answer (no account enumeration).
    await addMember(`nobody-${unique('x')}@synthetic.example`)
    await expect(page.getByText('No user with this email has signed up yet')).toHaveCount(0)

    // Still not listed after a reload while pending.
    await page.reload()
    await expect(page.getByTestId('member-row').filter({ hasText: users.alphaReception })).toBeVisible()
    await expect(row).toHaveCount(0)

    // The invitee sees and accepts the invitation; only then is the member listed.
    expect((await pendingInvitations(request, email)).map((i) => i.tenantId)).toContain(ids.alpha)
    expect((await acceptInvitation(request, email, ids.alpha)).status()).toBe(204)
    await page.reload()
    await expect(row).toContainText('Alpha East Clinic')
    await expect(row).toContainText('active')
    await page.getByRole('button', { name: `Suspend ${email}` }).click()
    await expect(row).toContainText('suspended')
  })

  test('non-admin cannot open admin pages', async ({ page }) => {
    await signIn(page, users.betaDoctor)
    await page.goto('/admin/members')
    await expect(page.getByTestId('forbidden')).toContainText('does not include access')
  })
})
