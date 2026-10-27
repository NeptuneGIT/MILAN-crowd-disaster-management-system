/**
 * Signal-to-distance model: a gradient-boosted quantile regression (d90) fitted in ml-model/.
 * The trees are data in ml/model_d90_exported.json (written by ml-model/export_model.py); this file
 * only walks them. To ship a retrained model, replace the two JSON files in ml/ and run `npm test`.
 *
 * Inputs:
 * - median_rssi: median signal strength heard from the beacon in the upload window (dBm)
 * - n_heard: number of adverts heard from this beacon in the window
 * - iqr: interquartile range (spread) of RSSI readings in the window
 *
 * Output: d90, the distance in metres the beacon is within with 90% confidence.
 */
import model from './ml/model_d90_exported.json'

interface TreeNode {
  value: number
  feature_idx: number
  threshold: number
  left: number
  right: number
  is_leaf: boolean
}

const { baseline, trees } = model as { baseline: number; trees: TreeNode[][] }

/** Used when a sighting carries no signal data. */
export const FALLBACK_DISTANCE_M = 10

// Physical bounds on the prediction.
const MIN_DISTANCE_M = 0.5
const MAX_DISTANCE_M = 35

/** Predicts the 90th percentile upper-bound distance (d90) in metres. */
export function predictBleDistance(
  medianRssi: number | null | undefined,
  nHeard: number | null | undefined,
  iqr: number | null | undefined
): number {
  if (medianRssi == null || !Number.isFinite(medianRssi)) return FALLBACK_DISTANCE_M

  const count = nHeard != null && Number.isFinite(nHeard) && nHeard > 0 ? nHeard : 1
  const spread = iqr != null && Number.isFinite(iqr) && iqr >= 0 ? iqr : 0
  const features = [medianRssi, count, spread] // order = "features" in the JSON

  let pred = baseline
  for (const nodes of trees) {
    let node = nodes[0]
    while (!node.is_leaf) {
      node = nodes[features[node.feature_idx] <= node.threshold ? node.left : node.right]
    }
    pred += node.value
  }
  return Math.max(MIN_DISTANCE_M, Math.min(MAX_DISTANCE_M, pred))
}
