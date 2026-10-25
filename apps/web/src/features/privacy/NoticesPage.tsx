import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { FormField } from '../../components/ui/FormField'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { apiClient } from '../../lib/api/client'
import { ConsentStep } from './ConsentStep'
import { problemText } from './problem'

const PURPOSES = [
  { code: 'reminders', label: 'Appointment and follow-up reminders (WhatsApp/SMS)', required: false },
  { code: 'marketing', label: 'Health camps and offers', required: false },
  { code: 'research', label: 'Anonymised research', required: false },
  { code: 'abdm_share', label: 'Share my health record on ABDM', required: false },
]

/** Draft and publish the hospital privacy notice. Versions are assigned by the server. */
export function NoticesPage() {
  const qc = useQueryClient()
  const notices = useQuery({ queryKey: ['privacy', 'notices'], queryFn: () => apiClient.privacy.notices() })
  const [title, setTitle] = useState('')
  const [body, setBody] = useState('')
  const [language, setLanguage] = useState('en')
  const [chosen, setChosen] = useState<Record<string, boolean>>({ reminders: true })
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const save = useMutation({
    mutationFn: () =>
      apiClient.privacy.createNotice(crypto.randomUUID(), {
        language,
        title,
        body,
        purposes: PURPOSES.filter((p) => chosen[p.code]).map((p) => p.code),
      }),
    onSuccess: async (row) => {
      setNotice(`Saved draft version ${row.version}. Publish it before the desk can use it.`)
      setError(null)
      await qc.invalidateQueries({ queryKey: ['privacy', 'notices'] })
    },
    onError: (err) => setError(problemText(err)),
  })

  const publish = useMutation({
    mutationFn: (id: string) => apiClient.privacy.publishNotice(crypto.randomUUID(), id),
    onSuccess: async (row) => {
      setNotice(`Version ${row.version} (${row.language}) is the notice the desk will show.`)
      setError(null)
      await qc.invalidateQueries({ queryKey: ['privacy', 'notices'] })
    },
    onError: (err) => setError(problemText(err)),
  })

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <h1 className="text-xl font-medium text-gray-900 dark:text-dark-50">Privacy notices</h1>
      <p className="text-sm text-gray-600 dark:text-dark-200">
        A published notice cannot be edited. Write a new version instead.
      </p>
      {notice && <Alert>{notice}</Alert>}
      {error && <Alert tone="error">{error}</Alert>}
      {notices.isPending && <LoadingBlock label="Loading notices" />}
      {notices.data && (
        <Card title="Versions">
          <ul className="space-y-3">
            {notices.data.map((row) => (
              <li key={row.noticeId} className="flex flex-wrap items-center justify-between gap-2 text-sm">
                <span>
                  {row.language} v{row.version} — {row.title}
                  {row.publishedAt ? ' · published' : ' · draft'}
                </span>
                {!row.publishedAt && (
                  <Button onClick={() => publish.mutate(row.noticeId)} disabled={publish.isPending}>
                    Publish
                  </Button>
                )}
              </li>
            ))}
            {notices.data.length === 0 && <li>No notice yet.</li>}
          </ul>
        </Card>
      )}
      <Card title="New draft">
        <form
          className="space-y-3"
          onSubmit={(event) => {
            event.preventDefault()
            save.mutate()
          }}
        >
          <label className="block text-sm font-medium">
            Language
            <select className="mt-1 min-h-11 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700" value={language} onChange={(event) => setLanguage(event.target.value)}>
              <option value="en">English</option>
              <option value="hi">Hindi</option>
              <option value="te">Telugu</option>
              <option value="ta">Tamil</option>
            </select>
          </label>
          <FormField label="Title" value={title} onChange={(event) => setTitle(event.target.value)} required />
          <label className="block text-sm font-medium">
            Notice
            <textarea
              className="mt-1 min-h-32 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700"
              value={body}
              onChange={(event) => setBody(event.target.value)}
              required
              minLength={40}
            />
          </label>
          <ConsentStep purposes={PURPOSES} value={chosen} onChange={(code, granted) => setChosen((prev) => ({ ...prev, [code]: granted }))} />
          <Button type="submit" disabled={save.isPending}>Save draft</Button>
        </form>
      </Card>
    </div>
  )
}
