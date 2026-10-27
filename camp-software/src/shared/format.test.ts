import { describe, expect, it } from 'vitest'
import { beaconLabel, coordText, distanceText, isStale, radiusText, timeAgo } from './format'

const NOW = Date.parse('2026-10-14T12:00:00Z')
const ago = (s: number): string => new Date(NOW - s * 1000).toISOString()

describe('format helpers', () => {
  it('beacon label matches SQL beacon_label', () => {
    expect(beaconLabel(1)).toBe('KM-000001')
    expect(beaconLabel(123)).toBe('KM-000123')
    expect(beaconLabel(2147483647)).toBe('KM-2147483647')
  })

  it('radius text', () => {
    expect(radiusText(18)).toBe('within ~18 m')
    expect(radiusText(18.4)).toBe('within ~18 m')
    expect(radiusText(18.6)).toBe('within ~19 m')
  })

  it('coordinates', () => {
    expect(coordText(25.43611, 81.84659)).toBe('25.4361, 81.8466')
  })

  it('distance text', () => {
    expect(distanceText(340)).toBe('340 m')
    expect(distanceText(999)).toBe('999 m')
    expect(distanceText(1000)).toBe('1.0 km')
    expect(distanceText(1234)).toBe('1.2 km')
  })

  it('time ago', () => {
    expect(timeAgo(ago(3), NOW)).toBe('just now')
    expect(timeAgo(ago(45), NOW)).toBe('45 s ago')
    expect(timeAgo(ago(120), NOW)).toBe('2 min ago')
    expect(timeAgo(ago(7200), NOW)).toBe('2 h ago')
    expect(timeAgo(ago(2 * 86400), NOW)).toBe('2 d ago')
    expect(timeAgo(ago(-30), NOW)).toBe('just now') // clock skew: never negative
  })

  it('stale after 5 minutes', () => {
    expect(isStale(ago(299), NOW)).toBe(false)
    expect(isStale(ago(300), NOW)).toBe(false)
    expect(isStale(ago(301), NOW)).toBe(true)
  })
})
