@echo off
setlocal
set "APP=Glance"
set "DIR=%LOCALAPPDATA%\Programs\%APP%"
set "SILENT="
if /i "%~1"=="/S" set "SILENT=1"

if not defined SILENT (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $r=[System.Windows.Forms.MessageBox]::Show('Remove %APP% and its shortcuts?','%APP% Uninstall','YesNo','Question'); if($r -ne 'Yes'){exit 2}"
  if errorlevel 2 exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-Process -Name 'Glance' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;" ^
  "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*Glance.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue };" ^
  "Start-Sleep -Milliseconds 600;" ^
  "Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) '%APP%.lnk') -ErrorAction SilentlyContinue;" ^
  "Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup'))  '%APP%.lnk') -ErrorAction SilentlyContinue;" ^
  "Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\%APP%' -Recurse -ErrorAction SilentlyContinue;" ^
  "if ($env:GLANCE_KEEP_SETTINGS -ne '1' -and -not '%SILENT%') { Add-Type -AssemblyName System.Windows.Forms; if ([System.Windows.Forms.MessageBox]::Show('Also delete your saved settings?','%APP% Uninstall','YesNo','Question') -eq 'Yes') { Remove-Item (Join-Path $env:APPDATA '%APP%') -Recurse -Force -ErrorAction SilentlyContinue } }"

if not defined SILENT (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('%APP% has been removed.','%APP% Uninstall','OK','Information')"
)

rem Delete our own folder after this script exits (batch is read lazily, so this trick is safe).
(goto) 2>nul & cd /d "%TEMP%" & rd /s /q "%DIR%" 2>nul
