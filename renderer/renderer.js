const els = {
  daemonDot: document.getElementById('daemon-dot'),
  daemonText: document.getElementById('daemon-text'),
  padDot: document.getElementById('pad-dot'),
  padText: document.getElementById('pad-text'),
  enable: document.getElementById('enable'),
  autokeyboard: document.getElementById('autokeyboard'),
  speed: document.getElementById('speed'),
  speedVal: document.getElementById('speed-val'),
  deadzone: document.getElementById('deadzone'),
  deadzoneVal: document.getElementById('deadzone-val'),
  scroll: document.getElementById('scroll'),
  scrollVal: document.getElementById('scroll-val'),
};

const DEFAULTS = { speed: 1, deadzone: 0.15, scroll: 1, enabled: true, autokeyboard: true };
const BOOL_KEYS = new Set(['enabled', 'autokeyboard']);

function loadSettings() {
  const s = { ...DEFAULTS };
  try {
    for (const key of Object.keys(DEFAULTS)) {
      const raw = localStorage.getItem(`cm.${key}`);
      if (raw === null) continue;
      s[key] = BOOL_KEYS.has(key) ? raw === 'true' : parseFloat(raw);
    }
  } catch {
    // localStorage unavailable (e.g. storage disabled) — defaults are fine.
  }
  return s;
}
function saveSetting(key, value) {
  try { localStorage.setItem(`cm.${key}`, String(value)); } catch { /* ignore */ }
}

const settings = loadSettings();

function applySettingsToUI() {
  els.enable.checked = settings.enabled;
  els.autokeyboard.checked = settings.autokeyboard;
  els.speed.value = String(settings.speed);
  els.deadzone.value = String(settings.deadzone);
  els.scroll.value = String(settings.scroll);
  els.speedVal.textContent = `${settings.speed.toFixed(2)}x`;
  els.deadzoneVal.textContent = settings.deadzone.toFixed(2);
  els.scrollVal.textContent = `${settings.scroll.toFixed(2)}x`;
}
applySettingsToUI();

// Push every current setting to the daemon on load, since it starts with its
// own defaults and has no memory of what was picked last session.
function sendAllConfig() {
  window.controllerMouse.setConfig('enabled', settings.enabled ? 1 : 0);
  window.controllerMouse.setConfig('autokeyboard', settings.autokeyboard ? 1 : 0);
  window.controllerMouse.setConfig('speed', settings.speed);
  window.controllerMouse.setConfig('deadzone', settings.deadzone);
  window.controllerMouse.setConfig('scroll', settings.scroll);
}
sendAllConfig();

els.enable.addEventListener('change', () => {
  settings.enabled = els.enable.checked;
  saveSetting('enabled', settings.enabled);
  window.controllerMouse.setConfig('enabled', settings.enabled ? 1 : 0);
});
els.autokeyboard.addEventListener('change', () => {
  settings.autokeyboard = els.autokeyboard.checked;
  saveSetting('autokeyboard', settings.autokeyboard);
  window.controllerMouse.setConfig('autokeyboard', settings.autokeyboard ? 1 : 0);
});
els.speed.addEventListener('input', () => {
  settings.speed = parseFloat(els.speed.value);
  els.speedVal.textContent = `${settings.speed.toFixed(2)}x`;
  saveSetting('speed', settings.speed);
  window.controllerMouse.setConfig('speed', settings.speed);
});
els.deadzone.addEventListener('input', () => {
  settings.deadzone = parseFloat(els.deadzone.value);
  els.deadzoneVal.textContent = settings.deadzone.toFixed(2);
  saveSetting('deadzone', settings.deadzone);
  window.controllerMouse.setConfig('deadzone', settings.deadzone);
});
els.scroll.addEventListener('input', () => {
  settings.scroll = parseFloat(els.scroll.value);
  els.scrollVal.textContent = `${settings.scroll.toFixed(2)}x`;
  saveSetting('scroll', settings.scroll);
  window.controllerMouse.setConfig('scroll', settings.scroll);
});

window.controllerMouse.onStatus(({ ok, message }) => {
  els.daemonDot.className = `dot ${ok ? 'good' : 'bad'}`;
  els.daemonText.textContent = message;
  // The daemon only starts reporting pad state once it's actually running.
  if (!ok) {
    els.padDot.className = 'dot';
    els.padText.textContent = 'No controller detected';
  }
});
window.controllerMouse.onPadStatus((connected) => {
  els.padDot.className = `dot ${connected ? 'good' : ''}`;
  els.padText.textContent = connected ? 'Controller connected' : 'No controller detected';
});

const keyboardBtn = document.getElementById('open-keyboard');
keyboardBtn.addEventListener('click', () => window.controllerMouse.toggleMode());
window.controllerMouse.onMode((mode) => {
  keyboardBtn.textContent = mode === 'keyboard' ? 'Close on-screen keyboard' : 'Open on-screen keyboard';
});
