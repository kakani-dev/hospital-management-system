import type { ReactNode } from 'react'

// Tailux demo "soft color" alert (js/demo .../components/alert/SoftColor.jsx).
const tones = {
  info: 'this:info',
  warning: 'this:warning',
  error: 'this:error',
}

export function Alert({ tone = 'info', children }: { tone?: keyof typeof tones; children: ReactNode }) {
  return (
    <div
      role={tone === 'error' ? 'alert' : 'status'}
      className={`${tones[tone]} rounded-lg bg-this-darker/10 px-4 py-3 text-this-darker dark:bg-this-lighter/10 dark:text-this-lighter sm:px-5`}
    >
      {children}
    </div>
  )
}
