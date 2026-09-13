# Controller Mouse

Use a gamepad as a real, system-wide mouse and keyboard on Windows.

Windows-only: a PowerShell helper process reads the controller via XInput and
drives the OS cursor/keystrokes through `user32.dll` and `SendKeys`. XInput
means Xbox controllers (wired, wireless, or Bluetooth) and anything that
emulates one (e.g. a PS4/PS5 controller through Steam Input or DS4Windows) —
plain DirectInput-only devices aren't read.

Everything — reading the controller, moving the cursor, watching for text
fields — happens in that one PowerShell process, independent of any window's
focus. That's deliberate: Electron's `navigator.getGamepads()` only reports
fresh data while its own window has OS focus, and a real click made another
app the foreground window, so an earlier version of this app would go dead
after the very first click. XInput has no such restriction.

Run it on Windows itself (not inside WSL) — a gamepad plugged into Windows
won't be visible to a WSL-hosted GUI app.

## Run it

```bash
npm install
npm start
```

A window opens with sensitivity/deadzone sliders and a live status readout.
Closing the window just hides it to the tray — use the tray icon to quit.

## Build a standalone .exe

```bash
npm run dist:win
```

Output lands in `release/`.

## Controls

| Input | Action |
|---|---|
| Left stick | Move cursor |
| Right trigger (RT) | Left click |
| Left trigger (LT) | Right click |
| Right bumper (RB) | Middle click |
| Right stick | Scroll |
| Start | Toggle on-screen keyboard |

### On-screen keyboard

Press Start (or the "Open on-screen keyboard" button in the window) to bring
up a controller-driven keyboard overlay, for typing without a physical
keyboard.

| Input | Action |
|---|---|
| D-pad / left stick | Move selection |
| A | Type the selected key |
| B or Start | Hide the keyboard |

The overlay never takes OS focus, so keystrokes go to whatever app is
actually focused underneath it.

### Auto-popup in text fields

With "Auto-open keyboard in text fields" on (the default), the keyboard pops
up by itself whenever a real text box gets focus anywhere on the desktop —
the same mechanism Windows' own touch keyboard uses (UI Automation), so it
follows normal keyboard/Tab focus, not just clicks. It hides itself again
once focus leaves that field. Dismissing it manually (B/Start) while still in
the same field keeps it dismissed until you tab away and back.

This relies on the app you're typing into properly exposing its text field
for accessibility — most native Windows apps and browsers do, but some
custom-rendered UIs (games, canvas-based editors) won't trigger it; use
Start to open the keyboard manually there. Turn the toggle off to disable
auto-popup entirely and rely on Start only.
