import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { beaconLabel } from '../shared/format'
import { predictBleDistance } from '../shared/mlDistanceModel'
import type {
  BoardRow,
  Camp,
  CampSession,
  DependentRow,
  FoundRow,
  MissingBoardRow
} from '../shared/types'

/**
 * The only place that talks to Supabase. Uses the public anon key plus the signed-in staff
 * member's session; row-level security (supabase/auth.sql) decides what is visible.
 * The session lives in memory only, so staff sign in on every launch.
 */
let client: SupabaseClient | null = null

function db(): SupabaseClient {
  if (!client) {
    const url = process.env.SUPABASE_URL
    const key = process.env.SUPABASE_ANON_KEY
    if (!url || !key) {
      throw new Error('SUPABASE_URL and SUPABASE_ANON_KEY are not set. Copy .env.example to .env.')
    }
    client = createClient(url, key, { auth: { persistSession: false } })
  }
  return client
}

export async function signIn(email: string, password: string): Promise<CampSession> {
  const { data, error } = await db().auth.signInWithPassword({ email: email.trim(), password })
  if (error)
    throw new Error(
      error.message === 'Invalid login credentials' ? 'Wrong email or password' : error.message
    )
  // app_metadata can only be set server-side, so this is trustworthy. RLS enforces it anyway;
  // this check just gives a clear message instead of an empty board.
  if (data.user.app_metadata?.role !== 'staff') {
    await db().auth.signOut()
    throw new Error('Not a staff account')
  }
  return { email: data.user.email ?? email }
}

export async function signOut(): Promise<void> {
  await db().auth.signOut()
}

export async function getSession(): Promise<CampSession | null> {
  const { data } = await db().auth.getSession()
  return data.session ? { email: data.session.user.email ?? '' } : null
}

function check<T>(res: { data: T | null; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message)
  return res.data as T
}

export async function getBoard(): Promise<BoardRow[]> {
  const rows = check(
    await db()
      .from('missing_board')
      .select(
        'child_id, child_name, beacon_label, lat, lon, seen_at, accuracy_m, rssi_dbm, n_heard, iqr, camp_id, camp_name, distance_m'
      )
      .order('missing_since') // fine to order by a column that isn't selected
  ) as MissingBoardRow[]

  return rows.map((r) => {
    // accuracy_m is null only when there is no sighting yet, so there is no circle to size.
    if (r.accuracy_m == null) return { ...r, predicted_distance_m: null, radius_m: null }
    // predictBleDistance falls back to 10 m when the phone sent no signal metrics.
    const predicted = predictBleDistance(r.rssi_dbm, r.n_heard, r.iqr)
    return { ...r, predicted_distance_m: predicted, radius_m: r.accuracy_m + predicted }
  })
}

export async function getCamps(): Promise<Camp[]> {
  return check(await db().from('camps').select('id, name, lat, lon').order('name'))
}

interface Parent {
  name: string
  phone: string | null
}

// PostgREST returns a single object for a many-to-one embed; be defensive about an array.
const parentOf = (p: Parent | Parent[] | null): Parent | undefined =>
  (Array.isArray(p) ? p[0] : p) ?? undefined

interface DependentJoin {
  id: string
  name: string
  beacon_id: number
  is_missing: boolean
  parents: Parent | Parent[] | null
}

/** Never selects aadhaar_number (and the database would refuse it anyway). */
export async function getDependents(): Promise<DependentRow[]> {
  const rows = check(
    await db()
      .from('children')
      .select('id, name, beacon_id, is_missing, parents(name, phone)')
      .order('name')
  ) as unknown as DependentJoin[]
  return rows.map((r) => {
    const p = parentOf(r.parents)
    return {
      id: r.id,
      name: r.name,
      beacon_id: r.beacon_id,
      beacon_label: beaconLabel(r.beacon_id),
      is_missing: r.is_missing,
      parent_name: p?.name ?? '',
      parent_phone: p?.phone ?? null
    }
  })
}

interface FoundJoin {
  id: string
  name: string
  beacon_id: number
  found_at: string
  found_camp_id: string | null
  parents: Parent | Parent[] | null
}

/** Found and not yet acknowledged: what the guardian's Found notice is still showing. */
export async function getFound(): Promise<FoundRow[]> {
  const rows = check(
    await db()
      .from('children')
      .select('id, name, beacon_id, found_at, found_camp_id, parents(name, phone)')
      .eq('is_missing', false)
      .not('found_at', 'is', null)
      .is('found_acknowledged_at', null)
      .order('found_at', { ascending: false })
  ) as unknown as FoundJoin[]
  return rows.map((r) => {
    const p = parentOf(r.parents)
    return {
      id: r.id,
      name: r.name,
      beacon_label: beaconLabel(r.beacon_id),
      found_at: r.found_at,
      camp_id: r.found_camp_id,
      parent_name: p?.name ?? '',
      parent_phone: p?.phone ?? null
    }
  })
}

/** Staff dismiss. Server-side acknowledge_found stamps the time; false just means it was already cleared. */
export async function acknowledgeFound(dependentId: string): Promise<void> {
  const { error } = await db().rpc('acknowledge_found', { p_child_id: dependentId })
  if (error) throw new Error(error.message)
}

/**
 * The single place is_missing changes. Fails loudly if RLS silently matched no row.
 * Marking found also records which camp (the database stamps found_at; marking missing clears both).
 */
export async function setMissing(
  dependentId: string,
  missing: boolean,
  foundCampId?: string
): Promise<void> {
  const patch = missing
    ? { is_missing: true }
    : { is_missing: false, found_camp_id: foundCampId ?? null }
  const rows = check(await db().from('children').update(patch).eq('id', dependentId).select('id'))
  if (!rows || rows.length !== 1) throw new Error('Not allowed')
}
