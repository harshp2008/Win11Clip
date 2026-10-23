import { clsx } from 'clsx'

export function Switch({
  checked,
  onChange,
  isDark,
  disabled = false,
  label,
}: {
  checked: boolean
  onChange: (v: boolean) => void
  isDark: boolean
  disabled?: boolean
  /** Accessible name, for a switch whose label is not the button's own text. */
  label?: string
}) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={clsx(
        'relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-win11-bg-accent focus:ring-offset-2',
        'disabled:opacity-50 disabled:cursor-not-allowed',
        checked ? 'bg-win11-bg-accent' : isDark ? 'bg-white/10' : 'bg-gray-300',
        isDark ? 'focus:ring-offset-gray-900' : 'focus:ring-offset-white'
      )}
    >
      <span
        className={clsx(
          'inline-block h-4 w-4 transform rounded-full bg-white transition-transform',
          checked ? 'translate-x-6' : 'translate-x-1'
        )}
      />
    </button>
  )
}
