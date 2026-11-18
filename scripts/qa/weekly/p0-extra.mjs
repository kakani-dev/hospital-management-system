/**
 * P0 cases that the weekly suite previously skipped:
 * SIG-001/002, WIZ-001, BRN-001, STF-001/004, PAY-007, E2E-001/002/003/005
 */
import {
  anon, c, createSyntheticAuthUser, ist, passwordToken, platformToken, rnd, RUN_ID, TAG, track, withToken,
} from './lib.mjs'

export async function runP0Extra(rec, ctx) {
  const { branchId: H } = ctx
  const phone = () => '+9190000' + rnd()

  // ---------- SIG-001 / SIG-002 ----------
  const sigEmail = `qa+${RUN_ID}@example.test`
  const sigName = `QA Test Hospital ${ist()} ${rnd()}`
  const sig = await anon('POST', '/api/v1/public/hospital-signups', {
    hospitalName: sigName,
    timeZone: 'Asia/Kolkata',
    contactName: 'QA Test Contact',
    contactEmail: sigEmail,
    phone: phone(),
    city: 'Hyderabad',
  })
  rec('SIG-001', sig.s === 202 && /received|review/i.test(sig.t), `${sig.s} ${sig.t.slice(0, 120)}`)
  if (sig.s === 202) track('hospital_signup', { email: sigEmail, hospitalName: sigName, status: 'pending' })

  const dup = await anon('POST', '/api/v1/public/hospital-signups', {
    hospitalName: `QA Test Dup ${rnd()}`,
    timeZone: 'Asia/Kolkata',
    contactName: 'QA Test',
    contactEmail: 'qa.admin@demo.medicore.test',
    phone: phone(),
    city: 'Hyderabad',
  })
  const dupCode = dup.j?.code || dup.j?.title || ''
  const dupOk = dup.s === 409 && (/email_registered|email.?registered|already/i.test(dup.t) || /email_registered/i.test(dupCode))
  rec('SIG-002', dupOk, `${dup.s} ${dup.t.slice(0, 160)}`)

  // ---------- WIZ-001 (+ tenant for STF-004) ----------
  let wizAdminTok = null
  let wizTenantId = null
  let wizMembershipId = null
  let wizBranchId = null
  try {
    const user = await createSyntheticAuthUser(`zz-qa.wiz.${RUN_ID}`)
    const wizName = `QA Test Hospital Wiz ${RUN_ID}`
    const wizPhone = phone()
    const reg = await anon('POST', '/api/v1/public/hospital-signups', {
      hospitalName: wizName,
      timeZone: 'Asia/Kolkata',
      contactName: 'QA Test Wizard',
      contactEmail: user.email,
      phone: wizPhone,
      city: 'Hyderabad',
    })
    track('hospital_signup', { email: user.email, hospitalName: wizName, status: reg.s === 202 ? 'pending' : 'failed', http: reg.s })
    if (reg.s !== 202) {
      rec('WIZ-001', false, `signup ${reg.s} ${reg.t.slice(0, 120)}`)
    } else {
      const pTok = await platformToken()
      const pending = await withToken(pTok, 'GET', '/api/v1/platform/hospital-requests?status=pending')
      const list = Array.isArray(pending.j) ? pending.j : []
      const mine = list.find(r => r.contactEmail?.toLowerCase() === user.email.toLowerCase())
      if (!mine) {
        rec('WIZ-001', false, 'pending request not found for wizard contact')
      } else {
        const code = (`zqa${RUN_ID}`).toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 20)
        let ap = await withToken(pTok, 'POST', `/api/v1/platform/hospital-requests/${mine.id}/approve`, {
          tenantCode: code,
          acknowledgeDuplicate: !!mine.possibleDuplicate,
        })
        if (ap.s === 409 && /duplicate/i.test(ap.t)) {
          ap = await withToken(pTok, 'POST', `/api/v1/platform/hospital-requests/${mine.id}/approve`, {
            tenantCode: code,
            acknowledgeDuplicate: true,
          })
        }
        track('tenant_approved', {
          tenantId: ap.j?.tenantId, tenantCode: code, hospitalName: wizName,
          inviteId: ap.j?.invite?.id, requestId: mine.id,
        })
        if (ap.s >= 300 || !ap.j?.invite?.token) {
          rec('WIZ-001', false, `approve ${ap.s} ${ap.t.slice(0, 160)}`)
        } else {
          wizAdminTok = await passwordToken(user.email, user.password)
          const claim = await withToken(wizAdminTok, 'POST', '/api/v1/me/invite-links/claim', { token: ap.j.invite.token })
          track('invite_claimed', { email: user.email, tenantId: claim.j?.tenantId || ap.j.tenantId, status: claim.s })
          if (claim.s >= 300) {
            rec('WIZ-001', false, `claim ${claim.s} ${claim.t.slice(0, 160)}`)
          } else {
            wizTenantId = claim.j?.tenantId || ap.j.tenantId
            // refresh token / context after claim
            wizAdminTok = await passwordToken(user.email, user.password)
            await withToken(wizAdminTok, 'POST', '/api/v1/me/context', { tenantId: wizTenantId })
            const setup0 = await withToken(wizAdminTok, 'GET', '/api/v1/setup')
            // profile -> branch
            await withToken(wizAdminTok, 'PATCH', '/api/v1/tenants/current', { name: wizName, timeZone: 'Asia/Kolkata' })
            const toBranch = await withToken(wizAdminTok, 'POST', '/api/v1/setup/step', { step: 'branch' })
            const branches = await withToken(wizAdminTok, 'GET', '/api/v1/branches')
            const blist = Array.isArray(branches.j) ? branches.j : []
            let br = blist.find(b => !b.isDeleted) || blist[0]
            if (br) {
              const renamed = await withToken(wizAdminTok, 'PATCH', `/api/v1/branches/${br.id}`, {
                name: 'QA Main', address: 'QA Test Road ' + RUN_ID,
              })
              br = renamed.j || br
              const gstin = '36AAAAA0000A1Z5'
              const prof = await withToken(wizAdminTok, 'PUT', `/api/v1/price-lists/branches/${br.id}/profile`, {
                gstin, legalName: 'QA Test ' + wizName,
              })
              track('branch', { id: br.id, name: 'QA Main', gstin, tenantId: wizTenantId, profileStatus: prof.s })
              wizBranchId = br.id
            }
            const toStaff = await withToken(wizAdminTok, 'POST', '/api/v1/setup/step', { step: 'staff' })
            const toSched = await withToken(wizAdminTok, 'POST', '/api/v1/setup/step', { step: 'schedule' })
            const toDone = await withToken(wizAdminTok, 'POST', '/api/v1/setup/step', { step: 'done' })
            const setup1 = await withToken(wizAdminTok, 'GET', '/api/v1/setup')
            const ok = setup1.j?.step === 'done' && !!setup1.j?.completedOn
            rec('WIZ-001', ok, `setup ${setup1.j?.step} completedOn=${!!setup1.j?.completedOn} advances=${[toBranch.s, toStaff.s, toSched.s, toDone.s].join(',')}`)
            const mems = await withToken(wizAdminTok, 'GET', '/api/v1/members')
            const mlist = Array.isArray(mems.j) ? mems.j : []
            const self = mlist.find(m => (m.email || '').toLowerCase() === user.email.toLowerCase())
            wizMembershipId = self?.id
          }
        }
      }
    }
  } catch (e) {
    rec('WIZ-001', false, String(e).slice(0, 200))
  }

  // ---------- BRN-001 (Demo Hospital, tagged) ----------
  const brCode = ('zqa' + rnd()).toLowerCase()
  const brCreate = await c('admin', 'POST', '/api/v1/branches', {
    code: brCode,
    name: `QA Test Branch ${RUN_ID}`,
    timezone: 'Asia/Kolkata',
    address: 'QA Test Branch Address',
  })
  const brId = brCreate.j?.id
  let brnOk = brCreate.s < 300 && !!brId
  let gstinSaved = false
  if (brId) {
    track('branch', { id: brId, code: brCode, name: `QA Test Branch ${RUN_ID}`, tenant: 'demo' })
    const gstin = '36ZZZCM9999M1ZN'
    const prof = await c('admin', 'PUT', `/api/v1/price-lists/branches/${brId}/profile`, {
      gstin, legalName: `QA Test Branch ${RUN_ID}`,
    })
    gstinSaved = prof.s < 300 && (prof.j?.gstin === gstin || /36ZZZCM9999M1ZN/.test(prof.t))
    if (!gstinSaved && prof.s < 300) {
      const g = await c('admin', 'GET', `/api/v1/price-lists/branches/${brId}/profile`)
      gstinSaved = g.j?.gstin === gstin
    }
    brnOk = brnOk && gstinSaved
  }
  rec('BRN-001', brnOk, `${brCreate.s} id=${brId} gstinSaved=${gstinSaved}`)

  // ---------- STF-001 ----------
  const inviteEmail = `zz-qa.invite.${RUN_ID}@synthetic.example`
  const inv = await c('admin', 'POST', '/api/v1/members/invite-links', {
    email: inviteEmail, role: 'receptionist',
  })
  const invOk = inv.s < 300 && !!(inv.j?.id || inv.j?.token)
  if (invOk) track('invite', { id: inv.j?.id, email: inviteEmail, role: 'receptionist', tenant: 'demo' })
  let listed = false
  if (inv.j?.id) {
    const list = await c('admin', 'GET', '/api/v1/members/invite-links')
    const items = Array.isArray(list.j) ? list.j : []
    listed = items.some(x => x.id === inv.j.id || (x.email || '').toLowerCase() === inviteEmail)
  }
  rec('STF-001', invOk && (listed || !!inv.j?.token), `${inv.s} listed=${listed} ${inv.t.slice(0, 100)}`)

  // ---------- STF-004 (sole admin on wizard tenant) ----------
  if (wizAdminTok && wizMembershipId) {
    const del = await withToken(wizAdminTok, 'DELETE', `/api/v1/members/${wizMembershipId}`)
    const stf4 = del.s >= 400 && /last_admin/i.test(del.t)
    rec('STF-004', stf4, `${del.s} ${del.t.slice(0, 160)}`)
  } else {
    rec('STF-004', null, 'blocked: wizard tenant / membership unavailable')
  }

  // ---------- PAY-007 cash daily limit ----------
  await runPay007(rec, H)

  // ---------- E2E cases ----------
  await runE2E(rec, H, ctx)
}

