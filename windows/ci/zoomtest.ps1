# zoomtest.ps1: "no zooming anywhere". Opens the app, then sends everything a user could try to zoom with:
# Ctrl + mouse wheel (what a trackpad pinch sends too), Ctrl and plus / minus / 0. The app writes its zoom and layout
# before and after each round; nothing may change. Phase 1 tries to zoom in, phase 2 tries to zoom out.
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class ZIn {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr e);
  public static void CtrlWheel(int delta, int times) {
    keybd_event(0x11, 0, 0, UIntPtr.Zero);
    for (int i = 0; i < times; i++) { mouse_event(0x0800, 0, 0, delta, UIntPtr.Zero); System.Threading.Thread.Sleep(60); }
    keybd_event(0x11, 0, 2, UIntPtr.Zero);
  }
  public static void CtrlKeys(params byte[] keys) {
    keybd_event(0x11, 0, 0, UIntPtr.Zero);
    foreach (var k in keys) { keybd_event(k, 0, 0, UIntPtr.Zero); keybd_event(k, 0, 2, UIntPtr.Zero); System.Threading.Thread.Sleep(80); }
    keybd_event(0x11, 0, 2, UIntPtr.Zero);
  }
}
"@
function Test-NoZoom([string]$Exe, [string]$Name, [string]$Shots, [string[]]$AppArgs = @()) {
  Set-Theme $false
  $j = Join-Path $Shots "$Name-zoom.json"
  Remove-Item "$j.*" -ErrorAction SilentlyContinue
  $p = Start-App $Exe (@('--test-open', '--test-zoomprobe', "--selftest=$j") + $AppArgs)
  if (-not (Wait-File "$j.z0" 120)) { Fail "$Name zoom test: app never reported"; [void](Quit-App $Exe $Name); return }
  $z0 = Get-Content "$j.z0" -Raw | ConvertFrom-Json
  $b = $z0.bounds
  [void][ZIn]::SetCursorPos([int]($b[0] + $b[2] / 2), [int]($b[1] + 40))   # over the panel (a quiet spot near the top)
  Start-Sleep -Milliseconds 400
  # Phase 1: zoom in
  [ZIn]::CtrlWheel(120, 8)
  [ZIn]::CtrlKeys(0x6B, 0x6B, 0xBB, 0x6B)   # Ctrl + numpad-plus, plus
  New-Item "$j.go1" -ItemType File | Out-Null
  Check (Wait-File "$j.z1" 60) "$Name zoom test: report after zoom-in attempts"
  $z1 = Get-Content "$j.z1" -Raw | ConvertFrom-Json
  Save-Crop (Join-Path $Shots "$Name-zoom-after-in.png") $b[0] $b[1] $b[2] $b[3]
  # Phase 2: zoom out
  [ZIn]::CtrlWheel(-120, 8)
  [ZIn]::CtrlKeys(0x6D, 0x6D, 0xBD, 0x6D)   # Ctrl + numpad-minus, minus
  New-Item "$j.go2" -ItemType File | Out-Null
  Check (Wait-File "$j.z2" 60) "$Name zoom test: report after zoom-out attempts"
  $z2 = Get-Content "$j.z2" -Raw | ConvertFrom-Json
  Save-Crop (Join-Path $Shots "$Name-zoom-after-out.png") $b[0] $b[1] $b[2] $b[3]
  Write-Host "$Name zoom: before=$($z0 | ConvertTo-Json -Compress) afterIn=$($z1 | ConvertTo-Json -Compress) afterOut=$($z2 | ConvertTo-Json -Compress)"
  $same = { param($a, $c) ($a | ConvertTo-Json -Compress) -eq ($c | ConvertTo-Json -Compress) }
  Check (& $same $z0 $z1) "${Name}: Ctrl+wheel and Ctrl+plus change nothing (zoom, layout, size)"
  Check (& $same $z0 $z2) "${Name}: Ctrl+wheel and Ctrl+minus change nothing (zoom, layout, size)"
  Check (Quit-App $Exe $Name) "$Name zoom test: clean quit"
}
