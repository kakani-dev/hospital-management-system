import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { PaymentAccountsSection } from './PaymentAccountsSection'
import { ALPHA_MAIN, fakeAuthClient, fakeSession, json, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const upi = { id: 'u1', branchId: ALPHA_MAIN, mode: 'upi', label: 'Front desk', vpa: 'alpha.main@okaxis', isDefault: true, isActive: true }
const bank = { id: 'b1', branchId: ALPHA_MAIN, mode: 'bank', label: 'Current', bankName: 'Synthetic Bank', maskedAccount: 'XXXX9012', ifsc: 'SBIN0001234', isDefault: true, isActive: true }

const open = () => renderWithProviders(<PaymentAccountsSection branchId={ALPHA_MAIN} />, { auth: fakeAuthClient({ session: fakeSession() }) })

describe('Payment accounts section', () => {
  it('says UPI QR is off when the branch has no account', async () => {
    stubFetch({ 'GET /api/v1/payment-accounts': () => json([]) })
    open()
    expect(await screen.findByText(/UPI QR codes stay off/)).toBeInTheDocument()
  })

  it('lists masked accounts and adds a bank account without keeping the full number on screen', async () => {
    let list: unknown[] = [upi]
    const calls = stubFetch({
      'GET /api/v1/payment-accounts': () => json(list),
      'POST /api/v1/payment-accounts': () => { list = [upi, bank]; return json(bank) },
    })
    const user = userEvent.setup()
    open()
    expect(await screen.findByText('alpha.main@okaxis')).toBeInTheDocument()
    await user.selectOptions(screen.getByLabelText('Type'), 'bank')
    await user.type(screen.getByLabelText('Account label'), 'Current')
    await user.type(screen.getByLabelText('Bank'), 'Synthetic Bank')
    await user.type(screen.getByLabelText('Account number'), '123456789012')
    await user.type(screen.getByLabelText('IFSC'), 'SBIN0001234')
    await user.click(screen.getByRole('button', { name: 'Add account' }))
    expect(await screen.findByText(/XXXX9012/)).toBeInTheDocument()
    expect(calls.find((c) => c.method === 'POST')!.body).toMatchObject({ branchId: ALPHA_MAIN, mode: 'bank', ifsc: 'SBIN0001234' })
    expect(screen.queryByText(/123456789012/)).not.toBeInTheDocument()
    expect(screen.getByLabelText('Account number')).toHaveValue('')
  })

  it('shows the server error for an invalid VPA', async () => {
    stubFetch({
      'GET /api/v1/payment-accounts': () => json([]),
      'POST /api/v1/payment-accounts': () => json({ title: 'Enter a valid UPI ID', status: 400 }, 400),
    })
    const user = userEvent.setup()
    open()
    await user.type(await screen.findByLabelText('Account label'), 'x')
    await user.type(screen.getByLabelText('UPI ID'), 'not-a-vpa')
    await user.click(screen.getByRole('button', { name: 'Add account' }))
    expect(await screen.findByRole('alert')).toBeInTheDocument()
  })

  it('makes an account default and deactivates another', async () => {
    const second = { ...upi, id: 'u2', label: 'Pharmacy', vpa: 'alpha.pharm@okicici', isDefault: false }
    const calls = stubFetch({
      'GET /api/v1/payment-accounts': () => json([upi, second]),
      'PUT /api/v1/payment-accounts/u2': () => json({ ...second, isDefault: true }),
      'PUT /api/v1/payment-accounts/u1': () => json({ ...upi, isActive: false, isDefault: false }),
    })
    const user = userEvent.setup()
    open()
    const rows = await screen.findAllByTestId('payment-account')
    await user.click(within(rows[1]!).getByRole('button', { name: 'Make default' }))
    await user.click(within(rows[0]!).getByRole('button', { name: 'Deactivate' }))
    const puts = calls.filter((c) => c.method === 'PUT')
    expect(puts.map((c) => [c.path, c.body])).toEqual([
      ['/api/v1/payment-accounts/u2', { isDefault: true }],
      ['/api/v1/payment-accounts/u1', { isActive: false }],
    ])
  })
})
