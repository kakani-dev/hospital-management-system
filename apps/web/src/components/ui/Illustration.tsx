import { useEffect, useState } from 'react'

/**
 * Decorative moments from 3dicons (CC0). Every screen imports a name from here;
 * the file path stays in this registry and each picture loads in its own chunk.
 */
export type IllustrationName = 'calendar' | 'clock' | 'person' | 'shield' | 'lock' | 'chat' | 'file' | 'bell' | 'tick' | 'lab'

const loaders = {
  calendar: () => import('../../assets/illustrations/calendar.webp'),
  clock: () => import('../../assets/illustrations/clock.webp'),
  person: () => import('../../assets/illustrations/person.webp'),
  shield: () => import('../../assets/illustrations/shield.webp'),
  lock: () => import('../../assets/illustrations/lock.webp'),
  chat: () => import('../../assets/illustrations/chat.webp'),
  file: () => import('../../assets/illustrations/file.webp'),
  bell: () => import('../../assets/illustrations/bell.webp'),
  tick: () => import('../../assets/illustrations/tick.webp'),
  lab: () => import('../../assets/illustrations/lab.webp'),
} satisfies Record<IllustrationName, () => Promise<{ default: string }>>

/** Empty states, onboarding, dashboard tiles, and success or error screens. Not for buttons or tables. */
export function Illustration({
  name,
  size = 96,
  alt = '',
  className = '',
}: {
  name: IllustrationName
  size?: number
  /** Empty string: decorative. Set it only when the picture is the only description. */
  alt?: string
  className?: string
}) {
  const [src, setSrc] = useState<string | null>(null)
  useEffect(() => {
    let live = true
    // The picture is an external asset. State updates when that load finishes, not during render.
    void loaders[name]().then((mod) => {
      if (live) setSrc(mod.default)
    })
    return () => {
      live = false
    }
  }, [name])

  const box = { width: size, height: size }
  if (!src) {
    return <span aria-hidden="true" className={`inline-block shrink-0 ${className}`} style={box} data-illustration={name} />
  }
  return (
    <img
      src={src}
      alt={alt}
      width={size}
      height={size}
      decoding="async"
      loading="lazy"
      className={`inline-block shrink-0 object-contain ${className}`}
      style={box}
      data-illustration={name}
    />
  )
}
