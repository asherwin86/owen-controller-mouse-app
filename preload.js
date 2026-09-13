const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('controllerMouse', {
  setConfig: (key, value) => ipcRenderer.send('settings:set', key, value),
  toggleMode: () => ipcRenderer.send('mode:toggle'),
  onStatus: (callback) => {
    const listener = (_e, status) => callback(status);
    ipcRenderer.on('daemon-status', listener);
    return () => ipcRenderer.removeListener('daemon-status', listener);
  },
  onPadStatus: (callback) => {
    const listener = (_e, connected) => callback(connected);
    ipcRenderer.on('pad-status', listener);
    return () => ipcRenderer.removeListener('pad-status', listener);
  },
  onMode: (callback) => {
    const listener = (_e, mode) => callback(mode);
    ipcRenderer.on('mode', listener);
    return () => ipcRenderer.removeListener('mode', listener);
  },
  onSelection: (callback) => {
    const listener = (_e, sel) => callback(sel);
    ipcRenderer.on('selection', listener);
    return () => ipcRenderer.removeListener('selection', listener);
  },
});
