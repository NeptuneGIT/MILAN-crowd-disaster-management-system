import { useCallback, useEffect, useRef, useState } from 'react'
import type { BoardRow, Camp, CampSession, DependentRow, FoundRow } from '../../shared/types'
import BoardTab from './BoardTab'
import DependentsTab from './DependentsTab'
import Logo from './Logo'
import LoginScreen from './LoginScreen'

const POLL_MS = 3000
const FLASH_MS = 2000

const message = (e: unknown): string => (e instanceof Error ? e.message : String(e))

export default function App(): React.JSX.Element | null {
  // undefined = still checking, null = signed out
  const [session, setSession] = useState<CampSession | null | undefined>(undefined)

  useEffect(() => {
    window.camp
      .getSession()
      .then(setSession)
      .catch(() => setSession(null))
  }, [])

  if (session === undefined) return null
  if (!session) return <LoginScreen onSignedIn={setSession} />
  return <Shell session={session} onSignedOut={() => setSession(null)} />
}

function Shell({
  session,
  onSignedOut
}: {
  session: CampSession
  onSignedOut: () => void
}): React.JSX.Element {
  const [tab, setTab] = useState<'board' | 'dependents'>('board')
  const [board, setBoard] = useState<BoardRow[]>([])
  const [camps, setCamps] = useState<Camp[] | null>(null)
  const [dependents, setDependents] = useState<DependentRow[]>([])
  const [found, setFound] = useState<FoundRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [updatedAt, setUpdatedAt] = useState<number | null>(null)
  const [flash, setFlash] = useState<Set<string>>(new Set())
  const lastSeen = useRef<Map<string, string | null>>(new Map())
  const inFlight = useRef(false)

  const refreshBoard = useCallback(async () => {
    if (inFlight.current) return // a slow request must not stack up behind the 3 s timer
    inFlight.current = true
    try {
      const [rows, foundRows] = await Promise.all([window.camp.getBoard(), window.camp.getFound()])
      setFound(foundRows)
      const next = new Map<string, string | null>()
      const fresh: string[] = []
      for (const r of rows) {
        next.set(r.child_id, r.seen_at)
        // Flash only when a *different* sighting arrives for a dependent we already knew about.
        if (
          lastSeen.current.has(r.child_id) &&
          r.seen_at &&
          lastSeen.current.get(r.child_id) !== r.seen_at
        ) {
          fresh.push(r.child_id)
        }
      }
      lastSeen.current = next
      setBoard(rows)
      setError(null)
      setUpdatedAt(Date.now())
      if (fresh.length) {
        setFlash((s) => new Set([...s, ...fresh]))
        setTimeout(
          () => setFlash((s) => new Set([...s].filter((id) => !fresh.includes(id)))),
          FLASH_MS
        )
      }
    } catch (e) {
      setError(message(e))
    } finally {
      inFlight.current = false
    }
  }, [])

  const refreshDependents = useCallback(async () => {
    try {
      setDependents(await window.camp.getDependents())
    } catch (e) {
      setError(message(e))
    }
  }, [])

  useEffect(() => {
    const first = setTimeout(refreshBoard, 0) // not called inline: avoids a setState during the effect
    const t = setInterval(refreshBoard, POLL_MS)
    return () => {
      clearTimeout(first)
      clearInterval(t)
    }
  }, [refreshBoard])

  useEffect(() => {
    const first = setTimeout(refreshDependents, 0)
    window.camp
      .getCamps()
      .then(setCamps)
      .catch((e) => {
        setCamps([])
        setError(message(e))
      })
    return () => clearTimeout(first)
  }, [refreshDependents])

  const signOut = async (): Promise<void> => {
    await window.camp.signOut().catch(() => undefined)
    onSignedOut()
  }

  return (
    <div className="shell">
      <header className="topbar">
        <h1 className="brand">
          <Logo size={34} />
          <span>MILAN</span>
        </h1>
        <nav aria-label="Sections">
          <button
            className={tab === 'board' ? 'tab active' : 'tab'}
            onClick={() => setTab('board')}
          >
            Missing board <span className="count">{board.length}</span>
          </button>
          <button
            className={tab === 'dependents' ? 'tab active' : 'tab'}
            onClick={() => setTab('dependents')}
          >
            All dependents
          </button>
        </nav>
        <span className="grow" />
        {updatedAt && <UpdatedAgo at={updatedAt} />}
        <span className="who">{session.email}</span>
        <button className="btn-outline" onClick={signOut}>
          Sign out
        </button>
      </header>

      {error && (
        <div role="alert" className="banner">
          {error}
        </div>
      )}

      {tab === 'board' ? (
        <BoardTab
          board={board}
          camps={camps}
          flash={flash}
          found={found}
          onDismiss={async (id) => {
            try {
              await window.camp.acknowledgeFound(id)
              setFound((f) => f.filter((r) => r.id !== id))
            } catch (e) {
              setError(message(e))
            }
          }}
        />
      ) : (
        <DependentsTab
          rows={dependents}
          board={board}
          camps={camps}
          onChanged={() => Promise.all([refreshDependents(), refreshBoard()]).then(() => undefined)}
        />
      )}
    </div>
  )
}

function UpdatedAgo({ at }: { at: number }): React.JSX.Element {
  const [now, setNow] = useState(at)
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [])
  const s = Math.max(0, Math.round((now - at) / 1000))
  return <span className="muted small">Updated {s} s ago</span>
}
