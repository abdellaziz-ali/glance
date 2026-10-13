<#
  Builds everything into .\dist using only tools that ship with Windows (csc.exe from .NET Framework 4.x):
    Glance.exe        - the app: native host with Glance.ps1 embedded, runs it in-process (no powershell.exe window/process)
    Glance-Setup.exe  - installer stub with Glance.exe + Uninstall.cmd embedded; /S silent, /STARTUP
    Glance-Setup.cmd  - same installer as a self-extracting batch (payload = base64 after 'exit /b')

  Usage: powershell -ExecutionPolicy Bypass -File .\Build.ps1 [-NoSetup]
#>
param([switch]$NoSetup)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Dist = Join-Path $Root 'dist'
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

$Version = (Select-String -Path (Join-Path $Root 'Glance.ps1') -Pattern "^\`$Version\s*=\s*'([^']+)'").Matches[0].Groups[1].Value
# Assembly attributes need exactly major.minor.build.revision.
$AsmVersion = (@($Version -split '\.') + @('0', '0', '0'))[0..3] -join '.'
Write-Host "Building Glance $Version"

$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe (.NET Framework 4.x) not found' }
$sma = Get-ChildItem (Join-Path $env:windir 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') -Recurse -Filter System.Management.Automation.dll | Select-Object -First 1
if (-not $sma) { throw 'System.Management.Automation.dll not found (Windows PowerShell 5.1 required)' }

$work = Join-Path $env:TEMP 'GlanceBuild'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Icon: amber bars on dark, same motif as the tray icon.
Add-Type -AssemblyName System.Drawing
function New-Icon([string]$path) {
    $ms = New-Object IO.MemoryStream
    $sizes = 16, 32, 48, 256
    $pngs = foreach ($sz in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $sz, $sz
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::FromArgb(255, 11, 13, 16))
        $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 245, 165, 36))
        $u = $sz / 32.0
        $g.FillRectangle($br, 5 * $u, 19 * $u, 6 * $u, 9 * $u); $g.FillRectangle($br, 13 * $u, 12 * $u, 6 * $u, 16 * $u); $g.FillRectangle($br, 21 * $u, 4 * $u, 6 * $u, 24 * $u)
        $g.Dispose()
        $m = New-Object IO.MemoryStream; $bmp.Save($m, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); ,$m.ToArray()
    }
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $off = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $sz = $sizes[$i]; $bw.Write([byte]($(if ($sz -ge 256) { 0 } else { $sz }))); $bw.Write([byte]($(if ($sz -ge 256) { 0 } else { $sz })))
        $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$off)
        $off += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write($p) }
    $bw.Flush(); [IO.File]::WriteAllBytes($path, $ms.ToArray())
}
$icoPath = Join-Path $work 'app.ico'
New-Icon $icoPath

function Invoke-Csc([string]$source, [string]$out, [string]$manifest, [string[]]$refs, [hashtable]$resources) {
    $args = @('/nologo', '/target:winexe', '/optimize+', "/out:`"$out`"", "/win32manifest:`"$manifest`"", "/win32icon:`"$icoPath`"")
    foreach ($r in $refs) { $args += "/reference:`"$r`"" }
    foreach ($k in $resources.Keys) { $args += "/resource:`"$($resources[$k])`",$k" }
    $args += "`"$source`""
    $o = & $csc @args 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw "csc failed for $(Split-Path $out -Leaf):`n$($o -join "`n")" }
}

# ---- 1. Glance.exe (the app)
$hostCs = Join-Path $work 'Host.cs'
[IO.File]::WriteAllText($hostCs, (Get-Content (Join-Path $Root 'src\Host.cs') -Raw).Replace('__VERSION__.0.0', $AsmVersion).Replace('__VERSION__', $Version), [Text.Encoding]::UTF8)
$appExe = Join-Path $Dist 'Glance.exe'
Remove-Item $appExe -Force -ErrorAction SilentlyContinue
Invoke-Csc $hostCs $appExe (Join-Path $Root 'src\Glance.manifest') @($sma.FullName, 'System.Windows.Forms.dll') @{ 'Glance.ps1' = (Join-Path $Root 'Glance.ps1') }
Write-Host ("  {0}  ({1:N0} KB)" -f $appExe, ((Get-Item $appExe).Length / 1KB))

if ($NoSetup) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue; return }

