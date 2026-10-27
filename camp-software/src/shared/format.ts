/** A sighting older than this greys the row out. */
const STALE_AFTER_MS = 5 * 60 * 1000

/** Same format as SQL `beacon_label`: KM-000123. */
export function beaconLabel(beaconId: number): string {
  return 'KM-' + String(beaconId).padStart(6, '0')
}

/** `within ~18 m` (the circle radius: GPS accuracy + predicted BLE distance). */
export function radiusText(radiusM: number): string {
  return `within ~${Math.round(radiusM)} m`
}

export function coordText(lat: number, lon: number): string {
  return `${lat.toFixed(4)}, ${lon.toFixed(4)}`
}

/** `340 m` below 1 km, else `1.2 km` (same as the phone app). */
export function distanceText(meters: number): string {
  return meters < 1000 ? `${Math.round(meters)} m` : `${(meters / 1000).toFixed(1)} km`
}

export function timeAgo(iso: string, now: number = Date.now()): string {
  const s = Math.max(0, Math.round((now - new Date(iso).getTime()) / 1000))
  if (s < 10) return 'just now'
  if (s < 60) return `${s} s ago`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m} min ago`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h} h ago`
  return `${Math.floor(h / 24)} d ago`
}

export function isStale(seenAtIso: string, now: number = Date.now()): boolean {
  return now - new Date(seenAtIso).getTime() > STALE_AFTER_MS
}