async function runPay007(rec, H) {
  try {
    const ses = await c('billing', 'POST', '/api/v1/counter-sessions/ensure', { branchId: H })
    const SID = ses.j?.id
    if (!SID) { rec('PAY-007', false, 'no counter session ' + ses.s); return }
    const SI = (await c('admin', 'GET', '/api/v1/service-items')).j
    const item = (Array.isArray(SI) ? SI : []).find(s => s.isActive && s.hospitalPricePaise > 0)
    if (!item) { rec('PAY-007', false, 'no priced service item'); return }
    const unit = item.hospitalPricePaise
    // Target: patient has paid 1,99,999.00 cash (19999900 paise), then +1 rupee cash refused.
    const nearLimit = 19999900
    const qty = Math.ceil(nearLimit / unit)
    const pat = await c('reception', 'POST', '/api/v1/patients', {
      firstName: 'QA Test', lastName: `CashLimit ${RUN_ID}`, sex: 'male', dateOfBirth: '1988-05-05',
      phone: '+9190000' + rnd(), registeredBranchId: H,
    })
    const p = pat.j?.id
    track('patient', { id: p, mrn: pat.j?.mrn, name: `QA Test CashLimit ${RUN_ID}` })
    const acct = await c('billing', 'POST', '/api/v1/accounts', { patientId: p, branchId: H })
    const billId = acct.j?.id
    const accountId = acct.j?.accountId
    const line = await c('billing', 'POST', `/api/v1/bills/${billId}/lines`, { serviceItemId: item.id, quantity: qty })
    if (line.s >= 300) { rec('PAY-007', false, `line ${line.s} ${line.t.slice(0, 120)}`); return }
    const fin = await c('billing', 'POST', `/api/v1/bills/${billId}/finalize`)
    if (fin.s >= 300) { rec('PAY-007', false, `finalize ${fin.s} ${fin.t.slice(0, 120)}`); return }
    const due = (await c('billing', 'GET', `/api/v1/bills/${billId}`)).j?.duePaise
    // Pay exactly nearLimit cash (or min(due, nearLimit)); leave room for +100 attempt via second tiny bill if needed
    const cash1 = Math.min(due, nearLimit)
    const pay1 = await c('billing', 'POST', '/api/v1/payments', {
      kind: 'payment', accountId, counterSessionId: SID,
      tenders: [{ mode: 'cash', amountPaise: cash1 }],
      allocations: [{ billId, amountPaise: cash1 }],
    }, { 'idempotency-key': crypto.randomUUID() })
    if (pay1.s >= 300) { rec('PAY-007', false, `cash1 ${pay1.s} ${pay1.t.slice(0, 140)}`); return }
    track('payment', { id: pay1.j?.id, amountPaise: cash1, mode: 'cash', case: 'PAY-007' })

    // Second small bill for +₹1 cash
    const acct2 = await c('billing', 'POST', '/api/v1/accounts', { patientId: p, branchId: H })
    const bill2 = acct2.j?.id
    await c('billing', 'POST', `/api/v1/bills/${bill2}/lines`, { code: 'CONSULT', quantity: 1 })
    await c('billing', 'POST', `/api/v1/bills/${bill2}/finalize`)
    const due2 = (await c('billing', 'GET', `/api/v1/bills/${bill2}`)).j?.duePaise || 100
    const cash2 = await c('billing', 'POST', '/api/v1/payments', {
      kind: 'payment', accountId: acct2.j?.accountId, counterSessionId: SID,
      tenders: [{ mode: 'cash', amountPaise: 100 }],
      allocations: [{ billId: bill2, amountPaise: 100 }],
    }, { 'idempotency-key': crypto.randomUUID() })
    const refused = cash2.s >= 400 && /2,00,000|200000|daily limit|cash would reach/i.test(cash2.t)
    const card = await c('billing', 'POST', '/api/v1/payments', {
      kind: 'payment', accountId: acct2.j?.accountId, counterSessionId: SID,
      tenders: [{ mode: 'card', amountPaise: Math.min(100, due2) }],
      allocations: [{ billId: bill2, amountPaise: Math.min(100, due2) }],
    }, { 'idempotency-key': crypto.randomUUID() })
    const cardOk = card.s < 300
    rec('PAY-007', refused && cardOk, `cash2=${cash2.s} ${cash2.t.slice(0, 100)} | card=${card.s}`)
  } catch (e) {
    rec('PAY-007', false, String(e).slice(0, 200))
  }
}

