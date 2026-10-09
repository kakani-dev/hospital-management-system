import { SelectField } from '../ui/SelectField'
import type { BranchOption } from '../../lib/api/types'

export function BranchPicker({
  branches,
  value,
  onChange,
}: {
  branches: BranchOption[]
  value: string | null
  onChange: (id: string) => void
}) {
  return (
    <div className="w-60">
      <SelectField label="Branch" data-testid="branch-picker" value={value ?? ''} onChange={(e) => onChange(e.target.value)} disabled={branches.length <= 1}>
        {branches.length === 0 && <option value="">No branch access</option>}
        {branches.map((b) => (
          <option key={b.id} value={b.id}>
            {b.name}
          </option>
        ))}
      </SelectField>
    </div>
  )
}
