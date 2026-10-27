// One-command demo: opens the staff app and fakes a phone sighting every few seconds.
// Usage: npm run demo [-- <seconds between sightings, default 4>]. Ctrl+C stops both.
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'

if (!existsSync('.env')) {
  console.error('No .env found. Copy .env.example to .env and fill in SUPABASE_URL and SUPABASE_ANON_KEY.')
  process.exit(1)
}
const every = Number(process.argv[2]) || 4
const run = (cmd) => spawn(cmd, { stdio: 'inherit', shell: true })
const app = run('npm run dev')
const fake = run(`npm run fake-sighting -- ${every}`)
const stop = () => { app.kill(); fake.kill() }
app.on('exit', stop) // closing the staff app ends the demo
process.on('SIGINT', stop)
