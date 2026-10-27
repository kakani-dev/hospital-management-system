# Payments test cases

Source of truth is shared with the Notion database [Test Cases](https://app.notion.com/p/331448b2168c43b99eeeb3a657626e6d); IDs match. Status lives in Notion.

## PAY-001

[Notion case](https://app.notion.com/p/404ead9eb8a881e0ab24d7c2f9a3170a)

**Collect cash in open counter session** · P0 · happy · Role: billing

- Preconditions: Open counter session
- Steps: Collect cash payment
- Test data: ₹500
- Expected: Receipt issued; bill paid
- Rule / code: `billing_open_bill_payments.sql`

## PAY-002

[Notion case](https://app.notion.com/p/404ead9eb8a881a99fe1c578e975184d)

**Cash without open session blocked** · P0 · negative · Role: billing

- Preconditions: No session
- Steps: Collect cash
- Test data: —
- Expected: "cash taken at a counter needs an open session"
- Rule / code: `billing_commands.sql`

## PAY-003

[Notion case](https://app.notion.com/p/404ead9eb8a88103b365d0bf205b0201)

**Card / UPI / bank / credit payment** · P0 · happy · Role: billing

- Preconditions: Draft or finalized bill
- Steps: Pay with each mode
- Test data: —
- Expected: Accepted; tender modes cash, card, upi, bank, credit only
- Rule / code: `billing_op_v1.sql payment_tender_mode`

## PAY-004

[Notion case](https://app.notion.com/p/404ead9eb8a88154a5c3f032dc056e11)

**Split tender** · P1 · edge · Role: billing

- Preconditions: Bill ₹1000
- Steps: ₹600 cash + ₹400 UPI
- Test data: —
- Expected: Allocations add to payment
- Rule / code: `billing_commands.sql ("allocations must add up to the payment")`

## PAY-005

[Notion case](https://app.notion.com/p/404ead9eb8a88156afc1c5c17b2c6b1a)

**Overpay blocked** · P1 · negative · Role: billing

- Preconditions: Due ₹500
- Steps: Pay ₹600 allocated
- Test data: —
- Expected: 400 "allocations exceed the bill total: ₹500.00 is due" (#143: was a 500)
- Rule / code: `20261027100200_billing_payment_overpay_4xx.sql`, `supabase/tests/50_payment_overpay_test.sql`

## PAY-006

[Notion case](https://app.notion.com/p/404ead9eb8a8811fb38eee7ee1a3438a)

**Nothing due** · P2 · negative · Role: billing

- Preconditions: Fully paid
- Steps: Pay again
- Test data: —
- Expected: 400 "nothing is due on this bill" (#143: was a 500)
- Rule / code: `20261027100200_billing_payment_overpay_4xx.sql`, `supabase/tests/50_payment_overpay_test.sql`

## PAY-007

[Notion case](https://app.notion.com/p/404ead9eb8a8810798b2fd275381bffd)

**Cash daily limit ₹2,00,000 per patient (s.269ST)** · P0 · edge · Role: billing

- Preconditions: Patient paid ₹1,99,999 cash today
- Steps: Pay ₹1 cash
- Test data: —
- Expected: Refused "cash would reach the ₹2,00,000 daily limit"; card allowed
- Rule / code: `billing_commands.sql:381-407`

## PAY-008

[Notion case](https://app.notion.com/p/404ead9eb8a881319e15f2109d08fb37)

**Idempotency on double-submit** · P0 · concurrency · Role: billing

- Preconditions: —
- Steps: Double-click Pay
- Test data: —
- Expected: One payment; reuse with different amount -> "idempotency key reused with a different amount"
- Rule / code: `billing_commands.sql`

## PAY-009

[Notion case](https://app.notion.com/p/404ead9eb8a88105a801de6faadc3bcc)

**Payments immutable** · P1 · data-integrity · Role: tenant_admin

- Preconditions: Payment
- Steps: Edit via API
- Test data: —
- Expected: "payments, tenders and allocations are immutable; refund or reverse them"
- Rule / code: `billing_op_v1.sql`

## PAY-010

[Notion case](https://app.notion.com/p/404ead9eb8a8812c8d53c6216310fb47)

**Counter session belongs to cashier and branch** · P1 · security · Role: billing

- Preconditions: Cashier A session
- Steps: Cashier B uses it; use at other branch
- Test data: —
- Expected: "counter session belongs to another cashier"; "counter session is for another branch"
- Rule / code: `billing_commands.sql`

## PAY-011

[Notion case](https://app.notion.com/p/404ead9eb8a88114911feb0cf858d092)

**Payment link channels** · P2 · happy · Role: billing

- Preconditions: Bill
- Steps: Send link via whatsapp/sms/qr/link; other
- Test data: email
- Expected: Only listed channels; else "channel must be whatsapp, sms, qr or link"
- Rule / code: `billing migrations; App.tsx /pay/:token`

## PAY-012

[Notion case](https://app.notion.com/p/404ead9eb8a8819da0edcddef816b521)

**Public payment link token** · P1 · security · Role: anonymous

- Preconditions: Valid & invalid token
- Steps: Open /pay/<token>
- Test data: Garbage token
- Expected: Valid shows bill amount only; invalid "payment link not found"
- Rule / code: `App.tsx PublicPaymentPage`

## PAY-013

[Notion case](https://app.notion.com/p/404ead9eb8a881b0ba5cfa333ca3057c)

**UPI QR uses placeholder** · P2 · edge · Role: billing

- Preconditions: —
- Steps: UPI QR
- Test data: —
- Expected: Known gap #63 until mapping ships
- Rule / code: `GitHub #63`
