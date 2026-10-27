import { useState } from 'react'
import type { BoardRow, Camp, FoundRow } from '../../shared/types'
import { coordText, distanceText, isStale, radiusText, timeAgo } from '../../shared/format'
import MapView, { type Focus } from './MapView'

export default function BoardTab({
  board,
  camps,
  flash,
  found,
  onDismiss
}: {
  board: BoardRow[]
  camps: Camp[] | null
  flash: Set<string>
  found: FoundRow[]
  onDismiss: (dependentId: string) => Promise<void>
}): React.JSX.Element {
  const [focus, setFocus] = useState<Focus | null>(null)
  const [selected, setSelected] = useState<string | null>(null)

  const select = (id: string): void => {
    setSelected(id)
    setFocus((f) => ({ id, n: (f?.n ?? 0) + 1 })) // n makes a second click on the same row re-zoom
  }

  return (
    <div className="board">
      <section className="board-list">
        {found.length > 0 && (
          <div className="fstrip">
            <h2 className="fstrip-title">Found ({found.length})</h2>
            {found.map((f) => (
              <div key={f.id} className="frow">
                <div>
                  <span className="fname">{f.name}</span>{' '}
                  <span className="mono small muted">{f.beacon_label}</span>
                  <div className="small">
                    {camps?.find((c) => c.id === f.camp_id)?.name ?? 'No camp'} ·{' '}
                    {timeAgo(f.found_at)}
                  </div>
                  <div className="small muted">
                    {f.parent_name}
                    {f.parent_phone ? ` · ${f.parent_phone}` : ''}
                  </div>
                </div>
                <div className="frow-side">
                  <span className="pill">Waiting</span>
                  <button className="btn-outline" onClick={() => void onDismiss(f.id)}>
                    Dismiss
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
        <h2 className="eyebrow">Missing</h2>
        <div className="card">
          <table className="board-table">
            <thead>
              <tr>
                <th>Dependent</th>
                <th>Region last seen</th>
                <th>Nearest camp</th>
              </tr>
            </thead>
            <tbody>
              {board.length === 0 && (
                <tr>
                  <td colSpan={3} className="empty">
                    None missing
                  </td>
                </tr>
              )}
              {board.map((r) => {
                const hasSighting = r.lat != null && r.lon != null && r.seen_at
                const stale = hasSighting && isStale(r.seen_at as string)
                const cls = [
                  selected === r.child_id ? 'selected' : '',
                  flash.has(r.child_id) ? 'flash' : '',
                  stale ? 'stale' : ''
                ].join(' ')
                return (
                  <tr key={r.child_id} className={cls} onClick={() => select(r.child_id)}>
                    <td>
                      {/* A real button so keyboard users can select; its click bubbles to the row. */}
                      <button className="row-btn">{r.child_name}</button>
                      <div className="mono small muted">{r.beacon_label}</div>
                    </td>
                    {hasSighting ? (
                      <>
                        <td>
                          {radiusText(r.radius_m ?? 0)} of{' '}
                          {coordText(r.lat as number, r.lon as number)}
                          {r.accuracy_m != null && r.predicted_distance_m != null && (
                            <div className="small muted">
                              GPS ±{Math.round(r.accuracy_m)} m + BLE{' '}
                              {Math.round(r.predicted_distance_m)} m
                              {r.rssi_dbm != null ? ` (${Math.round(r.rssi_dbm)} dBm)` : ''}
                            </div>
                          )}
                          <div className="small muted">
                            {timeAgo(r.seen_at as string)}
                            {stale && <span className="pill">stale</span>}
                          </div>
                        </td>
                        <td>
                          {r.camp_name}
                          {r.distance_m != null && (
                            <div className="small muted">{distanceText(r.distance_m)}</div>
                          )}
                        </td>
                      </>
                    ) : (
                      <>
                        <td className="muted">No sightings yet</td>
                        <td className="muted">—</td>
                      </>
                    )}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </section>

      <section className="board-map" aria-label="Map">
        {camps ? (
          <MapView camps={camps} board={board} focus={focus} />
        ) : (
          <div className="empty">Loading map…</div>
        )}
      </section>
    </div>
  )
}
