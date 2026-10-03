# Runs inside Glance-Setup.cmd ($Files = name -> base64) or from Glance-Setup.exe ($Source = extracted folder).
param([hashtable]$Files, [string]$SetupArgs, [string]$Source)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppName = 'Glance'
$Version = '__VERSION__'
$Silent  = $SetupArgs -match '(^|\s)/S(\s|$)'
$WantStartup = $SetupArgs -match '(^|\s)/STARTUP(\s|$)'
$Dir     = Join-Path $env:LOCALAPPDATA "Programs\$AppName"
$Exe     = Join-Path $Dir 'Glance.exe'
$StartMenuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup'))  "$AppName.lnk"
$RegKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"

function Say([string]$m) { Write-Host "  $m" }
function Ask([string]$text, [string]$buttons, [string]$icon = 'Question') {
    [System.Windows.Forms.MessageBox]::Show($text, "$AppName Setup", $buttons, $icon, 'Button1', 'ServiceNotification')
}
function Stop-Running {
    Get-Process -Name 'Glance' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*Glance.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
}
function New-Shortcut([string]$path, [string]$target, [string]$arguments, [string]$desc) {
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($path)
    $sc.TargetPath = $target; $sc.Arguments = $arguments; $sc.WorkingDirectory = $Dir
    $sc.Description = $desc; $sc.IconLocation = "$target,0"
    $sc.Save()
}

Write-Host ''
Write-Host "  $AppName $Version Setup" -ForegroundColor White
Write-Host '  ----------------------------------------'

$existing = Test-Path $Exe
if (-not $Silent) {
    $verb = if ($existing) { 'Update' } else { 'Install' }
    $msg = "$verb $AppName $Version`n`nLocation:  $Dir`n`nNo administrator rights are needed and nothing else is downloaded or installed."
    if ((Ask $msg 'OKCancel' 'Information') -ne 'OK') { Say 'Cancelled.'; exit 2 }
}

Say 'Closing running instance...'
Stop-Running

# Pre-rename "SysMonitor" install: stop it, remove its shortcuts/registration/files, keep its settings.
$legacyDir = Join-Path $env:LOCALAPPDATA 'Programs\SysMonitor'
if (Test-Path $legacyDir) {
    Say 'Removing previous SysMonitor install'
    Get-Process -Name 'SysMonitor' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    if (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'SysMonitor.lnk')) { $WantStartup = $true }
    foreach ($f in 'Programs', 'Startup') { Remove-Item (Join-Path ([Environment]::GetFolderPath($f)) 'SysMonitor.lnk') -ErrorAction SilentlyContinue }
    Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SysMonitor' -Recurse -ErrorAction SilentlyContinue
    Remove-Item $legacyDir -Recurse -Force -ErrorAction SilentlyContinue
}

Say "Copying files to $Dir"
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
foreach ($name in 'Glance.exe', 'Uninstall.cmd') {
    $dst = Join-Path $Dir $name
    if ($Source) { Copy-Item (Join-Path $Source $name) $dst -Force }
    else {
        if (-not $Files.ContainsKey($name)) { throw "Payload is missing $name" }
        [IO.File]::WriteAllBytes($dst, [Convert]::FromBase64String($Files[$name]))
    }
}

# Leftovers from the script-based 1.x/2.0 layout.
foreach ($old in 'Glance.ps1', 'Start-Glance.vbs') { Remove-Item (Join-Path $Dir $old) -ErrorAction SilentlyContinue }

Say 'Creating Start Menu shortcut'
New-Shortcut $StartMenuLnk $Exe '' "$AppName overlay"

$startup = $false
if ($WantStartup) { $startup = $true }
elseif (Test-Path $StartupLnk) { $startup = $true }
elseif (-not $Silent) { $startup = (Ask "Start $AppName automatically when you sign in to Windows?`n`n(You can change this later in Settings > General.)" 'YesNo') -eq 'Yes' }
if ($startup) { Say 'Enabling start with Windows'; New-Shortcut $StartupLnk $Exe '' "$AppName overlay" }

Say 'Registering in Apps & Features'
$size = [int]((Get-ChildItem $Dir | Measure-Object Length -Sum).Sum / 1KB)
New-Item -Path $RegKey -Force | Out-Null
$props = @{
    DisplayName = $AppName; DisplayVersion = $Version; Publisher = 'Glance'; InstallLocation = $Dir
    DisplayIcon = $Exe; EstimatedSize = $size
    UninstallString = "cmd.exe /c `"`"$Dir\Uninstall.cmd`"`""; QuietUninstallString = "cmd.exe /c `"`"$Dir\Uninstall.cmd`" /S`""
    NoModify = 1; NoRepair = 1; InstallDate = (Get-Date -Format 'yyyyMMdd')
}
foreach ($k in $props.Keys) { New-ItemProperty -Path $RegKey -Name $k -Value $props[$k] -Force | Out-Null }

Say 'Launching'
Start-Process -FilePath $Exe -WorkingDirectory $Dir

Say 'Done.'
if (-not $Silent) {
    Ask "$AppName is installed and running.`n`nFind it in the system tray - right-click for the menu, double-click for Settings.`nUninstall any time from Settings > Apps." 'OK' 'Information' | Out-Null
}
exit 0
