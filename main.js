const { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage, screen } = require('electron');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { autoUpdater } = require('electron-updater');

const UPDATE_CHECK_INTERVAL_MS = 4 * 60 * 60 * 1000; // this app stays running for weeks at a time in the tray

let win = null;
let keyboardWin = null;
let tray = null;
let daemon = null;
let daemonReady = false;
let daemonStatusMessage = 'Starting cursor helper…';
let quitting = false;
let mode = 'mouse'; // mirrors the daemon's authoritative mode, reported via its "MODE" lines
let padConnected = false;

function sendStatus(ok, message) {
  daemonReady = ok;
  daemonStatusMessage = message;
  win?.webContents.send('daemon-status', { ok, message });
}

function sendPadStatus() {
  win?.webContents.send('pad-status', padConnected);
}

function setMode(next) {
  mode = next;
  win?.webContents.send('mode', mode);
  keyboardWin?.webContents.send('mode', mode);
  if (mode === 'keyboard') keyboardWin?.showInactive();
  else keyboardWin?.hide();
}

function handleDaemonLine(line) {
  const [cmd, ...rest] = line.trim().split(' ');
  if (cmd === 'PAD') {
    padConnected = rest[0] === '1';
    sendPadStatus();
  } else if (cmd === 'MODE') {
    setMode(rest[0]);
  } else if (cmd === 'SEL') {
    const [page, row, col, shift] = rest.map(Number);
    keyboardWin?.webContents.send('selection', { page, row, col, shift: !!shift });
  }
}

let daemonSpawned = false;
let pendingLines = [];

function startDaemon() {
  if (process.platform !== 'win32') {
    sendStatus(false, 'Controller Mouse only drives the system cursor on Windows.');
    return;
  }
  const scriptPath = path.join(__dirname, 'cursor-daemon.ps1');
  daemon = spawn('powershell.exe', [
    '-NoProfile',
    '-NoLogo',
    '-ExecutionPolicy', 'Bypass',
    '-File', scriptPath,
  ], { stdio: ['pipe', 'pipe', 'pipe'] });

  let outBuf = '';
  daemon.stdout.on('data', (chunk) => {
    outBuf += chunk.toString();
    let nl;
    while ((nl = outBuf.indexOf('\n')) >= 0) {
      const line = outBuf.slice(0, nl).trim();
      outBuf = outBuf.slice(nl + 1);
      if (line) handleDaemonLine(line);
    }
  });

  daemon.on('spawn', () => {
    daemonSpawned = true;
    sendStatus(true, 'Connected to Windows cursor.');
    // PowerShell takes a moment to compile the Add-Type block, so anything
    // sent (e.g. saved sensitivity) before this point had to be queued —
    // otherwise a returning user's settings would silently vanish.
    for (const line of pendingLines) daemon.stdin.write(line + '\n');
    pendingLines = [];
  });
  daemon.on('error', (err) => sendStatus(false, `Could not start the cursor helper: ${err.message}`));
  daemon.on('exit', (code) => {
    daemon = null;
    daemonSpawned = false;
    padConnected = false;
    sendPadStatus();
    if (!quitting) sendStatus(false, `Cursor helper stopped unexpectedly (code ${code}).`);
  });
  daemon.stderr.on('data', (chunk) => console.error('[cursor-daemon]', chunk.toString()));
}

function sendToDaemon(line) {
  if (!daemonSpawned || !daemon || !daemon.stdin.writable) {
    pendingLines.push(line);
    return;
  }
  daemon.stdin.write(line + '\n');
}

function createWindow() {
  win = new BrowserWindow({
    width: 420,
    height: 560,
    resizable: false,
    backgroundColor: '#12141c',
    autoHideMenuBar: true,
    icon: path.join(__dirname, 'assets', 'icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
    },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.on('did-finish-load', () => {
    // Resend the real last-known status, not a boolean-derived guess — the
    // daemon can spawn then crash before this window even finishes loading,
    // and re-deriving from daemonReady alone would mislabel that as "still
    // starting" forever instead of showing the actual error.
    sendStatus(daemonReady, daemonStatusMessage);
    sendPadStatus();
    win.webContents.send('mode', mode);
  });

  win.on('close', (e) => {
    if (quitting) return;
    e.preventDefault();
    win.hide();
  });
}

function createKeyboardWindow() {
  const display = screen.getPrimaryDisplay();
  const width = Math.min(900, Math.round(display.workAreaSize.width * 0.8));
  const height = 320;
  keyboardWin = new BrowserWindow({
    width,
    height,
    x: Math.round(display.workArea.x + (display.workAreaSize.width - width) / 2),
    y: Math.round(display.workArea.y + display.workAreaSize.height - height - 24),
    frame: false,
    transparent: true,
    hasShadow: false,
    resizable: false,
    movable: false,
    // Never take OS focus: the overlay must not steal keystrokes away from
    // whatever app the user is actually typing into.
    focusable: false,
    skipTaskbar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
    },
  });
  keyboardWin.setAlwaysOnTop(true, 'screen-saver');
  keyboardWin.loadFile(path.join(__dirname, 'renderer', 'keyboard.html'));
  keyboardWin.webContents.on('did-finish-load', () => keyboardWin.webContents.send('mode', mode));
}

function createTray() {
  const icon = nativeImage.createFromPath(path.join(__dirname, 'assets', 'tray.png'));
  tray = new Tray(icon);
  tray.setToolTip('Controller Mouse');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Show window', click: () => win?.show() },
    { label: 'Check for updates', click: () => checkForUpdates() },
    { type: 'separator' },
    { label: 'Quit', click: () => { quitting = true; app.quit(); } },
  ]));
  tray.on('click', () => win?.show());
}

function checkForUpdates() {
  // Failing offline is expected and must not interrupt mouse/keyboard control,
  // so log-and-ignore rather than throw.
  autoUpdater.checkForUpdatesAndNotify().catch((e) => console.error('[updater]', e));
}

ipcMain.on('settings:set', (_e, key, value) => sendToDaemon(`SET ${key} ${value}`));
ipcMain.on('mode:toggle', () => sendToDaemon('TOGGLEMODE'));

app.whenReady().then(() => {
  createWindow();
  createKeyboardWindow();
  createTray();
  startDaemon();
  checkForUpdates();
  setInterval(checkForUpdates, UPDATE_CHECK_INTERVAL_MS);

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
    else win?.show();
  });
});

app.on('before-quit', () => { quitting = true; });
app.on('window-all-closed', (e) => {
  // Background utility: stay alive in the tray until Quit is chosen.
  if (!quitting) e.preventDefault();
});
app.on('will-quit', () => {
  daemon?.kill();
});
