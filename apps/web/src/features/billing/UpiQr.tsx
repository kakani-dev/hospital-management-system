import { useEffect, useState } from 'react'
import QRCode from 'qrcode'

/** On-screen UPI QR. The picture is the payment target, so it has a name. */
export function UpiQr({ uri }: { uri: string }) {
  const [svg, setSvg] = useState<string | null>(null)
  useEffect(() => {
    let live = true
    void QRCode.toString(uri, { type: 'svg', margin: 1, width: 220, errorCorrectionLevel: 'M' }).then((value) => {
      if (live) setSvg(value)
    })
    return () => {
      live = false
    }
  }, [uri])

  if (!svg) {
    return (
      <div className="grid size-56 place-items-center text-sm text-gray-500" role="status">
        Preparing the QR…
      </div>
    )
  }
  return (
    <div
      className="rounded-lg bg-white p-3 [&_svg]:h-auto [&_svg]:w-56"
      role="img"
      aria-label="UPI payment QR"
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  )
}
