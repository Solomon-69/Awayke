# winlib.ps1: helpers for the automated Windows test (shared, identical copy for Ludus, Nox and Awayke).
# Screenshots, window checks, tray icon promotion, theme switching.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class U32 {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
  // Screen copy WITH CAPTUREBLT, so layered (see-through) windows such as Nox's fade picture are included.
  public static void Grab(IntPtr dstDc, int x, int y, int w, int h) {
    IntPtr src = GetDC(IntPtr.Zero);
    BitBlt(dstDc, 0, 0, w, h, src, x, y, 0x00CC0020 | 0x40000000);
    ReleaseDC(IntPtr.Zero, src);
  }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  // Is a window with this exact title, belonging to this process, on screen?
  public static bool ProcessWindowVisible(int pid, string title) {
    bool found = false;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid && IsWindowVisible(h)) {
        var sb = new System.Text.StringBuilder(256); GetWindowText(h, sb, 256);
        if (sb.ToString() == title) { found = true; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, UIntPtr w, string l, uint flags, uint timeout, out UIntPtr result);
}
"@
[void][U32]::SetProcessDpiAwarenessContext([IntPtr]-4)   # per-monitor v2, so screenshots are in real pixels

$script:Failures = New-Object System.Collections.Generic.List[string]
function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:Failures.Add($msg) }
function Pass($msg) { Write-Host "PASS: $msg" -ForegroundColor Green }
function Check($ok, $msg) { if ($ok) { Pass $msg } else { Fail $msg } }

function Grab-Into($g, [int]$x, [int]$y, [int]$w, [int]$h) {
  $dc = $g.GetHdc()
  try { [U32]::Grab($dc, $x, $y, $w, $h) } finally { $g.ReleaseHdc($dc) }
}

function Save-Screen([string]$path) {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  Grab-Into $g $b.Left $b.Top $b.Width $b.Height
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Host "screenshot: $path ($($b.Width)x$($b.Height))"
}

function Save-Crop([string]$path, [int]$x, [int]$y, [int]$w, [int]$h, [int]$pad = 16) {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $x0 = [Math]::Max($b.Left, $x - $pad); $y0 = [Math]::Max($b.Top, $y - $pad)
  $x1 = [Math]::Min($b.Right, $x + $w + $pad); $y1 = [Math]::Min($b.Bottom, $y + $h + $pad)
  if ($x1 -le $x0 -or $y1 -le $y0) { Write-Host "crop skipped: $path"; return }
  $bmp = New-Object System.Drawing.Bitmap ($x1 - $x0), ($y1 - $y0)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  Grab-Into $g $x0 $y0 ($x1 - $x0) ($y1 - $y0)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Host "crop: $path"
}

# The tray corner: right end of the taskbar on the main screen.
function Save-TrayCorner([string]$path) {
  $s = [System.Windows.Forms.Screen]::PrimaryScreen
  Save-Crop $path ($s.Bounds.Right - 520) ($s.Bounds.Bottom - 90) 520 90 0
}

function Wait-File([string]$path, [int]$seconds = 90) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) {
    if (Test-Path $path) { Start-Sleep -Milliseconds 300; return $true }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

function Window-Visible([string]$title) {
  foreach ($p in Get-Process $title -ErrorAction SilentlyContinue) {
    if ([U32]::ProcessWindowVisible($p.Id, $title)) { return $true }
  }
  return $false
}

# Windows 11 hides new tray icons in the overflow. Promote ours (what Settings > Taskbar does), so it is on
# the taskbar for the screenshot. The entry only exists once the app has added its icon: proof it did.
function Promote-TrayIcon([string]$exeName, [int]$seconds = 30) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) {
    $root = 'HKCU:\Control Panel\NotifyIconSettings'
    if (Test-Path $root) {
      foreach ($k in Get-ChildItem $root) {
        $p = Get-ItemProperty $k.PSPath
        if ($p.ExecutablePath -like "*\$exeName") {
          Set-ItemProperty $k.PSPath -Name IsPromoted -Value 1 -Type DWord
          return $true
        }
      }
    }
    Start-Sleep -Milliseconds 300
  }
  return $false
}

function Theme-Values {
  $p = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
  return [pscustomobject]@{ Apps = $p.AppsUseLightTheme; System = $p.SystemUsesLightTheme }
}

function Set-Theme([bool]$dark) {
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
  $v = if ($dark) { 0 } else { 1 }
  Set-ItemProperty $key -Name AppsUseLightTheme -Value $v -Type DWord
  Set-ItemProperty $key -Name SystemUsesLightTheme -Value $v -Type DWord
  $r = [UIntPtr]::Zero
  [void][U32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 1000, [ref]$r)
  Start-Sleep -Seconds 2
}

function Quit-App([string]$exe, [string]$name, [int]$seconds = 20) {
  Start-Process $exe -ArgumentList '--quit' | Out-Null
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) {
    if (-not (Get-Process $name -ErrorAction SilentlyContinue)) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

function Start-App([string]$exe, [string[]]$arguments) {
  Write-Host "start: $exe $($arguments -join ' ')"
  return Start-Process $exe -ArgumentList $arguments -PassThru
}

function Finish {
  if ($script:Failures.Count -gt 0) {
    Write-Host "`n$($script:Failures.Count) check(s) failed:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host " - $_" }
    exit 1
  }
  Write-Host "`nAll checks passed." -ForegroundColor Green
  exit 0
}
