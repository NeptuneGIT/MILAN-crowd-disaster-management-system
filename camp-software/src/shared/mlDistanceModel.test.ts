import { describe, expect, it } from 'vitest'
import { FALLBACK_DISTANCE_M, predictBleDistance } from './mlDistanceModel'
import model from './ml/model_d90_exported.json'
import suite from './ml/test_suite.json'

describe('mlDistanceModel', () => {
  it('falls back to 10 m when signal is missing', () => {
    expect(FALLBACK_DISTANCE_M).toBe(10)
    expect(predictBleDistance(null, null, null)).toBe(10.0)
    expect(predictBleDistance(undefined, undefined, undefined)).toBe(10.0)
    expect(predictBleDistance(NaN, 10, 2)).toBe(10.0)
  })

  it('ships a consistent export', () => {
    expect(model.n_trees).toBe(model.trees.length)
    expect(model.features).toEqual(['median_rssi', 'n_heard', 'iqr'])
    expect(suite.baseline).toBe(model.baseline)
  })

  it("matches scikit-learn's predictions for every case in test_suite.json", () => {
    // Written by ml-model/export_model.py from the same model as the trees.
    expect(suite.test_cases.length).toBeGreaterThan(0)
    for (const { features, expected } of suite.test_cases) {
      const [rssi, nHeard, iqr] = features
      expect(predictBleDistance(rssi, nHeard, iqr)).toBeCloseTo(expected, 3)
    }
  })

  it('handles single advert and zero IQR cleanly', () => {
    expect(predictBleDistance(-45, 1, 0)).toBeLessThan(5.0)
    expect(predictBleDistance(-85, 1, 0)).toBeGreaterThan(20.0)
  })
})
