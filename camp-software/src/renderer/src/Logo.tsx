/** MILAN mark: two figures holding hands. Colour comes from `color`; the second head from --logo-accent. */
export default function Logo({ size = 32 }: { size?: number }): React.JSX.Element {
  return (
    <svg width={size} height={size} viewBox="0 0 96 96" aria-hidden="true">
      <circle cx="26" cy="20" r="9" fill="currentColor" />
      <circle cx="70" cy="20" r="9" fill="var(--logo-accent, #b85a00)" />
      <g fill="none" stroke="currentColor" strokeWidth="9" strokeLinecap="round">
        <path d="M26 38V82M70 38V82" />
        <path d="M26 50Q48 74 70 50" />
      </g>
    </svg>
  )
}
