const { contextBridge, ipcRenderer } = require('electron');
const listen = (name, fn) => {
  if (typeof fn !== 'function') throw new Error('Expected an event handler.');
  const handler = (_event, value) => fn(value);
  ipcRenderer.on(name, handler);
  return () => ipcRenderer.removeListener(name, handler);
};
contextBridge.exposeInMainWorld(
  'droiddock',
  Object.freeze({
    state: () => ipcRenderer.invoke('dock:state'),
    deviceState: () => ipcRenderer.invoke('dock:device-state'),
    openDevice: (id) => ipcRenderer.invoke('dock:open-device', id),
    windowAction: (action) => ipcRenderer.invoke('dock:window-action', action),
    displayReady: (frame) => ipcRenderer.invoke('dock:display-ready', frame),
    displayFailed: (failure) => ipcRenderer.invoke('dock:display-failed', failure),
    displaySize: (size) => ipcRenderer.send('dock:display-size', size),
    catalog: () => ipcRenderer.invoke('dock:catalog'),
    review: (id) => ipcRenderer.invoke('dock:review', id),
    download: (token, licenses) => ipcRenderer.invoke('dock:download', { token, licenses }),
    cancelDownload: () => ipcRenderer.invoke('dock:cancel-download'),
    start: (id) => ipcRenderer.invoke('dock:start', id),
    stop: (id) => ipcRenderer.invoke('dock:stop', id),
    edit: (id, changes) => ipcRenderer.invoke('dock:edit', { id, changes }),
    delete: (id) => ipcRenderer.invoke('dock:delete', id),
    attach: (id) => ipcRenderer.invoke('dock:attach', id),
    detach: (id) => ipcRenderer.invoke('dock:detach', id),
    input: (id, action) => ipcRenderer.send('dock:input', { id, action }),
    videoAck: (sequence) => ipcRenderer.send('dock:video-ack', sequence),
    terminalPreview: () => ipcRenderer.invoke('dock:terminal-preview'),
    terminalInstall: () => ipcRenderer.invoke('dock:terminal-install'),
    terminalLater: () => ipcRenderer.invoke('dock:terminal-later'),
    installAPK: (id) => ipcRenderer.invoke('dock:install-apk', id),
    help: (topic) => ipcRenderer.invoke('dock:help', topic),
    onState: (fn) => listen('dock:state-changed', fn),
    onProgress: (fn) => listen('dock:progress', fn),
    onVideo: (fn) => listen('dock:video', fn),
    onError: (fn) => listen('dock:error', fn),
    onDisplayRecovered: (fn) => listen('dock:display-recovered', fn),
  }),
);
