import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { parseGs1, type Gs1Scan } from '../../lib/gs1'

const GS = '\u001d'

/**
 * Barcode field for GS1 medicine packs. A USB keyboard-wedge scanner "types" the code into the focused
 * field and presses Enter; the camera button decodes DataMatrix, QR, GS1-128 and EAN with ZXing
 * (loaded only when the camera is opened). Calls onScan with the parsed result; shows parse errors itself.
 */
export function ScanInput({
  onScan,
  label = 'Scan barcode',
  testId = 'scan',
  autoFocus = false,
}: {
  onScan: (scan: Gs1Scan, raw: string) => void
  label?: string
  testId?: string
  autoFocus?: boolean
}) {
  const id = useId()
  const [value, setValue] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [camera, setCamera] = useState(false)

  const submit = (raw: string) => {
    const scan = parseGs1(raw)
    if (scan.error) {
      setError(scan.error)
      return
    }
    setError(null)
    setValue('')
    onScan(scan, raw)
  }

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter') {
      event.preventDefault()
      submit(event.currentTarget.value)
      return
    }
    // Many wedge scanners send FNC1 as Ctrl+] (the ASCII GS keystroke) or as F8; keep it as a separator.
    if ((event.ctrlKey && event.key === ']') || event.key === 'F8') {
      event.preventDefault()
      setValue((v) => v + GS)
    }
  }

  return (
    <div className="flex flex-col gap-1" data-testid={`${testId}-box`}>
      <label htmlFor={id} className="text-sm font-medium text-gray-700 dark:text-dark-100">
        {label}
      </label>
      <div className="flex gap-2">
        <input
          id={id}
          data-testid={`${testId}-input`}
          className="min-w-0 flex-1 rounded-md border border-gray-300 px-3 py-2 font-mono text-sm dark:border-dark-400 dark:bg-dark-700"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={onKeyDown}
          placeholder="Point the scanner here, or type the code and press Enter"
          autoComplete="off"
          spellCheck={false}
          autoFocus={autoFocus}
        />
        <button
          type="button"
          data-testid={`${testId}-camera`}
          className="rounded-md border border-gray-300 px-3 py-2 text-sm dark:border-dark-400"
          onClick={() => setCamera((c) => !c)}
        >
          {camera ? 'Close camera' : 'Use camera'}
        </button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-red-700 dark:text-red-300" data-testid={`${testId}-error`}>
          {error}
        </p>
      )}
      {camera && (
        <CameraScanner
          testId={testId}
          onText={(text) => {
            setCamera(false)
            submit(text)
          }}
          onError={(msg) => {
            setCamera(false)
            setError(msg)
          }}
        />
      )}
    </div>
  )
}

function CameraScanner({ onText, onError, testId }: { onText: (t: string) => void; onError: (m: string) => void; testId: string }) {
  const video = useRef<HTMLVideoElement>(null)
  const done = useRef({ onText, onError })
  done.current = { onText, onError }

  useEffect(() => {
    let stop: (() => void) | undefined
    let cancelled = false
    ;(async () => {
      try {
        const [{ BrowserMultiFormatReader }, { BarcodeFormat, DecodeHintType }] = await Promise.all([
          import('@zxing/browser'),
          import('@zxing/library'),
        ])
        const hints = new Map()
        hints.set(DecodeHintType.POSSIBLE_FORMATS, [
          BarcodeFormat.DATA_MATRIX,
          BarcodeFormat.QR_CODE,
          BarcodeFormat.CODE_128,
          BarcodeFormat.EAN_13,
          BarcodeFormat.UPC_A,
        ])
        hints.set(DecodeHintType.ASSUME_GS1, true)
        const reader = new BrowserMultiFormatReader(hints)
        if (cancelled || !video.current) return
        const controls = await reader.decodeFromVideoDevice(undefined, video.current, (result) => {
          if (result) {
            controls.stop()
            done.current.onText(result.getText())
          }
        })
        stop = () => controls.stop()
        if (cancelled) stop()
      } catch {
        done.current.onError('The camera could not start. Allow camera access, or use the scanner.')
      }
    })()
    return () => {
      cancelled = true
      stop?.()
    }
  }, [])

  return <video ref={video} data-testid={`${testId}-video`} className="mt-2 w-full max-w-sm rounded-md bg-black" muted playsInline />
}
