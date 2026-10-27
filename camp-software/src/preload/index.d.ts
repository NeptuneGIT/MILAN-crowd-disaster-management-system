import type { CampApi } from '../shared/types'

declare global {
  interface Window {
    camp: CampApi
  }
}
