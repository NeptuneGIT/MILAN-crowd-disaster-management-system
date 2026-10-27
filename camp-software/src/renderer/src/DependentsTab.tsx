import { useEffect, useMemo, useRef, useState } from 'react'
import type { BoardRow, Camp, DependentRow } from '../../shared/types'

interface Pending {
  dependent: DependentRow
  to: boolean
}

export default function DependentsTab({
  rows: dependents,
  board,
  camps,
  onChanged
}: {
  rows: DependentRow[]
  board: BoardRow[]
  camps: Camp[] | null
  onChanged: () => Promise<void>
}): React.JSX.Element {
  const [query, setQuery] = useState('')
  const [pending, setPending] = useState<Pending | null>(null)

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return dependents
    return dependents.filter(
      (c) => c.name.toLowerCase().includes(q) || c.beacon_label.toLowerCase().includes(q)
    )
  }, [dependents, query])

  const missingCount = dependents.filter((c) => c.is_missing).length

  return (
    <main className="dependents-tab">
      <div className="search-row">
        <label htmlFor="search">Search</label>
        <input
          id="search"
          type="search"
          placeholder="Name or KM-000123"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <span className="muted small">
          {dependents.length} dependents · {missingCount} missing
        </span>
      </div>

      <div className="card">
        <table className="dependents-table">
          <thead>
            <tr>
              <th>Dependent</th>
              <th>Beacon label</th>
              <th>Parent</th>
              <th>Parent phone</th>
              <th className="right">Missing?</th>
            </tr>
          </thead>
          <tbody>
            {shown.length === 0 && (
              <tr>
                <td colSpan={5} className="empty">
                  {dependents.length === 0 ? 'No dependents found.' : 'No match.'}
                </td>
              </tr>
            )}
            {shown.map((c) => (
              <tr key={c.id}>
                <td className="strong">{c.name}</td>
                <td className="mono">{c.beacon_label}</td>
                <td>{c.parent_name}</td>
                <td className="mono">{c.parent_phone ?? '—'}</td>
                <td className="right">
                  <span className="switch-row">
                    <span className="muted small">{c.is_missing ? 'Missing' : 'Found'}</span>
                    <button
                      role="switch"
                      aria-checked={c.is_missing}
                      aria-label={`${c.name} missing`}
                      className={c.is_missing ? 'switch on' : 'switch'}
                      onClick={() => setPending({ dependent: c, to: !c.is_missing })}
                    >
                      <span className="knob" />
                    </button>
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {pending && (
        <ConfirmDialog
          pending={pending}
          camps={camps ?? []}
          nearestCampId={board.find((r) => r.child_id === pending.dependent.id)?.camp_id ?? null}
          onCancel={() => setPending(null)}
          onConfirm={async (campId) => {
            await window.camp.setMissing(pending.dependent.id, pending.to, campId)
            await onChanged()
            setPending(null)
          }}
        />
      )}
    </main>
  )
}

function ConfirmDialog({
  pending,
  camps,
  nearestCampId,
  onCancel,
  onConfirm
}: {
  pending: Pending
  camps: Camp[]
  /** Camp nearest to the dependent's last sighting: the default for "Found at". */
  nearestCampId: string | null
  onCancel: () => void
  onConfirm: (foundCampId: string | undefined) => Promise<void>
}): React.JSX.Element {
  const ref = useRef<HTMLDialogElement>(null)
  const [campId, setCampId] = useState(nearestCampId ?? camps[0]?.id ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const { dependent, to } = pending

  // A native <dialog> gives a focus trap, Esc to cancel and a backdrop for free.
  useEffect(() => {
    ref.current?.showModal()
  }, [])

  const confirm = async (): Promise<void> => {
    setBusy(true)
    setError(null)
    try {
      await onConfirm(to ? undefined : campId || undefined)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setBusy(false)
    }
  }

  return (
    <dialog ref={ref} className="dialog" onCancel={onCancel} aria-labelledby="confirm-title">
      <h2 id="confirm-title">
        Mark {dependent.name} {to ? 'missing' : 'found'}?
      </h2>
      {!to && (
        <div className="field">
          <label htmlFor="found-camp">Found at</label>
          <select id="found-camp" value={campId} onChange={(e) => setCampId(e.target.value)}>
            {camps.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
                {c.id === nearestCampId ? ' (nearest)' : ''}
              </option>
            ))}
          </select>
        </div>
      )}
      {error && (
        <div role="alert" className="alert">
          {error}
        </div>
      )}
      <div className="dialog-actions">
        <button className="btn-outline" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
        <button className={to ? 'btn-danger' : 'btn-primary'} onClick={confirm} disabled={busy}>
          {busy ? 'Saving' : 'Confirm'}
        </button>
      </div>
    </dialog>
  )
}
