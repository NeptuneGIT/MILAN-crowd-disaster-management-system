import { useEffect, useRef } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { Circle, MapContainer, Marker, TileLayer, Tooltip, useMap } from 'react-leaflet'
import type { BoardRow, Camp } from '../../shared/types'
import { isStale } from '../../shared/format'

export interface Focus {
  id: string
  n: number
}

// Built from static markup only (no data in the HTML string). A divIcon avoids Leaflet's default
// marker PNGs, which the bundler would otherwise need to resolve.
const campIcon = L.divIcon({ className: 'camp-pin', html: '<span></span>', iconSize: [14, 14] })

const FALLBACK_CENTER: [number, number] = [28.9469, 77.1014] // Ashoka University, matches seed.sql

/** Pans only when the user clicks a row. New sightings never move the map. */
function FocusDependent({ focus, board }: { focus: Focus | null; board: BoardRow[] }): null {
  const map = useMap()
  const latest = useRef(board)
  useEffect(() => {
    latest.current = board
  })
  useEffect(() => {
    if (!focus) return
    const r = latest.current.find((b) => b.child_id === focus.id)
    if (!r || r.lat == null || r.lon == null || r.radius_m == null) return
    map.fitBounds(L.latLng(r.lat, r.lon).toBounds(r.radius_m * 2.5), { maxZoom: 19 })
  }, [focus, map])
  return null
}

export default function MapView({
  camps,
  board,
  focus
}: {
  camps: Camp[]
  board: BoardRow[]
  focus: Focus | null
}): React.JSX.Element {
  // Initial view fits all camps. MapContainer reads `bounds`/`center` once, so later
  // updates (new camps, polling) never move the map.
  const view =
    camps.length > 0
      ? { bounds: L.latLngBounds(camps.map((c) => [c.lat, c.lon] as [number, number])).pad(0.3) }
      : { center: FALLBACK_CENTER, zoom: 15 }

  return (
    <MapContainer {...view} maxZoom={19} className="map">
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap</a> contributors'
        url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        maxZoom={19}
      />
      {camps.map((c) => (
        <Marker key={c.id} position={[c.lat, c.lon]} icon={campIcon} keyboard={false}>
          <Tooltip permanent direction="right" offset={[8, 0]} className="camp-label">
            {c.name}
          </Tooltip>
        </Marker>
      ))}
      {board.flatMap((r) => {
        if (r.lat == null || r.lon == null || r.radius_m == null || !r.seen_at) return []
        const stale = isStale(r.seen_at)
        const color = stale ? '#6b6258' : '#8e2417'
        const hasInner = r.accuracy_m != null && r.accuracy_m > 0 && r.accuracy_m < r.radius_m

        const circles: React.JSX.Element[] = []

        // Inner circle: Phone GPS accuracy
        if (hasInner) {
          circles.push(
            <Circle
              key={`${r.child_id}-gps`}
              center={[r.lat, r.lon]}
              radius={r.accuracy_m as number}
              pathOptions={{
                color,
                fillColor: color,
                fillOpacity: 0.08,
                weight: 1.5,
                dashArray: '4 4'
              }}
            />
          )
        }

        // Outer circle: Total detection area (GPS accuracy + ML predicted distance)
        circles.push(
          <Circle
            key={r.child_id}
            center={[r.lat, r.lon]}
            radius={r.radius_m}
            pathOptions={{
              color,
              fillColor: color,
              fillOpacity: 0.14,
              weight: 2.5,
              dashArray: stale ? '6 6' : undefined
            }}
          >
            <Tooltip
              permanent
              direction="top"
              className={stale ? 'dependent-label stale' : 'dependent-label'}
            >
              {r.child_name}
            </Tooltip>
          </Circle>
        )

        return circles
      })}
      <FocusDependent focus={focus} board={board} />
    </MapContainer>
  )
}
