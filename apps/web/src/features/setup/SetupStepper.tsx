import { CheckIcon } from '@heroicons/react/24/outline'
import { SETUP_STEPS, type SetupStep } from './setupState'

const LABELS: Record<SetupStep, string> = {
  profile: 'Hospital',
  branch: 'Branch',
  staff: 'Staff',
  schedule: 'Schedule',
  done: 'Done',
}

/**
 * Numbered step list. Tailux demo2's add-product Steps (an ordered list of numbered circles,
 * a check once a step is behind, primary on the current step) is the model. That component and
 * its `.steps` stylesheet were not in the vendored Tailux subset (starter + demo primitives only),
 * so this uses the same tokens (primary-600, gray-200, dark-500) instead of adding another package.
 */
export function SetupStepper({ current }: { current: SetupStep }) {
  const index = SETUP_STEPS.indexOf(current)
  return (
    <ol className="flex flex-wrap gap-x-6 gap-y-3" aria-label="Setup progress">
      {SETUP_STEPS.map((step, i) => {
        const state = i < index ? 'complete' : i === index ? 'current' : 'upcoming'
        return (
          <li key={step} className="flex items-center gap-2" aria-current={state === 'current' ? 'step' : undefined}>
            <span
              className={
                state === 'upcoming'
                  ? 'flex size-7 items-center justify-center rounded-full bg-gray-200 text-xs font-semibold text-gray-600 dark:bg-dark-500 dark:text-dark-100'
                  : 'flex size-7 items-center justify-center rounded-full bg-primary-600 text-xs font-semibold text-white'
              }
            >
              {state === 'complete' ? <CheckIcon className="size-4" aria-hidden /> : i + 1}
            </span>
            <span className={state === 'current' ? 'text-sm font-medium text-gray-800 dark:text-dark-50' : 'text-sm text-gray-600 dark:text-dark-200'}>
              {LABELS[step]}
            </span>
          </li>
        )
      })}
    </ol>
  )
}
