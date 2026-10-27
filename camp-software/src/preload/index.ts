import { contextBridge, ipcRenderer } from 'electron'
import type { CampApi } from '../shared/types'

// ipcRenderer.invoke wraps errors as "Error invoking remote method 'x': Error: message".
// Strip that so the UI can show the message as is.
async function call<T>(channel: string, ...args: unknown[]): Promise<T> {
  try {
    return (await ipcRenderer.invoke(channel, ...args)) as T
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    throw new Error(msg.replace(/^Error invoking remote method '[^']+': (Error: )?/, ''))
  }
}

const camp: CampApi = {
  signIn: (email, password) => call('camp:signIn', email, password),
  signOut: () => call('camp:signOut'),
  getSession: () => call('camp:getSession'),
  getBoard: () => call('camp:getBoard'),
  getDependents: () => call('camp:getDependents'),
  getCamps: () => call('camp:getCamps'),
  getFound: () => call('camp:getFound'),
  acknowledgeFound: (dependentId) => call('camp:acknowledgeFound', dependentId),
  setMissing: (dependentId, missing, foundCampId) =>
    call('camp:setMissing', dependentId, missing, foundCampId)
}

// Sandboxed preload: only `electron` can be imported here, so no @electron-toolkit/preload.
contextBridge.exposeInMainWorld('camp', camp)
