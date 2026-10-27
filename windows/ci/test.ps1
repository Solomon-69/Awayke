# Automated Windows test for Awayke: start it, check it keeps the PC awake, the lid setting, the panel,
# the tray icon, then quit and check everything is put back. Screenshots go to $Shots.
param([string]$Exe = 'out/Awayke/Awayke.exe', [string]$Shots = 'shots')
. "$PSScriptRoot/winlib.ps1"
New-Item -ItemType Directory -Force $Shots | Out-Null
$Exe = (Resolve-Path $Exe).Path
$Shots = (Resolve-Path $Shots).Path

function LidValues { (powercfg /q SCHEME_CURRENT SUB_BUTTONS LIDACTION 2>&1) -join "`n" }
$lidBefore = LidValues
Write-Host "Lid setting before:`n$lidBefore"

# ---- Run 1: light theme, switch on, panel open ----
Set-Theme $false
$json = Join-Path $Shots 'awayke-selftest.json'
$p = Start-App $Exe @('--test-open', '--test-on', '--test-timer', "--selftest=$json")
Check (Promote-TrayIcon 'Awayke.exe') 'tray icon registered with Windows (NotifyIconSettings entry)'
Check (Wait-File $json 120) 'self-test file written'
$r = Get-Content $json -Raw | ConvertFrom-Json
Write-Host ($r | ConvertTo-Json -Depth 5)
Check (-not $p.HasExited) 'process alive'
Check $r.ready 'WebView2 page loaded'
Check $r.panelVisible 'panel opened (--test-open)'
Check $r.on 'switched on (--test-on)'
Check (($r.minutesLeft -ge 88) -and ($r.minutesLeft -le 90)) 'Add 30 min: a 60 minute timer now has about 90 minutes left'
Check ($r.trayText -match 'left') 'tray tooltip shows the time left'
Check (-not $r.batteryCutoff) 'battery cutoff is off by default'
Check $r.warn '5 minute warning is on by default'
Check $r.newerCheck 'update check compares versions correctly'
Check ($r.version -eq '1.5.0') 'version is 1.5.0'
Check ($null -ne $r.tray) 'tray icon has a position on screen'
Start-Sleep -Seconds 1
Save-Screen (Join-Path $Shots '01-awayke-desktop-light.png')
$b = $r.panelBounds
Save-Crop (Join-Path $Shots '02-awayke-panel-light.png') $b[0] $b[1] $b[2] $b[3]
Save-TrayCorner (Join-Path $Shots '03-awayke-tray-on.png')

$req = (powercfg /requests 2>&1) -join "`n"
Write-Host "powercfg /requests:`n$req"
Check ($req -match 'Awayke\.exe') 'powercfg /requests lists Awayke.exe'
$lidOn = LidValues
Write-Host "Lid setting while on:`n$lidOn"
if ($r.lidError) { Write-Host "Lid note from app: $($r.lidError)" }
elseif ($r.lidNow) { Check (($r.lidNow[0] -eq 0) -and ($r.lidNow[1] -eq 0)) 'lid action set to Do nothing while on' }

Check (Quit-App $Exe 'Awayke') 'quit with --quit (clean exit)'
$req2 = (powercfg /requests 2>&1) -join "`n"
Check (-not ($req2 -match 'Awayke\.exe')) 'keep-awake request gone after quit'
$lidAfter = LidValues
Check ($lidAfter -eq $lidBefore) 'lid setting put back exactly after quit'

# ---- Run 2: dark theme, settings view ----
Set-Theme $true
$json2 = Join-Path $Shots 'awayke-selftest-dark.json'
$p2 = Start-App $Exe @('--test-open', '--test-settings', "--selftest=$json2")
[void](Promote-TrayIcon 'Awayke.exe' 10)
Check (Wait-File $json2 120) 'second run: self-test file written'
$r2 = Get-Content $json2 -Raw | ConvertFrom-Json
Start-Sleep -Seconds 1
Save-Screen (Join-Path $Shots '04-awayke-desktop-dark.png')
$b = $r2.panelBounds
Save-Crop (Join-Path $Shots '05-awayke-settings-dark.png') $b[0] $b[1] $b[2] $b[3]
Save-TrayCorner (Join-Path $Shots '06-awayke-tray-off-dark.png')
Check (-not $r2.on) 'starts switched off'
Check (Quit-App $Exe 'Awayke') 'second run: clean quit'

# ---- Run 3: dark theme, switch on, panel open (for the page pictures) ----
Set-Theme $true
$json3 = Join-Path $Shots 'awayke-selftest-dark-on.json'
$p3 = Start-App $Exe @('--test-open', '--test-on', "--selftest=$json3")
[void](Promote-TrayIcon 'Awayke.exe' 10)
Check (Wait-File $json3 120) 'third run: self-test file written'
$r3 = Get-Content $json3 -Raw | ConvertFrom-Json
Start-Sleep -Seconds 1
$b = $r3.panelBounds
Save-Crop (Join-Path $Shots '07-awayke-panel-dark.png') $b[0] $b[1] $b[2] $b[3]
Save-TrayCorner (Join-Path $Shots '08-awayke-tray-on-dark.png')
Check (Quit-App $Exe 'Awayke') 'third run: clean quit'
Set-Theme $false
Finish
