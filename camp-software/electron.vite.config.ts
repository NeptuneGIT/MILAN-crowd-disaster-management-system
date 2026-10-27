import { defineConfig, loadEnv } from 'electron-vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ command, mode }) => {
  // electron-builder leaves .env out of the packaged app, so a build bakes the Supabase URL and anon key
  // (both public by design) into the main process. In dev the main process still reads .env at runtime.
  const env = command === 'build' ? loadEnv(mode, process.cwd(), '') : {}
  const bake = (k: string): Record<string, string> =>
    env[k] ? { [`process.env.${k}`]: JSON.stringify(env[k]) } : {}
  return {
    main: { define: { ...bake('SUPABASE_URL'), ...bake('SUPABASE_ANON_KEY') } },
    preload: {},
    renderer: {
      plugins: [react()]
    }
  }
})