# ---- 2. Installers
$installer = (Get-Content (Join-Path $Root 'installer\Install.ps1') -Raw).Replace('__VERSION__', $Version)
$payload = [ordered]@{
    'Glance.exe' = [IO.File]::ReadAllBytes($appExe)
    'Uninstall.cmd'  = [IO.File]::ReadAllBytes((Join-Path $Root 'installer\Uninstall.cmd'))
    'Install.ps1'    = [Text.Encoding]::UTF8.GetBytes($installer)
}

# Bootstrap one-liner: reads this .cmd, decodes the ::FILE sections, runs Install.ps1 from memory.
# Avoids % ! | < > and inner double quotes so cmd passes it through untouched. ':'+':' stops self-matching.
$boot = @(
    '$t=[IO.File]::ReadAllText($env:SM_SELF);$b=$t.Substring($t.IndexOf('':''+'':PAYLOAD''));$h=@{};$n=$null;$sb=$null;'
    'foreach($l in $b.Split([char]10)){$l=$l.Trim();if($l.StartsWith('':''+'':FILE '')){if($n){$h[$n]=$sb.ToString()};$n=$l.Substring(7).Trim();$sb=New-Object Text.StringBuilder}'
    'elseif($l.StartsWith('':''+'':END'')){if($n){$h[$n]=$sb.ToString()};break}elseif($n){[void]$sb.Append($l)}};'
    '$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($h[''Install.ps1'']));$h.Remove(''Install.ps1'');'
    '& ([scriptblock]::Create($c)) -Files $h -SetupArgs $env:SM_ARGS;exit $LASTEXITCODE'
) -join ''

$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('@echo off')
[void]$sb.AppendLine("title Glance $Version Setup")
[void]$sb.AppendLine('setlocal')
[void]$sb.AppendLine('set "SM_SELF=%~f0"')
[void]$sb.AppendLine('set "SM_ARGS=%*"')
[void]$sb.AppendLine("powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -STA -Command `"$boot`"")
[void]$sb.AppendLine('exit /b %errorlevel%')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('::PAYLOAD')
foreach ($name in $payload.Keys) {
    [void]$sb.AppendLine("::FILE $name")
    $b64 = [Convert]::ToBase64String($payload[$name])
    for ($i = 0; $i -lt $b64.Length; $i += 76) { [void]$sb.AppendLine($b64.Substring($i, [Math]::Min(76, $b64.Length - $i))) }
}
[void]$sb.AppendLine('::END')

$cmdPath = Join-Path $Dist 'Glance-Setup.cmd'
[IO.File]::WriteAllText($cmdPath, $sb.ToString(), [Text.Encoding]::ASCII)
Write-Host ("  {0}  ({1:N0} KB)" -f $cmdPath, ((Get-Item $cmdPath).Length / 1KB))

foreach ($name in $payload.Keys) { [IO.File]::WriteAllBytes((Join-Path $work $name), $payload[$name]) }

$cs = (Get-Content (Join-Path $Root 'installer\SetupStub.cs') -Raw).Replace('__VERSION__.0.0', $AsmVersion).Replace('__VERSION__', $Version)
$csPath = Join-Path $work 'SetupStub.cs'
[IO.File]::WriteAllText($csPath, $cs, [Text.Encoding]::UTF8)

$res = @{}; foreach ($name in $payload.Keys) { $res[$name] = Join-Path $work $name }
$exePath = Join-Path $Dist 'Glance-Setup.exe'
Remove-Item $exePath -Force -ErrorAction SilentlyContinue
Invoke-Csc $csPath $exePath (Join-Path $Root 'installer\SetupStub.manifest') @('System.Windows.Forms.dll') $res
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("  {0}  ({1:N0} KB)" -f $exePath, ((Get-Item $exePath).Length / 1KB))

# The in-app updater refuses any download that this file does not vouch for; ship it with every release.
$sumsPath = Join-Path $Dist 'SHA256SUMS.txt'
$lines = foreach ($f in 'Glance-Setup.exe', 'Glance-Setup.cmd', 'Glance.exe') { '{0} *{1}' -f (Get-FileHash (Join-Path $Dist $f) -Algorithm SHA256).Hash.ToLowerInvariant(), $f }
[IO.File]::WriteAllText($sumsPath, ($lines -join "`n") + "`n", [Text.Encoding]::ASCII)
Write-Host "  $sumsPath"