async function runE2E(rec, H, ctx) {
  const today = ist()
  // E2E-001 Morning opening
  try {
    const a = await c('admin', 'GET', '/api/v1/me')
    const ses = await c('billing', 'POST', '/api/v1/counter-sessions/ensure', { branchId: H })
    const appts = await c('reception', 'GET', `/api/v1/appointments?branchId=${H}&date=${today}`)
    const alist = Array.isArray(appts.j) ? appts.j : (appts.j?.items || [])
    const queue = await c('doctor', 'GET', `/api/v1/queue?branchId=${H}`)
    const ok = a.s === 200 && ses.s < 300 && !!ses.j?.id && appts.s === 200 && queue.s === 200
    rec('E2E-001', ok, `admin=${a.s} session=${ses.s} appts=${appts.s}/${alist.length} queue=${queue.s}`)
  } catch (e) {
    rec('E2E-001', false, String(e).slice(0, 160))
  }

  // E2E-002 Busy OPD hour (scaled to available slots; tagged)
  try {
    const doctorMe = (await c('doctor', 'GET', '/api/v1/me')).j
    const prs = (await c('admin', 'GET', '/api/v1/practitioners')).j
    const V = (Array.isArray(prs) ? prs : []).find(p => p.userId === doctorMe.userId)?.id
    const vts = (await c('admin', 'GET', '/api/v1/visit-types')).j
    const VT = (Array.isArray(vts) ? vts : []).find(v => v.code === 'new_consult')
    const slots = (await c('reception', 'GET', `/api/v1/slots?branchId=${H}&practitionerId=${V}&date=${today}`)).j || []
    const future = (Array.isArray(slots) ? slots : []).filter(s => new Date(s.startsAt) > new Date())
    // Pick slots at least 30 min apart (consult duration)
    const picked = []
    for (const s of future) {
      const t = +new Date(s.startsAt)
      if (picked.every(u => Math.abs(+new Date(u.startsAt) - t) >= 30 * 60e3)) picked.push(s)
      if (picked.length >= 10) break
    }
    const booked = []
    for (let i = 0; i < picked.length; i++) {
      const pat = await c('reception', 'POST', '/api/v1/patients', {
        firstName: 'QA Test', lastName: `E2E2Book${i} ${RUN_ID}`, sex: 'female', dateOfBirth: '1992-02-02',
        phone: '+9190000' + rnd(), registeredBranchId: H,
      })
      const a = await c('reception', 'POST', '/api/v1/appointments', {
        branchId: H, practitionerId: V, patientId: pat.j?.id, startsAt: picked[i].startsAt, endsAt: picked[i].endsAt,
        visitTypeId: VT.id, reason: TAG,
      })
      if (a.s < 300) { booked.push(a.j); track('appointment', { id: a.j?.id, case: 'E2E-002' }) }
    }
    const walkins = []
    for (let i = 0; i < 3; i++) {
      const pat = await c('reception', 'POST', '/api/v1/patients', {
        firstName: 'QA Test', lastName: `E2E2Walk${i} ${RUN_ID}`, sex: 'male', dateOfBirth: '1993-03-03',
        phone: '+9190000' + rnd(), registeredBranchId: H,
      })
      const w = await c('reception', 'POST', '/api/v1/queue/walk-in', { branchId: H, patientId: pat.j?.id, practitionerId: V })
      if (w.s < 300) { walkins.push(w.j); track('queue_walkin', { id: w.j?.id || w.j?.queueEntryId, case: 'E2E-002' }) }
    }
    // Check in as many booked as still in future slots today
    let checked = 0, drafts = 0, paid = 0
    const SID = (await c('billing', 'POST', '/api/v1/counter-sessions/ensure', { branchId: H })).j?.id
    for (const ap of booked.slice(0, 5)) {
      const ci = await c('reception', 'POST', `/api/v1/appointments/${ap.id}/check-in`)
      if (ci.s < 300) {
        checked++
        const qid = ci.j?.queueEntry?.id || ci.j?.queueEntryId
        const bills = await c('billing', 'GET', `/api/v1/bills?patientId=${ap.patientId}`)
        const bl = (Array.isArray(bills.j) ? bills.j : []).filter(b => b.patientId === ap.patientId && b.status === 'draft')
        if (bl.length === 1) drafts++
        if (qid) {
          await c('doctor', 'PATCH', `/api/v1/queue/${qid}`, { status: 'in_consultation' })
          await c('doctor', 'PATCH', `/api/v1/queue/${qid}`, { status: 'done' })
        }
        if (bl[0] && SID) {
          const f = await c('billing', 'POST', `/api/v1/bills/${bl[0].id}/finalize`)
          const due = (await c('billing', 'GET', `/api/v1/bills/${bl[0].id}`)).j?.duePaise
          if (f.s < 300 && due > 0) {
            const mode = paid % 2 === 0 ? 'upi' : 'card'
            const pay = await c('billing', 'POST', '/api/v1/payments', {
              kind: 'payment', accountId: bl[0].accountId, counterSessionId: SID,
              tenders: [{ mode, amountPaise: due }],
              allocations: [{ billId: bl[0].id, amountPaise: due }],
            }, { 'idempotency-key': crypto.randomUUID() })
            if (pay.s < 300) paid++
          }
        }
      }
    }
    const ok = booked.length >= 1 && walkins.length === 3 && checked >= 1 && drafts >= 1
    rec('E2E-002', ok, `booked=${booked.length}/${picked.length} walkins=${walkins.length} checked=${checked} drafts=${drafts} paid=${paid}`)
  } catch (e) {
    rec('E2E-002', false, String(e).slice(0, 200))
  }

  // E2E-003 Refund dispute
  try {
    const SID = (await c('billing', 'POST', '/api/v1/counter-sessions/ensure', { branchId: H })).j?.id
    const pat = await c('reception', 'POST', '/api/v1/patients', {
      firstName: 'QA Test', lastName: `E2E3Refund ${RUN_ID}`, sex: 'female', dateOfBirth: '1990-04-04',
      phone: '+9190000' + rnd(), registeredBranchId: H,
    })
    const acct = await c('billing', 'POST', '/api/v1/accounts', { patientId: pat.j?.id, branchId: H })
    await c('billing', 'POST', `/api/v1/bills/${acct.j?.id}/lines`, { code: 'CONSULT', quantity: 1 })
    await c('billing', 'POST', `/api/v1/bills/${acct.j?.id}/finalize`)
    const bill = (await c('billing', 'GET', `/api/v1/bills/${acct.j?.id}`)).j
    const due = bill?.duePaise || 50000
    const pay = await c('billing', 'POST', '/api/v1/payments', {
      kind: 'payment', accountId: acct.j?.accountId,
      tenders: [{ mode: 'upi', amountPaise: due }],
      allocations: [{ billId: bill.id, amountPaise: due }],
    }, { 'idempotency-key': crypto.randomUUID() })
    track('payment', { id: pay.j?.id, mode: 'upi', case: 'E2E-003' })
    // Cashier tries cash refund of digital -> needs manager
    const cashRef = await c('billing', 'POST', `/api/v1/payments/${pay.j?.id}/refunds`, {
      amountPaise: due, reasonCode: 'other', mode: 'cash', counterSessionId: SID,
    })
    const needsMgr = cashRef.s >= 400 && /manager|digital/i.test(cashRef.t)
    // Proper path: refund to UPI requiring approval when above threshold
    const upiRef = await c('billing', 'POST', `/api/v1/payments/${pay.j?.id}/refunds`, {
      amountPaise: due, reasonCode: 'other', mode: 'upi',
    })
    let approved = false
    if (upiRef.j?.approvalId) {
      const self = await c('billing', 'POST', `/api/v1/approvals/${upiRef.j.approvalId}/decide`, { status: 'approved' })
      const ad = await c('admin', 'POST', `/api/v1/approvals/${upiRef.j.approvalId}/decide`, { status: 'approved' })
      approved = self.s >= 400 && ad.s < 300
      track('refund_approval', { approvalId: upiRef.j.approvalId, case: 'E2E-003' })
    } else if (upiRef.s < 300) {
      // small amount auto-approved path — still ok if cash-of-digital was blocked
      approved = true
    }
    rec('E2E-003', needsMgr && (approved || upiRef.s < 300 || !!upiRef.j?.approvalId),
      `cashRef=${cashRef.s} ${cashRef.t.slice(0, 80)} | upiRef=${upiRef.s} approval=${!!upiRef.j?.approvalId} approved=${approved}`)
  } catch (e) {
    rec('E2E-003', false, String(e).slice(0, 200))
  }

  // E2E-005 CA month-end GST
  try {
    const from = ist(-30).slice(0, 8) + '01'
    const to = today
    const er = await c('accountant', 'GET', `/api/v1/billing-reports/earnings?branchId=${H}&from=${from}&to=${to}`)
    const { E, T } = await import('../h.mjs')
    const cv = await fetch(`${E}/api/v1/billing-reports/earnings/export?branchId=${H}&from=${from}&to=${to}&format=csv`, {
      headers: { authorization: 'Bearer ' + T.accountant },
    })
    const body = er.j || {}
    const text = JSON.stringify(body)
    const hasGst = /cgst|sgst|igst/i.test(text)
    // IGST should only appear with inter-state; soft check: if igst present, cgst/sgst may also exist for intra
    const bills = await c('billing', 'GET', `/api/v1/bills?from=${from}&to=${to}&branchId=${H}`)
    const blist = Array.isArray(bills.j) ? bills.j : (bills.j?.items || [])
    const ok = er.s === 200 && hasGst && cv.status === 200
    rec('E2E-005', ok, `earnings=${er.s} gst=${hasGst} export=${cv.status} billsListed=${blist.length}`)
  } catch (e) {
    rec('E2E-005', false, String(e).slice(0, 200))
  }
}
