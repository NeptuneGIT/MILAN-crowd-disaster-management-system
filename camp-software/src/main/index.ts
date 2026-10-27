import 'dotenv/config'
import { app, shell, BrowserWindow, ipcMain, session } from 'electron'
import { join } from 'path'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import * as db from './db'

function createWindow(): void {
  const mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 1000,
    minHeight: 640,
    show: false,
    autoHideMenuBar: true,
    title: 'MILAN Camp',
    icon: join(__dirname, '../../resources/icon.png'),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  })

  mainWindow.on('ready-to-show', () => mainWindow.show())

  // Only http(s) links leave the app (the OSM attribution link).
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url)
    return { action: 'deny' }
  })
  mainWindow.webContents.on('will-navigate', (e) => e.preventDefault())

  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

app.whenReady().then(() => {
  electronApp.setAppUserModelId('in.hackforsocial.lostfound.camp')

  // OpenStreetMap's tile policy requires an identifying User-Agent/Referer. A packaged Electron
  // app (file://) sends neither, so tiles can get blocked. Demo-scale use only.
  session.defaultSession.webRequest.onBeforeSendHeaders(
    { urls: ['https://tile.openstreetmap.org/*', 'https://*.tile.openstreetmap.org/*'] },
    (details, callback) => {
      details.requestHeaders['User-Agent'] = 'MilanCamp/1.0 (hackathon demo)'
      details.requestHeaders['Referer'] = 'https://github.com/lostfound-camp'
      callback({ requestHeaders: details.requestHeaders })
    }
  )

  app.on('browser-window-created', (_, window) => {
    optimizer.watchWindowShortcuts(window)
  })

  // One handler per CampApi method (src/shared/types.ts). Arguments come from the renderer, so
  // validate their types here rather than trusting them.
  ipcMain.handle('camp:signIn', (_e, email: unknown, password: unknown) => {
    if (typeof email !== 'string' || typeof password !== 'string') throw new Error('Bad arguments')
    return db.signIn(email, password)
  })
  ipcMain.handle('camp:signOut', () => db.signOut())
  ipcMain.handle('camp:getSession', () => db.getSession())
  ipcMain.handle('camp:getBoard', () => db.getBoard())
  ipcMain.handle('camp:getDependents', () => db.getDependents())
  ipcMain.handle('camp:getCamps', () => db.getCamps())
  ipcMain.handle('camp:getFound', () => db.getFound())
  ipcMain.handle('camp:acknowledgeFound', (_e, dependentId: unknown) => {
    if (typeof dependentId !== 'string') throw new Error('Bad arguments')
    return db.acknowledgeFound(dependentId)
  })
  ipcMain.handle(
    'camp:setMissing',
    (_e, dependentId: unknown, missing: unknown, campId: unknown) => {
      if (
        typeof dependentId !== 'string' ||
        typeof missing !== 'boolean' ||
        (campId !== undefined && typeof campId !== 'string')
      )
        throw new Error('Bad arguments')
      return db.setMissing(dependentId, missing, campId)
    }
  )

  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
