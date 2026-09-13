# Long-lived helper process: owns the whole control loop, from reading the
# controller to moving the cursor and typing keys.
#
# Everything lives in one process, on one thread, polling at ~60Hz, because
# Chromium's Gamepad API (which an Electron renderer would otherwise use)
# only reports fresh state while its window has OS focus — and a real click
# sent to another app immediately steals that focus. XInput has no such
# restriction: it works no matter which window is focused, which is the
# whole point of a system-wide controller mouse.
#
# Config changes and mode toggles arrive from the Electron app as one
# command per line on stdin; this script reports pad-connected/mode/on-screen
# keyboard selection changes back on stdout for the app to display.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class CMNative {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
    [DllImport("xinput1_4.dll")] public static extern uint XInputGetState(uint dwUserIndex, ref XINPUT_STATE pState);

    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_GAMEPAD {
        public ushort wButtons;
        public byte bLeftTrigger;
        public byte bRightTrigger;
        public short sThumbLX;
        public short sThumbLY;
        public short sThumbRX;
        public short sThumbRY;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_STATE {
        public uint dwPacketNumber;
        public XINPUT_GAMEPAD Gamepad;
    }
}
"@

# ---- mouse_event / wheel flags -------------------------------------------------
$LEFTDOWN = 0x0002; $LEFTUP = 0x0004
$RIGHTDOWN = 0x0008; $RIGHTUP = 0x0010
$MIDDLEDOWN = 0x0020; $MIDDLEUP = 0x0040
$WHEEL = 0x0800; $HWHEEL = 0x1000
$WHEEL_DELTA = 120

# ---- XInput button bitmask + trigger threshold ---------------------------------
$BTN_DPAD_UP = 0x0001; $BTN_DPAD_DOWN = 0x0002; $BTN_DPAD_LEFT = 0x0004; $BTN_DPAD_RIGHT = 0x0008
$BTN_START = 0x0010; $BTN_BACK = 0x0020
$BTN_RSHOULDER = 0x0200
$BTN_A = 0x1000; $BTN_B = 0x2000
$TRIGGER_THRESHOLD = 30
$STICK_NAV_THRESHOLD = 0.5

# SendKeys treats these as control characters and needs them wrapped in braces
# to type the literal character (see the on-screen keyboard's symbol page).
$SENDKEYS_METACHARS = '+^%~(){}'
function Send-Literal-Char([char]$ch) {
    if ($SENDKEYS_METACHARS.IndexOf($ch) -ge 0) {
        [System.Windows.Forms.SendKeys]::SendWait("{$ch}")
    } else {
        [System.Windows.Forms.SendKeys]::SendWait([string]$ch)
    }
}

# ---- on-screen keyboard layout (mirrors renderer/keyboard.js, which renders it) -
function K([string]$type, [string]$value) {
    return [PSCustomObject]@{ Type = $type; Value = $value }
}
function CharKeys([string]$s) {
    return $s.ToCharArray() | ForEach-Object { K 'char' ([string]$_) }
}

