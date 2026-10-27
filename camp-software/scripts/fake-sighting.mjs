// Fakes a phone's BLE sighting of a random missing dependent, near a random camp, using the same
// anon RPCs the phone app uses. Usage: npm run fake-sighting [-- <repeat every N seconds>]
const { SUPABASE_URL: url, SUPABASE_ANON_KEY: key } = process.env
if (!url || !key)
  throw new Error('Set SUPABASE_URL / SUPABASE_ANON_KEY (run via npm run fake-sighting)')

const rpc = async (fn, body) => {
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  })
  if (!res.ok) throw new Error(`${fn}: ${res.status} ${await res.text()}`)
  return res.status === 204 ? null : res.json().catch(() => null)
}
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const jitter = (m) => ((Math.random() * 2 - 1) * m) / 111_320 // metres -> degrees (~, fine near equator)

async function once() {
  const eids = await rpc('get_missing_eids', {}) // rotating IDs; any of them is valid for the current time window
  if (!eids?.length)
    return console.log('No dependent is marked missing. Mark one in the All dependents tab first.')
  const camps = await (
    await fetch(`${url}/rest/v1/camps?select=name,lat,lon`, {
      headers: { apikey: key, Authorization: `Bearer ${key}` }
    })
  ).json()
  const camp = pick(camps)
  const rssi = Math.round(-45 - Math.random() * 45) // -45 to -90 dBm
  const nHeard = Math.floor(1 + Math.random() * 20)
  const iqr = Math.round(Math.random() * 6 * 10) / 10
  const s = {
    p_eid: pick(eids),
    p_lat: camp.lat + jitter(150),
    p_lon: camp.lon + jitter(150),
    p_accuracy_m: Math.round(5 + Math.random() * 25),
    p_reporter: `fake-${Math.random().toString(36).slice(2, 8)}`, // fresh id so the 5 s de-dupe never drops it
    p_rssi: rssi,
    p_n_heard: nHeard,
    p_iqr: iqr
  }
  await rpc('report_sighting', s)
  console.log(
    `band ${s.p_eid} near ${camp.name} (${s.p_lat.toFixed(5)}, ${s.p_lon.toFixed(5)}, GPS ±${s.p_accuracy_m} m, RSSI ${rssi} dBm, ${nHeard} adv, IQR ${iqr})`
  )
}

const every = Number(process.argv[2])
await once()
if (every > 0) setInterval(() => once().catch(console.error), every * 1000)
