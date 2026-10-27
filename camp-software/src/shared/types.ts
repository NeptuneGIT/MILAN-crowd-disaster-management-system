/** The columns of the `missing_board` view (supabase/schema.sql) that the screens use. */
export interface MissingBoardRow {
  child_id: string
  child_name: string
  beacon_label: string
  /** The sighting fields are null until the dependent has been seen since being marked missing. */
  lat: number | null
  lon: number | null
  seen_at: string | null
  accuracy_m: number | null
  rssi_dbm: number | null
  n_heard: number | null
  iqr: number | null
  camp_id: string | null
  camp_name: string | null
  distance_m: number | null
}

/** A board row plus the circle sizes the camp app works out from it. */
export interface BoardRow extends MissingBoardRow {
  /** BLE distance predicted from the signal metrics (10 m when there are none). */
  predicted_distance_m: number | null
  /** Outer circle: GPS `accuracy_m` + `predicted_distance_m`. */
  radius_m: number | null
}

/** A dependent for the "All dependents" tab. Never includes Aadhaar. */
export interface DependentRow {
  id: string
  name: string
  beacon_id: number
  beacon_label: string
  is_missing: boolean
  parent_name: string
  parent_phone: string | null
}

/** A dependent staff marked found whose Found notice is still waiting for the guardian. */
export interface FoundRow {
  id: string
  name: string
  beacon_label: string
  found_at: string
  camp_id: string | null
  parent_name: string
  parent_phone: string | null
}

export interface Camp {
  id: string
  name: string
  lat: number
  lon: number
}

export interface CampSession {
  email: string
}

/** What the preload exposes as `window.camp`. */
export interface CampApi {
  signIn(email: string, password: string): Promise<CampSession>
  signOut(): Promise<void>
  getSession(): Promise<CampSession | null>
  getBoard(): Promise<BoardRow[]>
  getDependents(): Promise<DependentRow[]>
  getCamps(): Promise<Camp[]>
  /** Found notices not yet confirmed by the guardian. */
  getFound(): Promise<FoundRow[]>
  /** Clears a Found notice for everyone: staff dismiss it when the guardian never confirms. */
  acknowledgeFound(dependentId: string): Promise<void>
  /** foundCampId: where the dependent was found (only used when missing is false). */
  setMissing(dependentId: string, missing: boolean, foundCampId?: string): Promise<void>
}