# Each row is wrapped with a leading unary comma: without it, PowerShell
# flattens a statement's array result into the enclosing @() instead of
# nesting it, which would merge every row into one long row.
$MainRows = @(
    ,(@(CharKeys '1234567890') + @(K 'backspace' 'Bksp'))
    ,(CharKeys 'qwertyuiop')
    ,(@(CharKeys 'asdfghjkl') + @(K 'enter' 'Enter'))
    ,(@(K 'shift' 'Shift') + @(CharKeys 'zxcvbnm') + @(K 'char' ',') + @(K 'char' '.'))
    ,(@((K 'page' '123'), (K 'left' 'Left'), (K 'space' 'Space'), (K 'right' 'Right'), (K 'hide' 'Hide')))
)
$SymbolRows = @(
    ,(@(CharKeys '!@#$%^&*()') + @(K 'backspace' 'Bksp'))
    ,(CharKeys '-_=+[]{}\|')
    ,(@(CharKeys ";:'`",.<>/?") + @(K 'enter' 'Enter'))
    ,(@((K 'page' 'ABC'), (K 'left' 'Left'), (K 'space' 'Space'), (K 'right' 'Right'), (K 'hide' 'Hide')))
)
function Get-Rows([int]$page) { if ($page -eq 0) { return $MainRows } else { return $SymbolRows } }

# ---- mutable state --------------------------------------------------------------
$cfg = @{ enabled = $true; speed = 1.0; deadzone = 0.15; scroll = 1.0; autokeyboard = $true }
$mode = 'mouse'
$kb = @{ page = 0; row = 0; col = 0; shift = $false }
$padConnected = $false
$lastButtons = @{ left = $false; right = $false; middle = $false }
$lastStart = $false; $lastA = $false; $lastB = $false
$moveRemX = 0.0; $moveRemY = 0.0
$scrollRemX = 0.0; $scrollRemY = 0.0
$navRepeat = @{
    up    = @{ held = $false; nextAt = 0.0 }
    down  = @{ held = $false; nextAt = 0.0 }
    left  = @{ held = $false; nextAt = 0.0 }
    right = @{ held = $false; nextAt = 0.0 }
}

# ---- auto-popup: watch what has OS focus system-wide via UI Automation, the same
# mechanism Windows' own touch keyboard uses to know when a text box is focused. -
# Polled rather than event-driven: a plain ControlType.Document also matches the
# main viewport of any Chromium/Electron app (confirmed live — a focused Electron
# window's root reports Document too), so a real editable check is needed, not
# just "did focus change." Edit is trusted outright; Document/ComboBox only count
# if they carry a non-read-only ValuePattern, which is what excludes that viewport
# while still catching contenteditable-style rich text areas.
$isTextFocused = $false
$autoShown = $false      # keyboard is visible because we opened it, not the user
$autoSuppressed = $false # user dismissed it while still in this text box; don't reopen
$prevTextFocused = $false
$FOCUS_POLL_INTERVAL = 0.25
$nextFocusPollAt = 0.0

function Test-IsTextElement($el) {
    if ($null -eq $el) { return $false }
    $ct = $el.Current.ControlType
    if ($ct -eq [System.Windows.Automation.ControlType]::Edit) { return $true }
    if ($ct -eq [System.Windows.Automation.ControlType]::ComboBox -or $ct -eq [System.Windows.Automation.ControlType]::Document) {
        $vp = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
            return -not ($vp -as [System.Windows.Automation.ValuePattern]).Current.IsReadOnly
        }
        return $false
    }
    return $false
}

function Clamp-Selection {
    $rows = Get-Rows $kb.page
    if ($kb.row -ge $rows.Length) { $kb.row = $rows.Length - 1 }
    if ($kb.row -lt 0) { $kb.row = 0 }
    $row = $rows[$kb.row]
    if ($kb.col -ge $row.Length) { $kb.col = $row.Length - 1 }
    if ($kb.col -lt 0) { $kb.col = 0 }
}
function Report-Selection {
    Clamp-Selection
    Write-Output "SEL $($kb.page) $($kb.row) $($kb.col) $([int]$kb.shift)"
}
function Set-Mode([string]$next, [switch]$Auto) {
    if (-not $Auto) {
        # A manual toggle always takes precedence over the auto-popup logic:
        # dismissing the keyboard by hand while still in the same text box
        # must not have it immediately pop back up on the next tick.
        $script:autoShown = $false
        if ($next -eq 'mouse' -and $script:mode -eq 'keyboard' -and $script:isTextFocused) {
            $script:autoSuppressed = $true
        }
    }
    $script:mode = $next
    if ($next -eq 'keyboard') {
        $script:kb.shift = $false
        Report-Selection
    }
    Write-Output "MODE $next"
}

function Move-Row([int]$delta) {
    $rows = Get-Rows $kb.page
    $curRow = $rows[$kb.row]
    $frac = if ($curRow.Length -gt 1) { $kb.col / [double]($curRow.Length - 1) } else { 0 }
    $kb.row = [Math]::Max(0, [Math]::Min($rows.Length - 1, $kb.row + $delta))
    $newRow = $rows[$kb.row]
    $kb.col = [Math]::Round($frac * ($newRow.Length - 1))
    Report-Selection
}
function Move-Col([int]$delta) {
    $row = (Get-Rows $kb.page)[$kb.row]
    $kb.col = [Math]::Max(0, [Math]::Min($row.Length - 1, $kb.col + $delta))
    Report-Selection
}
function Activate-Key {
    $key = (Get-Rows $kb.page)[$kb.row][$kb.col]
    switch ($key.Type) {
        'char' {
            $ch = [string]$key.Value
            if ($kb.shift -and $ch -match '[a-z]') { $ch = $ch.ToUpper(); $kb.shift = $false }
            Send-Literal-Char ([char]$ch)
        }
        'space'     { Send-Literal-Char ' ' }
        'backspace' { [System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE}') }
        'enter'     { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
        'left'      { [System.Windows.Forms.SendKeys]::SendWait('{LEFT}') }
        'right'     { [System.Windows.Forms.SendKeys]::SendWait('{RIGHT}') }
        'shift'     { $kb.shift = -not $kb.shift }
        'page'      { $kb.page = 1 - $kb.page; $kb.row = 0; $kb.col = 0 }
        'hide'      { Set-Mode 'mouse'; return }
    }
    Report-Selection
}

function Set-MouseButton([string]$name, [bool]$pressed) {
    if ($lastButtons[$name] -eq $pressed) { return }
    $lastButtons[$name] = $pressed
    switch ($name) {
        'left'   { [CMNative]::mouse_event($(if ($pressed) { $LEFTDOWN } else { $LEFTUP }), 0, 0, 0, [UIntPtr]::Zero) }
        'right'  { [CMNative]::mouse_event($(if ($pressed) { $RIGHTDOWN } else { $RIGHTUP }), 0, 0, 0, [UIntPtr]::Zero) }
        'middle' { [CMNative]::mouse_event($(if ($pressed) { $MIDDLEDOWN } else { $MIDDLEUP }), 0, 0, 0, [UIntPtr]::Zero) }
    }
}
function Release-AllButtons {
    foreach ($name in @('left', 'right', 'middle')) { Set-MouseButton $name $false }
}

# Radial deadzone: direction comes straight from the raw stick vector,
# magnitude is remapped from [deadzone, 1] to [0, 1] and curved so small
# pushes give fine control and full deflection is fast.
function Get-RadialCurve([double]$x, [double]$y, [double]$deadzone, [double]$exponent) {
    $mag = [Math]::Sqrt($x * $x + $y * $y)
    if ($mag -le $deadzone -or $mag -eq 0) { return @{ x = 0.0; y = 0.0; mag = 0.0 } }
    $t = [Math]::Min(($mag - $deadzone) / (1 - $deadzone), 1.0)
    return @{ x = $x / $mag; y = $y / $mag; mag = [Math]::Pow($t, $exponent) }
}
function Get-AxisCurve([double]$raw, [double]$deadzone, [double]$exponent) {
    $mag = [Math]::Abs($raw)
    if ($mag -le $deadzone) { return 0.0 }
    $t = [Math]::Min(($mag - $deadzone) / (1 - $deadzone), 1.0)
    $sign = if ($raw -lt 0) { -1.0 } else { 1.0 }
    return $sign * [Math]::Pow($t, $exponent)
}

function Process-Command([string]$line) {
    $parts = $line.Trim().Split(' ')
    if ($parts.Length -eq 0 -or $parts[0] -eq '') { return }
    switch ($parts[0]) {
        'SET' {
            $key = $parts[1].ToLower()
            if ($key -eq 'enabled' -or $key -eq 'autokeyboard') { $cfg[$key] = $parts[2] -eq '1' }
            elseif ($cfg.ContainsKey($key)) { $cfg[$key] = [double]$parts[2] }
        }
        'TOGGLEMODE' { Set-Mode $(if ($mode -eq 'mouse') { 'keyboard' } else { 'mouse' }) }
    }
}

# ---- non-blocking stdin: poll a pending ReadAsync instead of a blocking ReadLine,
# so this loop can also run the ~60Hz controller poll on the same thread. -------
$stdin = [Console]::OpenStandardInput()
$readBuf = New-Object byte[] 512
$readTask = $stdin.ReadAsync($readBuf, 0, $readBuf.Length)
$pendingText = ''
function Drain-Stdin {
    # A single malformed line, or the pipe going away, must never take down
    # the whole control loop — that would silently freeze the real cursor.
    try {
        while ($script:readTask.IsCompleted) {
            $n = $script:readTask.Result
            if ($n -le 0) { return } # stdin closed
            $script:pendingText += [System.Text.Encoding]::UTF8.GetString($script:readBuf, 0, $n)
            while (($nl = $script:pendingText.IndexOf("`n")) -ge 0) {
                $line = $script:pendingText.Substring(0, $nl).TrimEnd("`r")
                try { Process-Command $line } catch { [Console]::Error.WriteLine("command error: $_") }
                $script:pendingText = $script:pendingText.Substring($nl + 1)
            }
            $script:readTask = $script:stdin.ReadAsync($script:readBuf, 0, $script:readBuf.Length)
        }
    } catch {
        [Console]::Error.WriteLine("stdin error: $_")
    }
}

# ---- digital-repeat helper for on-screen-keyboard navigation -------------------
$REPEAT_DELAY = 0.38; $REPEAT_RATE = 0.13
function Poll-Repeat([string]$dir, [bool]$isDown, [double]$now, [scriptblock]$onFire) {
    $rep = $navRepeat[$dir]
    if (-not $isDown) { $rep.held = $false; return }
    if (-not $rep.held) {
        $rep.held = $true
        $rep.nextAt = $now + $REPEAT_DELAY
        & $onFire
    } elseif ($now -ge $rep.nextAt) {
        $rep.nextAt = $now + $REPEAT_RATE
        & $onFire
    }
}

# ---- main loop ------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastTime = $sw.Elapsed.TotalSeconds
$CURSOR_BASE_SPEED = 1100.0  # px/sec at full stick deflection
$CURSOR_CURVE = 1.7
$SCROLL_BASE_NOTCHES = 4.0   # wheel notches/sec at full stick deflection
$SCROLL_CURVE = 1.3

while ($true) {
  try {
    Drain-Stdin

    $now = $sw.Elapsed.TotalSeconds
    $dt = [Math]::Min($now - $lastTime, 0.05)
    $lastTime = $now

    $state = New-Object CMNative+XINPUT_STATE
    $found = $false
    for ($i = 0; $i -lt 4; $i++) {
        if ([CMNative]::XInputGetState([uint32]$i, [ref]$state) -eq 0) { $found = $true; break }
    }
    if ($found -ne $padConnected) {
        $padConnected = $found
        Write-Output "PAD $(if ($found) { 1 } else { 0 })"
    }

    if ($now -ge $nextFocusPollAt) {
        $nextFocusPollAt = $now + $FOCUS_POLL_INTERVAL
        try { $isTextFocused = Test-IsTextElement ([System.Windows.Automation.AutomationElement]::FocusedElement) }
        catch { $isTextFocused = $false }
    }
    if ($isTextFocused -ne $prevTextFocused) {
        $prevTextFocused = $isTextFocused
        # Suppression only protects the text box the user dismissed the
        # keyboard in; once focus actually leaves it, the next text box
        # focused should auto-popup again like normal.
        if (-not $isTextFocused) { $autoSuppressed = $false }
    }
    if ($found -and $cfg.enabled -and $cfg.autokeyboard) {
        if ($isTextFocused -and $mode -eq 'mouse' -and -not $autoSuppressed) {
            Set-Mode 'keyboard' -Auto
            $autoShown = $true
        } elseif ((-not $isTextFocused) -and $mode -eq 'keyboard' -and $autoShown) {
            Set-Mode 'mouse' -Auto
            $autoShown = $false
        }
    }

    if ($found) {
        $gp = $state.Gamepad
        $lx = $gp.sThumbLX / 32767.0
        $ly = $gp.sThumbLY / 32767.0   # XInput: positive = pushed up
        $rx = $gp.sThumbRX / 32767.0
        $ry = $gp.sThumbRY / 32767.0
        $btns = $gp.wButtons
        $start = ($btns -band $BTN_START) -ne 0
        $a = ($btns -band $BTN_A) -ne 0
        $b = ($btns -band $BTN_B) -ne 0
        $rt = $gp.bRightTrigger -gt $TRIGGER_THRESHOLD
        $lt = $gp.bLeftTrigger -gt $TRIGGER_THRESHOLD
        $rb = ($btns -band $BTN_RSHOULDER) -ne 0

        if ($start -and -not $lastStart) { Set-Mode $(if ($mode -eq 'mouse') { 'keyboard' } else { 'mouse' }) }
        $lastStart = $start

        if ($mode -eq 'mouse') {
            if ($cfg.enabled) {
                $move = Get-RadialCurve $lx $ly $cfg.deadzone $CURSOR_CURVE
                if ($move.mag -gt 0) {
                    $speedPxPerSec = $move.mag * $CURSOR_BASE_SPEED * $cfg.speed
                    # Screen Y grows downward, so "up" (positive move.y here) subtracts.
                    $script:moveRemX += $move.x * $speedPxPerSec * $dt
                    $script:moveRemY += (-$move.y) * $speedPxPerSec * $dt
                }
                $dx = [Math]::Truncate($moveRemX)
                $dy = [Math]::Truncate($moveRemY)
                if ($dx -ne 0 -or $dy -ne 0) {
                    $script:moveRemX -= $dx
                    $script:moveRemY -= $dy
                    $p = New-Object CMNative+POINT
                    [CMNative]::GetCursorPos([ref]$p) | Out-Null
                    [CMNative]::SetCursorPos($p.X + [int]$dx, $p.Y + [int]$dy) | Out-Null
                }

                Set-MouseButton 'left' $rt
                Set-MouseButton 'right' $lt
                Set-MouseButton 'middle' $rb

                $scrollY = Get-AxisCurve $ry $cfg.deadzone $SCROLL_CURVE
                $scrollX = Get-AxisCurve $rx $cfg.deadzone $SCROLL_CURVE
                if ($scrollY -ne 0) { $script:scrollRemY += $scrollY * $SCROLL_BASE_NOTCHES * $cfg.scroll * $dt }
                if ($scrollX -ne 0) { $script:scrollRemX += $scrollX * $SCROLL_BASE_NOTCHES * $cfg.scroll * $dt }
                $notchesY = [Math]::Truncate($scrollRemY)
                $notchesX = [Math]::Truncate($scrollRemX)
                if ($notchesY -ne 0) {
                    $script:scrollRemY -= $notchesY
                    [CMNative]::mouse_event($WHEEL, 0, 0, [int]($notchesY * $WHEEL_DELTA), [UIntPtr]::Zero) | Out-Null
                }
                if ($notchesX -ne 0) {
                    $script:scrollRemX -= $notchesX
                    [CMNative]::mouse_event($HWHEEL, 0, 0, [int]($notchesX * $WHEEL_DELTA), [UIntPtr]::Zero) | Out-Null
                }
            } else {
                Release-AllButtons
            }
        } else {
            # Keyboard mode: D-pad or left stick navigates, A activates, B/Start hide.
            $up = (($btns -band $BTN_DPAD_UP) -ne 0) -or ($ly -gt $STICK_NAV_THRESHOLD)
            $down = (($btns -band $BTN_DPAD_DOWN) -ne 0) -or ($ly -lt -$STICK_NAV_THRESHOLD)
            $left = (($btns -band $BTN_DPAD_LEFT) -ne 0) -or ($lx -lt -$STICK_NAV_THRESHOLD)
            $right = (($btns -band $BTN_DPAD_RIGHT) -ne 0) -or ($lx -gt $STICK_NAV_THRESHOLD)
            Poll-Repeat 'up' $up $now { Move-Row (-1) }
            Poll-Repeat 'down' $down $now { Move-Row 1 }
            Poll-Repeat 'left' $left $now { Move-Col (-1) }
            Poll-Repeat 'right' $right $now { Move-Col 1 }

            if ($a -and -not $lastA) { Activate-Key }
            $lastA = $a
            if ($b -and -not $lastB) { Set-Mode 'mouse' }
            $lastB = $b
        }
    } else {
        Release-AllButtons
        $lastStart = $false; $lastA = $false; $lastB = $false
        foreach ($rep in $navRepeat.Values) { $rep.held = $false }
    }
  } catch {
    [Console]::Error.WriteLine("loop error: $_")
  }

    Start-Sleep -Milliseconds 16
}
