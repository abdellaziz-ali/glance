#requires -Version 5.1
<#
  Glance - always-on-top CPU / RAM / GPU / disk / network overlay for Windows.
  Single script, no dependencies: Windows PowerShell 5.1 + WPF (both built into Windows).

  Run from source:    double-click Start-Glance.vbs  (or: powershell -STA -ExecutionPolicy Bypass -File .\Glance.ps1)
  Build .exe:         .\Build.ps1  ->  dist\Glance.exe + dist\Glance-Setup.exe (uses the csc.exe that ships with Windows)
  Smoke test:         $env:GLANCE_HEADLESS=1  (add $env:GLANCE_SHOT=<dir> to also save PNG screenshots)
  Settings:           %AppData%\Glance\settings.json

  Overlay: drag = move, gear = settings, right-click = menu. Tray: left-click = show/hide, double-click = settings.
#>

$ErrorActionPreference = 'Stop'
$Version  = '2.2'
$Headless = $env:GLANCE_HEADLESS -eq '1'
$ShotDir  = $env:GLANCE_SHOT
$AppExe   = [string]$AppExe                                   # set by the .exe host; empty when run as a script
$AppDir   = if ($AppExe) { Split-Path $AppExe -Parent } else { $PSScriptRoot }

# ---------------------------------------------------------------- bootstrap: WPF needs Windows PowerShell 5.1 in STA
$isWinPS = $PSVersionTable.PSVersion.Major -eq 5
$isSta   = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not ($isWinPS -and $isSta)) {
    if ($env:GLANCE_RELAUNCHED -eq '1') { Write-Error 'Glance needs Windows PowerShell 5.1 in STA mode.'; exit 1 }
    $env:GLANCE_RELAUNCHED = '1'
    $exe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($Headless) { & $exe -NoProfile -NoLogo -ExecutionPolicy Bypass -STA -File $PSCommandPath; exit $LASTEXITCODE }
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-NoLogo','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"")
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

Add-Type -Namespace Glance -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
[DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
[DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong32(IntPtr hWnd, int nIndex);
[DllImport("user32.dll", EntryPoint="SetWindowLongW")] public static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
public static long GetExStyle(IntPtr h) { return IntPtr.Size == 8 ? GetWindowLongPtr(h, -20).ToInt64() : GetWindowLong32(h, -20); }
public static void SetExStyle(IntPtr h, long v) { if (IntPtr.Size == 8) SetWindowLongPtr(h, -20, new IntPtr(v)); else SetWindowLong32(h, -20, (int)v); }
'@
[void][Glance.Native]::SetProcessDPIAware()

$mutexName = if ($Headless) { 'Local\Glance_Headless' } else { 'Local\Glance_SingleInstance' }
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

# ---------------------------------------------------------------- settings
$DataDir      = Join-Path $env:APPDATA 'Glance'
$SettingsPath = Join-Path $DataDir 'settings.json'
$Defaults = @{
    Mode = 'Panel'; Anchor = 'TopRight'; PanelLeft = $null; PanelTop = $null; BarLeft = $null; BarTop = $null
    BgAlpha = 0.92; Scale = 1.0; Accent = 'Amber'; ClickThrough = $false; ShowHeader = $true
    ShowSparklines = $true; ShowBars = $true; Interval = 1000
    ShowCpu = $true; ShowRam = $true; ShowGpu = $true; ShowNet = $true; ShowDisk = $true
    ShowTop = $true; ShowUptime = $true; ShowBattery = $true; DisksMode = 'All'
    NetBits = $false; Adapter = ''
}
$Accents = [ordered]@{ Amber = '#F5A524'; Mint = '#4FD1A5'; Ice = '#5DB7F0'; Coral = '#FF6E4F' }
$AnchorNames = [ordered]@{
    TopLeft = 'Top left'; TopCenter = 'Top center'; TopRight = 'Top right'
    MiddleLeft = 'Middle left'; Custom = 'Free (dragged)'; MiddleRight = 'Middle right'
    BottomLeft = 'Bottom left'; BottomCenter = 'Bottom center'; BottomRight = 'Bottom right'
}

function Load-Settings {
    $s = $Defaults.Clone()
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { if ($s.ContainsKey($p.Name)) { $s[$p.Name] = $p.Value } }
        } catch {}
    }
    if (-not $Accents.Contains([string]$s.Accent)) { $s.Accent = 'Amber' }
    if (-not $AnchorNames.Contains([string]$s.Anchor)) { $s.Anchor = 'TopRight' }
    $s
}
function Save-Settings {
    try {
        New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
        $script:Settings | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8
    } catch {}
}
function Write-ErrorLog([string]$msg) {
    try { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null; Add-Content -Path (Join-Path $DataDir 'error.log') -Value "$(Get-Date -Format s) $msg" } catch {}
}
# Settings written by the pre-rename "SysMonitor" builds are adopted on first run.
$legacyDir = Join-Path $env:APPDATA 'SysMonitor'
if (-not (Test-Path $SettingsPath) -and (Test-Path (Join-Path $legacyDir 'settings.json'))) {
    try { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null; Copy-Item (Join-Path $legacyDir 'settings.json') $SettingsPath } catch {}
}
$script:Settings = Load-Settings

# ---------------------------------------------------------------- formatting
$CH = @{ Deg = [string][char]0xB0; Down = [string][char]0x2193; Up = [string][char]0x2191; Bolt = [string][char]0x26A1; Ellipsis = [string][char]0x2026 }

function Format-Rate([double]$bps) {
    if ($script:Settings.NetBits) { $v = $bps * 8; $units = 'bps','Kbps','Mbps','Gbps'; $k = 1000 }
    else                          { $v = $bps;     $units = 'B/s','KB/s','MB/s','GB/s'; $k = 1024 }
    $i = 0
    while ($v -ge $k -and $i -lt 3) { $v /= $k; $i++ }
    $num = if ($i -eq 0 -or $v -ge 100) { '{0,5:0}' -f $v } else { '{0,5:0.0}' -f $v }
    "$num $($units[$i])"
}
function Format-Short([double]$b) {
    if ($b -lt 1KB)  { return ('{0:0} B' -f $b) }
    if ($b -lt 1MB)  { return ('{0:0} K' -f ($b / 1KB)) }
    if ($b -lt 10MB) { return ('{0:0.0} M' -f ($b / 1MB)) }
    if ($b -lt 1GB)  { return ('{0:0} M' -f ($b / 1MB)) }
    '{0:0.0} G' -f ($b / 1GB)
}
function Truncate-Text([string]$s, [int]$n) { if ($s.Length -gt $n) { $s.Substring(0, $n - 1) + $CH.Ellipsis } else { $s } }

# ---------------------------------------------------------------- metrics worker (own runspace; never touches UI)
$workerScript = {
    $ErrorActionPreference = 'Stop'
    $sw    = [System.Diagnostics.Stopwatch]::StartNew()
    $cores = [Environment]::ProcessorCount
    $boot  = $null
    try { $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch {}

    $nvsmi = $null
    foreach ($c in @("$env:windir\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) { if (Test-Path $c) { $nvsmi = $c; break } }
    if (-not $nvsmi) { $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue; if ($cmd) { $nvsmi = $cmd.Source } }

    $gpuName = $null; $vramTotal = 0.0
    try {
        $vc = Get-CimInstance Win32_VideoController | Sort-Object AdapterRAM -Descending | Select-Object -First 1
        $gpuName = $vc.Name; $vramTotal = [double]$vc.AdapterRAM
    } catch {}
    try {
        # AdapterRAM is uint32 (caps at 4 GB); the registry has the real size.
        $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in Get-ChildItem $cls -ErrorAction SilentlyContinue) {
            $q = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
            if ($q -and [double]$q -gt $vramTotal) { $vramTotal = [double]$q }
        }
    } catch {}

    $prevRx = 0L; $prevTx = 0L; $prevT = $null; $prevAdapter = $null
    $prevProc = @{}; $prevProcT = $null; $topName = $null; $topPct = 0
    $cpuTemp = $null; $thermalOk = $true; $bat = $null
    $tick = 0

    while ($sync.Run) {
        $start = $sw.Elapsed.TotalMilliseconds
        $s = @{ Time = Get-Date; Err = New-Object System.Collections.ArrayList }

        try { $s.Cpu = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime } catch { [void]$s.Err.Add("cpu: $_") }

        try {
            $os = Get-CimInstance Win32_OperatingSystem
            $s.RamTotal = [double]$os.TotalVisibleMemorySize * 1KB
            $s.RamUsed  = $s.RamTotal - [double]$os.FreePhysicalMemory * 1KB
            if (-not $boot) { $boot = $os.LastBootUpTime }
        } catch { [void]$s.Err.Add("ram: $_") }
        if ($boot) { $s.Uptime = (Get-Date) - $boot }

        if ($thermalOk -and ($tick % 5 -eq 0)) {
            try {
                $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature |
                      Where-Object { $_.CurrentTemperature -gt 2732 } | Sort-Object CurrentTemperature -Descending | Select-Object -First 1
                if ($tz) { $cpuTemp = ($tz.CurrentTemperature - 2732) / 10 } else { $thermalOk = $false }
            } catch { $thermalOk = $false }
        }
        if ($cpuTemp) { $s.CpuTemp = $cpuTemp }

        try {
            $all = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                   Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -notin 'Loopback','Tunnel' })
            $s.Adapters = @($all | ForEach-Object { $_.Name })
            $want = [string]$sync.Adapter
            if ($want) { $sel = @($all | Where-Object { $_.Name -eq $want }) } else { $sel = @() }
            if ($sel.Count -eq 0) {
                $sel = @($all | Where-Object { $_.Description -notmatch 'Virtual|VMware|Hyper-V|vEthernet|VirtualBox|Loopback|TAP-|WAN Miniport|Bluetooth' })
                if ($sel.Count -eq 0) { $sel = $all }
            }
            if ($prevAdapter -ne $want) { $prevT = $null; $prevAdapter = $want }
            $rx = 0L; $tx = 0L; $names = @()
            foreach ($ni in $sel) { $st = $ni.GetIPStatistics(); $rx += $st.BytesReceived; $tx += $st.BytesSent; $names += $ni.Name }
            $now = $sw.Elapsed.TotalSeconds
            if ($null -ne $prevT) {
                $dt = $now - $prevT
                if ($dt -gt 0) { $s.Down = [Math]::Max(0, ($rx - $prevRx) / $dt); $s.Up = [Math]::Max(0, ($tx - $prevTx) / $dt) }
            }
            $prevRx = $rx; $prevTx = $tx; $prevT = $now
            $s.NetNames = $names -join ', '
        } catch { [void]$s.Err.Add("net: $_") }

        try {
            $s.Disks = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk |
                Where-Object { $_.Name -match '^[A-Z]:$' } | Sort-Object Name | ForEach-Object {
                    @{ Name = $_.Name; Read = [double]$_.DiskReadBytesPersec; Write = [double]$_.DiskWriteBytesPersec; Busy = [Math]::Min(100.0, [double]$_.PercentDiskTime) }
                })
        } catch { [void]$s.Err.Add("disk: $_") }

        try {
            if ($nvsmi) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo($nvsmi, '--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,name --format=csv,noheader,nounits')
                $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $out = $p.StandardOutput.ReadLine(); [void]$p.WaitForExit(2000)
                if ($out) {
                    $f = $out -split ',\s*'
                    $s.Gpu = [double]$f[0]; $s.VramUsed = [double]$f[1] * 1MB; $s.VramTotal = [double]$f[2] * 1MB; $s.GpuTemp = [double]$f[3]; $s.GpuName = $f[4]
                }
            } else {
                $byType = @{}
                foreach ($e in Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine) {
                    if ($e.Name -match 'engtype_(.+)$') { $t = $Matches[1]; $byType[$t] = [double]$byType[$t] + [double]$e.UtilizationPercentage }
                }
                $max = 0.0; foreach ($v in $byType.Values) { if ($v -gt $max) { $max = $v } }
                $s.Gpu = [Math]::Min(100.0, $max)
                $used = 0.0
                foreach ($m in Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory) { if ([double]$m.DedicatedUsage -gt $used) { $used = [double]$m.DedicatedUsage } }
                $s.VramUsed = $used; $s.VramTotal = $vramTotal; $s.GpuName = $gpuName
            }
        } catch { [void]$s.Err.Add("gpu: $_") }

        if ($tick % 2 -eq 0) {
            try {
                $now = $sw.Elapsed.TotalSeconds; $cur = @{}; $best = $null; $bestPct = 0.0
                foreach ($p in Get-Process) {
                    if ($p.Id -le 4) { continue }
                    try { $ms = $p.TotalProcessorTime.TotalMilliseconds } catch { continue }
                    $cur[$p.Id] = $ms
                    if ($null -ne $prevProcT -and $prevProc.ContainsKey($p.Id)) {
                        $pct = ($ms - $prevProc[$p.Id]) / (($now - $prevProcT) * 1000) / $cores * 100
                        if ($pct -gt $bestPct) { $bestPct = $pct; $best = $p.ProcessName }
                    }
                }
                $prevProc = $cur; $prevProcT = $now
                if ($best) { $topName = $best; $topPct = [Math]::Min(100.0, $bestPct) }
            } catch { [void]$s.Err.Add("top: $_") }
        }
        if ($topName) { $s.TopName = $topName; $s.TopPct = $topPct }

        if ($tick % 10 -eq 0) {
            try {
                $b = Get-CimInstance Win32_Battery | Select-Object -First 1
                $bat = if ($b) { @{ Pct = [double]$b.EstimatedChargeRemaining; Status = [int]$b.BatteryStatus; Mins = [int]$b.EstimatedRunTime } } else { $null }
            } catch { $bat = $null }
        }
        if ($bat) { $s.Battery = $bat }

        $sync.Queue.Enqueue($s)
        $tick++
        $wait = [int]([double]$sync.Interval - ($sw.Elapsed.TotalMilliseconds - $start))
        Start-Sleep -Milliseconds ([Math]::Max(50, $wait))
    }
}

$sync = [hashtable]::Synchronized(@{ Run = $true; Interval = [double]$script:Settings.Interval; Adapter = [string]$script:Settings.Adapter
                                     Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)) })
$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$worker = [powershell]::Create(); $worker.Runspace = $rs
[void]$worker.AddScript($workerScript.ToString())
$workerHandle = $worker.BeginInvoke()

# ---------------------------------------------------------------- UI helpers
$BrushConv = New-Object System.Windows.Media.BrushConverter
function Brush([string]$hex) { $b = $BrushConv.ConvertFromString($hex); $b.Freeze(); $b }
function Thick([double]$l, [double]$t, [double]$r, [double]$b) { New-Object System.Windows.Thickness($l, $t, $r, $b) }
function Glyph([int]$code) { [string][char]$code }

$C = @{
    Bg = '#0B0D10'; Surface = '#11151A'; Raised = '#171C22'; Line = '#232930'; Line2 = '#2E3640'
    Text = '#E8EDF2'; Dim = '#8A94A0'; Faint = '#5A6470'; Track = '#1A2026'
}
$Palette = @{ Text = Brush $C.Text; Dim = Brush $C.Dim; Faint = Brush $C.Faint; Track = Brush $C.Track; Line = Brush $C.Line }
$MonoFont = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas')
$IconFont = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
function Accent-Hex { $Accents[[string]$script:Settings.Accent] }

# ---------------------------------------------------------------- overlay rows
function New-Row([string]$Id, [string]$Label, [string]$Color, [string]$Key, [bool]$Pct = $true, [double]$MinScale = 1, [bool]$BarHidden = $false, [bool]$HasSpark = $true) {
    $accent = Brush $Color
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = Thick 0 2 0 2; $g.Visibility = 'Collapsed'
    foreach ($w in @([System.Windows.GridLength]::Auto, (New-Object System.Windows.GridLength(1, 'Star')), [System.Windows.GridLength]::Auto)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd)
    }
    foreach ($h in @([System.Windows.GridLength]::Auto, [System.Windows.GridLength]::Auto)) {
        $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = $h; $g.RowDefinitions.Add($rd)
    }

    $rail = New-Object System.Windows.Controls.Border
    $rail.Width = 3; $rail.CornerRadius = New-Object System.Windows.CornerRadius(1.5); $rail.Background = $accent; $rail.Margin = Thick 0 2 0 0
    [System.Windows.Controls.Grid]::SetRowSpan($rail, 2); $g.Children.Add($rail) | Out-Null

    $text = New-Object System.Windows.Controls.StackPanel
    $text.Margin = Thick 10 0 10 0; $text.VerticalAlignment = 'Center'
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Label.ToUpperInvariant(); $lbl.FontSize = 9; $lbl.FontWeight = 'SemiBold'; $lbl.Foreground = $Palette.Dim
    $val = New-Object System.Windows.Controls.TextBlock
    $val.Text = '--'; $val.FontSize = 14; $val.FontFamily = $MonoFont; $val.Foreground = $Palette.Text; $val.Margin = Thick 0 0 0 0
    $text.Children.Add($lbl) | Out-Null; $text.Children.Add($val) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($text, 1); $g.Children.Add($text) | Out-Null

    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = 84; $cv.Height = 24; $cv.VerticalAlignment = 'Center'; $cv.ClipToBounds = $true; $cv.Margin = Thick 0 0 0 0
    $fill = New-Object System.Windows.Shapes.Polygon; $fill.Fill = $accent; $fill.Opacity = 0.16
    $line = New-Object System.Windows.Shapes.Polyline; $line.Stroke = $accent; $line.StrokeThickness = 1.5; $line.StrokeLineJoin = 'Round'
    $cv.Children.Add($fill) | Out-Null; $cv.Children.Add($line) | Out-Null
    if (-not $HasSpark) { $cv.Visibility = 'Collapsed' }
    [System.Windows.Controls.Grid]::SetColumn($cv, 2); $g.Children.Add($cv) | Out-Null

    $track = New-Object System.Windows.Controls.Grid
    $track.Height = 2; $track.Margin = Thick 10 4 0 0; $track.Background = $Palette.Track
    $fc = New-Object System.Windows.Controls.ColumnDefinition; $fc.Width = New-Object System.Windows.GridLength(0, 'Star')
    $rc = New-Object System.Windows.Controls.ColumnDefinition; $rc.Width = New-Object System.Windows.GridLength(100, 'Star')
    $track.ColumnDefinitions.Add($fc); $track.ColumnDefinitions.Add($rc)
    $tf = New-Object System.Windows.Controls.Border; $tf.Background = $accent
    $track.Children.Add($tf) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($track, 1); [System.Windows.Controls.Grid]::SetColumn($track, 1); [System.Windows.Controls.Grid]::SetColumnSpan($track, 2)
    $g.Children.Add($track) | Out-Null

    @{ Id = $Id; LabelText = $Label; Key = $Key; Grid = $g; Text = $text; Label = $lbl; Value = $val; Spark = $cv; Line = $line; Fill = $fill
       Track = $track; FillCol = $fc; RestCol = $rc; Hist = New-Object 'System.Collections.Generic.Queue[double]'
       Pct = $Pct; MinScale = $MinScale; BarHidden = $BarHidden; HasSpark = $HasSpark; HasData = $false }
}

function Update-Spark($row, [double]$v) {
    $h = $row.Hist; $h.Enqueue($v)
    while ($h.Count -gt 60) { [void]$h.Dequeue() }
    $max = $row.MinScale
    if ($row.Pct) { $max = 100 } else { foreach ($x in $h) { if ($x -gt $max) { $max = $x } } }
    $p = [Math]::Min(100.0, $v / $max * 100)
    $row.FillCol.Width = New-Object System.Windows.GridLength($p, 'Star')
    $row.RestCol.Width = New-Object System.Windows.GridLength((100 - $p), 'Star')
    if ($row.Spark.Visibility -ne 'Visible') { return }
    $w = 84.0; $hh = 24.0; $n = $h.Count; $i = 0
    $pts = New-Object System.Windows.Media.PointCollection
    foreach ($x in $h) {
        $px = $w * ($i + (60 - $n)) / 59.0
        $py = $hh - [Math]::Min(1.0, $x / $max) * ($hh - 2) - 1
        $pts.Add((New-Object System.Windows.Point($px, $py))); $i++
    }
    $poly = New-Object System.Windows.Media.PointCollection
    foreach ($pt in $pts) { $poly.Add($pt) }
    if ($n -gt 0) { $poly.Add((New-Object System.Windows.Point($pts[$n - 1].X, $hh))); $poly.Add((New-Object System.Windows.Point($pts[0].X, $hh))) }
    $row.Line.Points = $pts; $row.Fill.Points = $poly
}

function Update-RowVisibility($row) {
    $S = $script:Settings; $bar = $S.Mode -eq 'Bar'
    $on = $row.HasData -and ($S[$row.Key] -ne $false) -and -not ($bar -and $row.BarHidden)
    if ($on -and $row.Id -like 'disk_*' -and $S.DisksMode -eq 'System') { $on = $row.LabelText -eq $env:SystemDrive }
    $want = if ($on) { 'Visible' } else { 'Collapsed' }
    if ($row.Grid.Visibility -ne $want) { $row.Grid.Visibility = $want }
}
function Set-RowValue($row, [string]$text, $spark) {
    if ($row.Value.Text -ne $text) { $row.Value.Text = $text }
    if ($null -ne $spark) { Update-Spark $row ([double]$spark) }
    if (-not $row.HasData) { $row.HasData = $true; Update-RowVisibility $row }
}

# ---------------------------------------------------------------- overlay window
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Glance" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight" ShowActivated="False"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
        FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border x:Name="Root" CornerRadius="8" Padding="12,8,12,10" BorderThickness="1" BorderBrush="#2A313B">
    <StackPanel x:Name="Outer" Orientation="Vertical">
      <Grid x:Name="Header" Height="20" Margin="0,0,0,2" Opacity="0.75">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border x:Name="Mark" Width="7" Height="7" CornerRadius="1.5" Margin="1,0,8,0" VerticalAlignment="Center"/>
          <TextBlock Text="GLANCE" FontSize="9" FontWeight="Bold" Foreground="#8A94A0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="BtnSettings" Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#8A94A0" Margin="6,0" Cursor="Hand" ToolTip="Settings"/>
          <TextBlock x:Name="BtnHide" Text="&#xE921;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#8A94A0" Margin="6,0,0,0" Cursor="Hand" ToolTip="Hide (tray icon to restore)"/>
        </StackPanel>
      </Grid>
      <Border x:Name="HeaderLine" Height="1" Background="#232930" Margin="0,0,0,4"/>
      <StackPanel x:Name="Rows" Orientation="Vertical" MinWidth="232"/>
    </StackPanel>
  </Border>
</Window>
'@
$win = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'Root','Outer','Header','HeaderLine','Mark','BtnSettings','BtnHide','Rows') { Set-Variable -Name $n -Value $win.FindName($n) }
$BgBrush = $BrushConv.ConvertFromString($C.Bg); $Root.Background = $BgBrush
$RowsPanel = $Rows

$script:Rows = [ordered]@{}
$Rows['cpu']    = New-Row 'cpu'    'CPU'      '#F5A524' 'ShowCpu'
$Rows['ram']    = New-Row 'ram'    'Memory'   '#4FD1A5' 'ShowRam'
$Rows['gpu']    = New-Row 'gpu'    'GPU'      '#FF6E4F' 'ShowGpu'
$Rows['down']   = New-Row 'down'   ($CH.Down + ' Download') '#5DB7F0' 'ShowNet' $false 50KB
$Rows['up']     = New-Row 'up'     ($CH.Up + ' Upload')     '#C3D94E' 'ShowNet' $false 50KB
$DiskPanel = New-Object System.Windows.Controls.StackPanel; $DiskPanel.Orientation = 'Vertical'
$Rows['top']    = New-Row 'top'    'Top process' '#E8EDF2' 'ShowTop'     $true 1 $true  $false
$Rows['uptime'] = New-Row 'uptime' 'Uptime'      '#8A94A0' 'ShowUptime'  $true 1 $true  $false
$Rows['bat']    = New-Row 'bat'    'Battery'     '#4FD1A5' 'ShowBattery'
foreach ($r in $Rows.Values) {
    if ($r.Id -eq 'top') { $RowsPanel.Children.Add($DiskPanel) | Out-Null }
    $RowsPanel.Children.Add($r.Grid) | Out-Null
}
foreach ($id in 'top','uptime') { $Rows[$id].Track.Visibility = 'Collapsed' }

function Apply-Appearance {
    $BgBrush.Opacity = [double]$script:Settings.BgAlpha
    $Root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform([double]$script:Settings.Scale, [double]$script:Settings.Scale)
    $acc = Brush (Accent-Hex)
    $Mark.Background = $acc
    if ($script:Set) { $script:Set.Resources['Accent'] = $acc }
}

function Apply-Mode {
    $S = $script:Settings; $bar = $S.Mode -eq 'Bar'
    $orient = if ($bar) { 'Horizontal' } else { 'Vertical' }
    $RowsPanel.Orientation = $orient; $DiskPanel.Orientation = $orient
    $RowsPanel.MinWidth = if ($bar) { 0 } else { 232 }
    $a = [string]$S.Anchor
    $Root.CornerRadius = if (-not $bar) { New-Object System.Windows.CornerRadius(8) }
                         elseif ($a -like 'Top*')    { New-Object System.Windows.CornerRadius(0, 0, 8, 8) }
                         elseif ($a -like 'Bottom*') { New-Object System.Windows.CornerRadius(8, 8, 0, 0) }
                         else { New-Object System.Windows.CornerRadius(8) }
    $Root.Padding = if ($bar) { Thick 12 4 12 5 } else { Thick 12 8 12 10 }
    $hv = if (-not $bar -and $S.ShowHeader) { 'Visible' } else { 'Collapsed' }
    $Header.Visibility = $hv; $HeaderLine.Visibility = $hv
    foreach ($r in $Rows.Values) {
        $r.Text.Orientation = $orient
        $r.Text.Margin = if ($bar) { Thick 8 0 0 0 } else { Thick 10 0 10 0 }
        $r.Grid.Margin = if ($bar) { Thick 6 0 10 0 } else { Thick 0 2 0 2 }
        $r.Label.Margin = if ($bar) { Thick 0 0 8 0 } else { Thick 0 0 0 0 }
        $r.Label.VerticalAlignment = 'Center'; $r.Value.VerticalAlignment = 'Center'
        $r.Value.FontSize = if ($bar) { 13 } else { 14 }
        $r.Value.Margin = Thick 0 0 0 0
        $r.Spark.Visibility = if (-not $bar -and $S.ShowSparklines -and $r.HasSpark) { 'Visible' } else { 'Collapsed' }
        $r.Track.Visibility = if (-not $bar -and $S.ShowBars -and $r.Id -notin 'top','uptime') { 'Visible' } else { 'Collapsed' }
        Update-RowVisibility $r
    }
}
function Apply-Visibility { foreach ($r in $Rows.Values) { Update-RowVisibility $r } }

function Clamp-Position([double]$l, [double]$t, [double]$w, [double]$h) {
    $sp = [System.Windows.SystemParameters]
    $l = [Math]::Max($sp::VirtualScreenLeft, [Math]::Min($l, $sp::VirtualScreenLeft + $sp::VirtualScreenWidth - $w))
    $t = [Math]::Max($sp::VirtualScreenTop,  [Math]::Min($t, $sp::VirtualScreenTop + $sp::VirtualScreenHeight - $h))
    @($l, $t)
}
function Apply-Position {
    if (-not $win.IsLoaded) { return }
    $win.UpdateLayout()
    $w = $win.ActualWidth; $h = $win.ActualHeight; $S = $script:Settings
    $bar = $S.Mode -eq 'Bar'; $a = [string]$S.Anchor
    $l = $null; $t = $null
    if ($a -eq 'Custom') {
        if ($bar) { $l = $S.BarLeft; $t = $S.BarTop } else { $l = $S.PanelLeft; $t = $S.PanelTop }
        if ($null -eq $l -or $null -eq $t) { $a = if ($bar) { 'TopCenter' } else { 'TopRight' } }
    }
    if ($a -ne 'Custom') {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $m = if ($bar) { 0 } else { 16 }
        $l = switch -Wildcard ($a) { '*Left' { $wa.Left + $m } '*Right' { $wa.Right - $w - $m } default { $wa.Left + ($wa.Width - $w) / 2 } }
        $t = switch -Wildcard ($a) { 'Top*' { $wa.Top + $m } 'Bottom*' { $wa.Bottom - $h - $m } default { $wa.Top + ($wa.Height - $h) / 2 } }
    }
    $pos = Clamp-Position ([double]$l) ([double]$t) $w $h
    $win.Left = $pos[0]; $win.Top = $pos[1]
}
function Save-Position {
    if ($script:Settings.Mode -eq 'Bar') { $script:Settings.BarLeft = $win.Left; $script:Settings.BarTop = $win.Top }
    else { $script:Settings.PanelLeft = $win.Left; $script:Settings.PanelTop = $win.Top }
    $script:Settings.Anchor = 'Custom'
    Apply-Mode; Refresh-SettingsUI; Save-Settings
}
function Set-Anchor([string]$a) { $script:Settings.Anchor = $a; Apply-Setting 'Anchor'; Refresh-SettingsUI }
function Reset-Position {
    foreach ($k in 'PanelLeft','PanelTop','BarLeft','BarTop') { $script:Settings[$k] = $null }
    Set-Anchor 'TopRight'
}

$script:Hwnd = [IntPtr]::Zero
function Apply-ExStyle {
    if ($script:Hwnd -eq [IntPtr]::Zero) { return }
    $ex = [Glance.Native]::GetExStyle($script:Hwnd)
    $ex = $ex -bor 0x80 -bor 0x08000000                                                              # TOOLWINDOW | NOACTIVATE
    if ($script:Settings.ClickThrough) { $ex = $ex -bor 0x20 } else { $ex = $ex -band (-bnot 0x20) } # TRANSPARENT
    [Glance.Native]::SetExStyle($script:Hwnd, $ex)
}
function Assert-Topmost { if ($script:Hwnd -ne [IntPtr]::Zero) { [void][Glance.Native]::SetWindowPos($script:Hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x13) } }

# ---------------------------------------------------------------- sample -> UI
function Apply-Sample($s) {
    $script:LastSample = $s
    if ($s.ContainsKey('Cpu')) {
        $t = '{0,3:0} %' -f $s.Cpu
        if ($s.CpuTemp) { $t += '   {0:0}{1}C' -f $s.CpuTemp, $CH.Deg }
        Set-RowValue $Rows['cpu'] $t $s.Cpu
    }
    if ($s.RamTotal) {
        Set-RowValue $Rows['ram'] ('{0:0.0} / {1:0.0} GB' -f ($s.RamUsed / 1GB), ($s.RamTotal / 1GB)) ($s.RamUsed / $s.RamTotal * 100)
    }
    if ($s.ContainsKey('Gpu')) {
        $t = '{0,3:0} %' -f $s.Gpu
        if ($s.VramTotal -gt 0) { $t += '  {0:0.0}/{1:0}G' -f ($s.VramUsed / 1GB), ($s.VramTotal / 1GB) }
        if ($s.GpuTemp) { $t += '  {0:0}{1}' -f $s.GpuTemp, $CH.Deg }
        Set-RowValue $Rows['gpu'] $t $s.Gpu
    }
    if ($s.ContainsKey('Down')) {
        Set-RowValue $Rows['down'] (Format-Rate $s.Down) $s.Down
        Set-RowValue $Rows['up']   (Format-Rate $s.Up)   $s.Up
    }
    foreach ($d in $s.Disks) {
        $id = 'disk_' + $d.Name.Substring(0, 1)
        if (-not $Rows.Contains($id)) {
            $r = New-Row $id $d.Name '#7F8FA6' 'ShowDisk'
            $r.Label.Text = 'Disk ' + $d.Name
            $Rows[$id] = $r; $DiskPanel.Children.Add($r.Grid) | Out-Null
            Apply-Mode
        }
        Set-RowValue $Rows[$id] ('R {0,-6} W {1,-6}' -f (Format-Short $d.Read), (Format-Short $d.Write)) $d.Busy
    }
    if ($s.TopName) { Set-RowValue $Rows['top'] ('{0}  {1:0} %' -f (Truncate-Text $s.TopName 14), $s.TopPct) $null }
    if ($s.Uptime) { $u = $s.Uptime; Set-RowValue $Rows['uptime'] ('{0}d {1:00}:{2:00}:{3:00}' -f $u.Days, $u.Hours, $u.Minutes, $u.Seconds) $null }
    if ($s.Battery) {
        $b = $s.Battery; $t = '{0:0} %' -f $b.Pct
        if ($b.Status -in 1, 4, 5) { if ($b.Mins -gt 0 -and $b.Mins -lt 71582788) { $t += '  {0}h{1:00}m' -f [int][Math]::Floor($b.Mins / 60), ($b.Mins % 60) } }
        else { $t += '  ' + $CH.Bolt }
        Set-RowValue $Rows['bat'] $t $b.Pct
    }
}
function Drain-Queue {
    $last = $null
    while ($sync.Queue.Count -gt 0) { $last = $sync.Queue.Dequeue() }
    if ($null -eq $last) { return $null }
    Apply-Sample $last
    $last
}

# ---------------------------------------------------------------- settings window
[xml]$setXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Glance Settings" Width="780" Height="560" MinWidth="680" MinHeight="460" WindowStartupLocation="CenterScreen"
        Background="#0B0D10" Foreground="#E8EDF2" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display" WindowStyle="None" ResizeMode="CanResize" ShowInTaskbar="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="46" GlassFrameThickness="0" CornerRadius="0" ResizeBorderThickness="6" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#F5A524"/>
    <SolidColorBrush x:Key="Text" Color="#E8EDF2"/>
    <SolidColorBrush x:Key="Dim" Color="#8A94A0"/>
    <SolidColorBrush x:Key="Faint" Color="#5A6470"/>
    <SolidColorBrush x:Key="Surface" Color="#11151A"/>
    <SolidColorBrush x:Key="Raised" Color="#171C22"/>
    <SolidColorBrush x:Key="Line" Color="#232930"/>
    <SolidColorBrush x:Key="Line2" Color="#2E3640"/>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Background="Transparent" CornerRadius="6" Padding="12,9" Margin="10,2">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <TextBlock x:Name="I" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Surface}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Raised}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
                <Setter TargetName="I" Property="Foreground" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="42" Height="22" CornerRadius="11" Background="{StaticResource Line2}" BorderBrush="Transparent" BorderThickness="1">
              <Ellipse x:Name="Knob" Width="14" Height="14" Fill="#C9D1D9" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="Knob" Property="Fill" Value="#0B0D10"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Track" Property="BorderBrush" Value="#55FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="0,3,6,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}" Margin="{TemplateBinding Margin}">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Line2}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="#0B0D10"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{StaticResource Raised}" BorderBrush="{StaticResource Line2}" BorderThickness="1" CornerRadius="5" Padding="14,7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#1F262E"/><Setter TargetName="B" Property="BorderBrush" Value="#3C4650"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="#0F1216"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="#FF8A74"/>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" Width="46" Height="46">
              <TextBlock Text="{TemplateBinding Content}" FontFamily="Segoe MDL2 Assets" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#C42B1C"/><Setter Property="Foreground" Value="White"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DarkSlider" TargetType="Slider">
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="24" Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="{StaticResource Line2}" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False" VerticalAlignment="Center">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="{DynamicResource Accent}" CornerRadius="2" Height="4"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent" Height="24"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="16" Height="16" Cursor="Hand">
                    <Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Fill="#E8EDF2" Stroke="{DynamicResource Accent}" StrokeThickness="2"/></ControlTemplate></Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Width="6" Background="Transparent" Margin="0,2">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="{StaticResource Line2}" CornerRadius="3"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border BorderBrush="{StaticResource Line}" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="46"/><RowDefinition/></Grid.RowDefinitions>
      <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition/></Grid.ColumnDefinitions>

      <Border Grid.RowSpan="2" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0"/>
      <StackPanel Orientation="Horizontal" Margin="20,0,0,0" VerticalAlignment="Center">
        <Border x:Name="SetMark" Width="10" Height="10" CornerRadius="2" Background="{DynamicResource Accent}" VerticalAlignment="Center"/>
        <TextBlock Text="GLANCE" FontSize="12" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Grid.Row="1" x:Name="NavPanel" Margin="0,8,0,0"/>
      <TextBlock Grid.Row="1" x:Name="SideFoot" Foreground="{StaticResource Faint}" FontSize="11" Margin="22,0,0,16" VerticalAlignment="Bottom"/>

      <Grid Grid.Column="1">
        <TextBlock x:Name="PageTitle" FontSize="13" Foreground="{StaticResource Dim}" Margin="32,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="BtnClose" Content="&#xE8BB;" Style="{StaticResource IconBtn}" HorizontalAlignment="Right" VerticalAlignment="Top" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="Close"/>
      </Grid>

      <Grid Grid.Row="1" Grid.Column="1">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="32,14,32,6">
          <TextBlock x:Name="PageHeading" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock x:Name="PageSub" Foreground="{StaticResource Dim}" Margin="0,4,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="32,6,26,10">
          <ContentControl x:Name="PageHost"/>
        </ScrollViewer>
        <Border Grid.Row="2" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="32,12">
          <Grid>
            <TextBlock x:Name="FootNote" Foreground="{StaticResource Faint}" FontSize="11.5" VerticalAlignment="Center" Text="Changes apply instantly and are saved automatically."/>
            <Button x:Name="BtnDone" Content="Done" Style="{StaticResource Btn}" HorizontalAlignment="Right" MinWidth="96"/>
          </Grid>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$script:Set = $null
$script:Bound = New-Object System.Collections.ArrayList
$script:Suppress = $false

function New-Text([string]$text, [double]$size = 13, $brush = $null, [string]$weight = 'Normal') {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.FontWeight = $weight; $tb.TextWrapping = 'Wrap'
    if ($brush) { $tb.Foreground = $brush }
    $tb
}
function New-Section([string]$title) {
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = Thick 0 14 0 4
    $h = New-Text $title.ToUpperInvariant() 10.5 (Brush (Accent-Hex)) 'Bold'
    $h.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Accent')
    $sp.Children.Add($h) | Out-Null
    $sp
}
function New-SettingRow([string]$title, [string]$desc, $control, [bool]$below = $false) {
    $b = New-Object System.Windows.Controls.Border
    $b.BorderThickness = Thick 0 0 0 1; $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Line'); $b.Padding = Thick 0 12 0 12
    $g = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $txt = New-Object System.Windows.Controls.StackPanel; $txt.VerticalAlignment = 'Center'; $txt.Margin = Thick 0 0 24 0
    $txt.Children.Add((New-Text $title 13 $Palette.Text 'SemiBold')) | Out-Null
    if ($desc) { $d = New-Text $desc 11.5 $Palette.Dim; $d.Margin = Thick 0 2 0 0; $txt.Children.Add($d) | Out-Null }
    $g.Children.Add($txt) | Out-Null
    if ($below) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Children.Add($g) | Out-Null; $control.Margin = Thick 0 10 0 0; $sp.Children.Add($control) | Out-Null
        $b.Child = $sp
    } else {
        $control.VerticalAlignment = 'Center'; [System.Windows.Controls.Grid]::SetColumn($control, 1); $g.Children.Add($control) | Out-Null
        $b.Child = $g
    }
    $b
}

function New-Switch([string]$key, [string]$title, [string]$desc) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $script:Set.Resources['Switch']; $cb.Tag = $key; $cb.IsChecked = [bool]$script:Settings[$key]
    $h = { param($sender, $e) if ($script:Suppress) { return }; $script:Settings[$sender.Tag] = [bool]$sender.IsChecked; Apply-Setting $sender.Tag }
    $cb.Add_Checked($h); $cb.Add_Unchecked($h)
    [void]$script:Bound.Add(@{ Kind = 'Switch'; Key = $key; Control = $cb })
    New-SettingRow $title $desc $cb
}
function New-ActionSwitch([string]$title, [string]$desc, [bool]$state, [scriptblock]$onChange) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $script:Set.Resources['Switch']; $cb.IsChecked = $state
    $cb.Add_Checked($onChange); $cb.Add_Unchecked($onChange)
    New-SettingRow $title $desc $cb
}
function New-SliderRow([string]$key, [string]$title, [string]$desc, [double]$min, [double]$max, [double]$step, [scriptblock]$fmt) {
    $wrap = New-Object System.Windows.Controls.Grid; $wrap.Width = 260
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(64)
    $wrap.ColumnDefinitions.Add($c1); $wrap.ColumnDefinitions.Add($c2)
    $sl = New-Object System.Windows.Controls.Slider
    $sl.Style = $script:Set.Resources['DarkSlider']; $sl.Minimum = $min; $sl.Maximum = $max; $sl.TickFrequency = $step; $sl.IsSnapToTickEnabled = $true
    $sl.Value = [double]$script:Settings[$key]
    $lbl = New-Text (& $fmt $sl.Value) 12.5 $Palette.Text; $lbl.FontFamily = $MonoFont; $lbl.HorizontalAlignment = 'Right'; $lbl.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($lbl, 1)
    $sl.Tag = @{ Key = $key; Label = $lbl; Fmt = $fmt }
    $sl.Add_ValueChanged({ param($sender, $e)
        $t = $sender.Tag; $t.Label.Text = (& $t.Fmt $sender.Value)
        if ($script:Suppress) { return }
        $script:Settings[$t.Key] = [double]$sender.Value; Apply-Setting $t.Key
    })
    $wrap.Children.Add($sl) | Out-Null; $wrap.Children.Add($lbl) | Out-Null
    [void]$script:Bound.Add(@{ Kind = 'Slider'; Key = $key; Control = $sl })
    New-SettingRow $title $desc $wrap
}
function New-ChipGroup([string]$key, $options) {
    $wp = New-Object System.Windows.Controls.WrapPanel
    $grp = "grp_$key"
    foreach ($o in $options) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $script:Set.Resources['Chip']; $rb.GroupName = $grp; $rb.Content = $o.Label; $rb.Tag = @{ Key = $key; Value = $o.Value }
        $rb.IsChecked = ([string]$script:Settings[$key] -eq [string]$o.Value)
        $rb.Add_Checked({ param($sender, $e) if ($script:Suppress) { return }; $script:Settings[$sender.Tag.Key] = $sender.Tag.Value; Apply-Setting $sender.Tag.Key })
        $wp.Children.Add($rb) | Out-Null
        [void]$script:Bound.Add(@{ Kind = 'Chip'; Key = $key; Control = $rb })
    }
    $wp
}
function New-ChoiceRow([string]$key, [string]$title, [string]$desc, $options, [bool]$below = $false) { New-SettingRow $title $desc (New-ChipGroup $key $options) $below }
function New-ButtonRow([string]$title, [string]$desc, [string]$caption, [scriptblock]$onClick, [string]$style = 'Btn') {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = $caption; $btn.Style = $script:Set.Resources[$style]; $btn.Add_Click($onClick)
    New-SettingRow $title $desc $btn
}
function Opt([string]$label, $value) { @{ Label = $label; Value = $value } }

function New-AnchorPicker {
    $frame = New-Object System.Windows.Controls.Border
    $frame.Width = 236; $frame.Height = 136; $frame.CornerRadius = New-Object System.Windows.CornerRadius(6); $frame.Padding = Thick 6 6 6 6
    $frame.HorizontalAlignment = 'Left'; $frame.BorderThickness = Thick 1 1 1 1
    $frame.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Surface')
    $frame.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Line2')
    $grid = New-Object System.Windows.Controls.Primitives.UniformGrid; $grid.Rows = 3; $grid.Columns = 3
    $arrows = @{ TopLeft = 0x2196; TopCenter = 0x2191; TopRight = 0x2197; MiddleLeft = 0x2190; MiddleRight = 0x2192; BottomLeft = 0x2199; BottomCenter = 0x2193; BottomRight = 0x2198 }
    foreach ($k in $AnchorNames.Keys) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $script:Set.Resources['Chip']; $rb.GroupName = 'grp_Anchor'; $rb.Margin = Thick 3 3 3 3; $rb.Padding = Thick 0 0 0 0
        $rb.ToolTip = $AnchorNames[$k]
        if ($k -eq 'Custom') { $rb.Content = 'Free'; $rb.FontSize = 11 } else { $rb.Content = Glyph $arrows[$k]; $rb.FontSize = 15 }
        $rb.Tag = @{ Key = 'Anchor'; Value = $k }
        $rb.IsChecked = ([string]$script:Settings.Anchor -eq $k)
        $rb.Add_Checked({ param($sender, $e) if ($script:Suppress) { return }; $script:Settings.Anchor = $sender.Tag.Value; Apply-Setting 'Anchor' })
        $grid.Children.Add($rb) | Out-Null
        [void]$script:Bound.Add(@{ Kind = 'Chip'; Key = 'Anchor'; Control = $rb })
    }
    $frame.Child = $grid
    $frame
}

function Refresh-SettingsUI {
    $script:Suppress = $true
    try {
        foreach ($b in $script:Bound) {
            switch ($b.Kind) {
                'Switch' { $b.Control.IsChecked = [bool]$script:Settings[$b.Key] }
                'Slider' { $b.Control.Value = [double]$script:Settings[$b.Key] }
                'Chip'   { $b.Control.IsChecked = ([string]$script:Settings[$b.Key] -eq [string]$b.Control.Tag.Value) }
            }
        }
        if ($script:StartupSwitch) { $script:StartupSwitch.IsChecked = Test-Path (Get-StartupLink) }
    } finally { $script:Suppress = $false }
}

function Apply-Setting([string]$key) {
    switch -Regex ($key) {
        '^(BgAlpha|Scale|Accent)$'                 { Apply-Appearance; if ($key -eq 'Scale') { Apply-Position } }
        '^(Mode|Anchor|ShowSparklines|ShowBars|ShowHeader)$' { Apply-Mode; Apply-Position }
        '^(Show|DisksMode)'                        { Apply-Visibility; Apply-Position }
        '^ClickThrough$'                           { Apply-ExStyle }
        '^Interval$'                               { $sync.Interval = [double]$script:Settings.Interval }
        '^Adapter$'                                { $sync.Adapter = [string]$script:Settings.Adapter }
    }
    Request-Save
}
$saveTimer = New-Object System.Windows.Threading.DispatcherTimer
$saveTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$saveTimer.Add_Tick({ $saveTimer.Stop(); Save-Settings })
function Request-Save { $saveTimer.Stop(); $saveTimer.Start() }

function Build-AdapterChips {
    if (-not $script:AdapterHost) { return }
    $script:Bound = [System.Collections.ArrayList]@($script:Bound | Where-Object { $_.Key -ne 'Adapter' })
    $names = @()
    if ($script:LastSample -and $script:LastSample.Adapters) { $names = @($script:LastSample.Adapters) }
    $opts = @((Opt 'Auto (physical adapters)' ''))
    foreach ($n in $names) { $opts += Opt $n $n }
    if ($script:Settings.Adapter -and $names -notcontains $script:Settings.Adapter) { $opts += Opt "$($script:Settings.Adapter) (offline)" $script:Settings.Adapter }
    $script:AdapterHost.Child = New-ChipGroup 'Adapter' $opts
}

function New-SettingsWindow {
    $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $setXaml))
    $script:Set = $w
    $w.Resources['Accent'] = Brush (Accent-Hex)
    if ($AppExe) {
        try {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($AppExe)
            $w.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        } catch {}
    }
    foreach ($n in 'NavPanel','SideFoot','PageTitle','PageHeading','PageSub','PageHost','BtnClose','BtnDone') { Set-Variable -Name "S_$n" -Value $w.FindName($n) -Scope Script }
    $script:S_SideFoot.Text = if ($AppExe) { "v$Version  -  Glance.exe" } else { "v$Version  -  script mode" }

    $pages = [ordered]@{}

    # General
    $p = New-Object System.Windows.Controls.StackPanel
    $sec = New-Section 'Startup'
    $script:StartupSwitch = $null
    $row = New-ActionSwitch 'Start with Windows' 'Launches silently at sign-in through a Startup-folder shortcut.' (Test-Path (Get-StartupLink)) {
        param($sender, $e) if ($script:Suppress) { return }; Set-Startup ([bool]$sender.IsChecked) }
    $script:StartupSwitch = $row.Child.Children[1]
    $sec.Children.Add($row) | Out-Null; $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Overlay'
    $sec.Children.Add((New-ChoiceRow 'Mode' 'Layout' 'Panel floats anywhere; Bar docks as a thin strip at the top edge.' @((Opt 'Panel' 'Panel'), (Opt 'Top bar' 'Bar')))) | Out-Null
    $sec.Children.Add((New-Switch 'ClickThrough' 'Click-through' 'Mouse clicks pass through the overlay to whatever is underneath. Use the tray icon to get back here.')) | Out-Null
    $sec.Children.Add((New-Switch 'ShowHeader' 'Show header' 'Title strip with the settings and hide buttons (panel layout only).')) | Out-Null
    $sec.Children.Add((New-SettingRow 'Position' 'Pick a screen corner or edge. Dragging the overlay switches to Free. Bar layout snaps flush to the edge.' (New-AnchorPicker) $true)) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Sampling'
    $sec.Children.Add((New-SliderRow 'Interval' 'Refresh interval' 'How often metrics are sampled. Lower is smoother but uses a little more CPU.' 500 3000 250 { param($v) '{0:0.00} s' -f ($v / 1000) })) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $pages['General'] = @{ Icon = (Glyph 0xE713); Sub = 'Startup, layout and sampling behaviour.'; Panel = $p }

    # Appearance
    $p = New-Object System.Windows.Controls.StackPanel
    $sec = New-Section 'Surface'
    $sec.Children.Add((New-SliderRow 'BgAlpha' 'Background opacity' 'Transparency of the overlay surface. Text stays fully opaque.' 0.4 1.0 0.04 { param($v) '{0:0} %' -f ($v * 100) })) | Out-Null
    $sec.Children.Add((New-SliderRow 'Scale' 'Size' 'Scales the whole overlay. Useful on high-DPI or TV displays.' 0.8 1.5 0.05 { param($v) '{0:0} %' -f ($v * 100) })) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Style'
    $accOpts = @(); foreach ($k in $Accents.Keys) { $accOpts += Opt $k $k }
    $sec.Children.Add((New-ChoiceRow 'Accent' 'Accent colour' 'Used for the brand mark and controls. Metric colours are fixed for readability.' $accOpts)) | Out-Null
    $sec.Children.Add((New-Switch 'ShowSparklines' 'Sparklines' '60-second history graph next to each metric.')) | Out-Null
    $sec.Children.Add((New-Switch 'ShowBars' 'Usage tracks' 'Thin bar under each metric showing current load.')) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $pages['Appearance'] = @{ Icon = (Glyph 0xE790); Sub = 'Opacity, size, accent and detail level.'; Panel = $p }

    # Metrics
    $p = New-Object System.Windows.Controls.StackPanel
    $sec = New-Section 'Shown on the overlay'
    foreach ($m in @(
        @('ShowCpu','CPU','Total processor load, plus package temperature when the firmware exposes it.'),
        @('ShowRam','Memory','Physical RAM in use vs installed.'),
        @('ShowGpu','GPU','Load, VRAM and temperature. NVIDIA via nvidia-smi; others via Windows GPU counters.'),
        @('ShowNet','Network','Download and upload throughput.'),
        @('ShowDisk','Disks','Read / write throughput per drive letter.'),
        @('ShowTop','Top process','The process using the most CPU right now.'),
        @('ShowUptime','Uptime','Time since the last boot.'),
        @('ShowBattery','Battery','Charge and remaining time. Hidden automatically on desktops.'))) {
        $sec.Children.Add((New-Switch $m[0] $m[1] $m[2])) | Out-Null
    }
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Disks'
    $sec.Children.Add((New-ChoiceRow 'DisksMode' 'Which drives' '' @((Opt 'All drives' 'All'), (Opt "System drive only ($env:SystemDrive)" 'System')))) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $pages['Metrics'] = @{ Icon = (Glyph 0xE9D9); Sub = 'Choose which readouts appear.'; Panel = $p }

    # Network
    $p = New-Object System.Windows.Controls.StackPanel
    $sec = New-Section 'Units'
    $sec.Children.Add((New-ChoiceRow 'NetBits' 'Speed unit' 'ISPs advertise in bits; file transfers show bytes.' @((Opt 'Bytes  (KB/s, MB/s)' $false), (Opt 'Bits  (Kbps, Mbps)' $true)))) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Adapter'
    $script:AdapterHost = New-Object System.Windows.Controls.Border
    $sec.Children.Add((New-SettingRow 'Measured adapter' 'Auto sums every physical adapter that is up and skips virtual ones (Hyper-V, VPN, VMware).' $script:AdapterHost $true)) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $pages['Network'] = @{ Icon = (Glyph 0xE839); Sub = 'Units and which adapter is measured.'; Panel = $p }

    # About
    $p = New-Object System.Windows.Controls.StackPanel
    $sec = New-Section 'Glance'
    $about = New-Object System.Windows.Controls.StackPanel; $about.Margin = Thick 0 10 0 6
    $about.Children.Add((New-Text "Version $Version" 13 $Palette.Text 'SemiBold')) | Out-Null
    $t = New-Text 'A WPF overlay driven by PowerShell, compiled into one small executable. No runtime to download, no background service - only components already in Windows.' 12 $Palette.Dim; $t.Margin = Thick 0 4 0 0
    $about.Children.Add($t) | Out-Null
    $sec.Children.Add($about) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Files'
    $sec.Children.Add((New-ButtonRow 'Settings folder' $DataDir 'Open' { Start-Process explorer.exe -ArgumentList "`"$DataDir`"" })) | Out-Null
    $sec.Children.Add((New-ButtonRow $(if ($AppExe) { 'Install location' } else { 'Script location' }) $AppDir 'Open' { Start-Process explorer.exe -ArgumentList "`"$AppDir`"" })) | Out-Null
    $unins = Join-Path $AppDir 'Uninstall.cmd'
    if (Test-Path $unins) { $sec.Children.Add((New-ButtonRow 'Uninstall' 'Removes the app, shortcuts and the Apps & Features entry.' 'Uninstall...' { Start-Process cmd.exe -ArgumentList "/c `"`"$unins`"`"" } 'DangerBtn')) | Out-Null }
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Reset'
    $sec.Children.Add((New-ButtonRow 'Restore defaults' 'Resets every option and the overlay position. Start-with-Windows is left as is.' 'Reset all settings' {
        $script:Settings = $Defaults.Clone(); Refresh-SettingsUI
        Apply-Appearance; Apply-Mode; Apply-Visibility; Apply-ExStyle; Apply-Position
        $sync.Interval = [double]$script:Settings.Interval; $sync.Adapter = ''
        Save-Settings } 'DangerBtn')) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $pages['About'] = @{ Icon = (Glyph 0xE946); Sub = 'Version, files and reset.'; Panel = $p }

    $script:SetPages = $pages
    foreach ($name in $pages.Keys) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $w.Resources['Nav']; $rb.Content = $name; $rb.Tag = $pages[$name].Icon; $rb.GroupName = 'nav'
        $rb.Add_Checked({ param($sender, $e) Show-SettingsPage ([string]$sender.Content) })
        $script:S_NavPanel.Children.Add($rb) | Out-Null
    }
    $script:S_NavPanel.Children[0].IsChecked = $true

    $w.Add_Closing({ param($sender, $e) if (-not $script:Quitting) { $e.Cancel = $true; $sender.Hide() } })
    $script:S_BtnClose.Add_Click({ $script:Set.Hide() })
    $script:S_BtnDone.Add_Click({ $script:Set.Hide() })
    $w.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Escape') { $sender.Hide() } })
    $w
}
function Show-SettingsPage([string]$name) {
    $pg = $script:SetPages[$name]
    $script:S_PageTitle.Text = "Settings  /  $name"; $script:S_PageHeading.Text = $name; $script:S_PageSub.Text = $pg.Sub
    $script:S_PageHost.Content = $pg.Panel
    foreach ($nav in $script:S_NavPanel.Children) { if ([string]$nav.Content -eq $name -and -not $nav.IsChecked) { $nav.IsChecked = $true } }
    if ($name -eq 'Network') { Build-AdapterChips }
}
function Show-Settings {
    if (-not $script:Set) { New-SettingsWindow | Out-Null }
    Refresh-SettingsUI; Build-AdapterChips
    $script:Set.Show(); $script:Set.WindowState = 'Normal'; $script:Set.Activate() | Out-Null
}

# ---------------------------------------------------------------- tray icon + menu
[System.Windows.Forms.Application]::EnableVisualStyles()
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 11, 13, 16))
    $col = [System.Drawing.ColorTranslator]::FromHtml((Accent-Hex))
    $br = New-Object System.Drawing.SolidBrush $col
    $g.FillRectangle($br, 2, 10, 3, 5); $g.FillRectangle($br, 6, 6, 3, 9); $g.FillRectangle($br, 10, 2, 3, 13)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
function Get-StartupLink { Join-Path ([Environment]::GetFolderPath('Startup')) 'Glance.lnk' }
function Set-Startup([bool]$on) {
    $lnk = Get-StartupLink
    if (-not $on) { Remove-Item $lnk -ErrorAction SilentlyContinue; return }
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($lnk)
    $vbs = Join-Path $AppDir 'Start-Glance.vbs'
    if ($AppExe) { $sc.TargetPath = $AppExe; $sc.Arguments = ''; $sc.IconLocation = "$AppExe,0" }
    elseif (Test-Path $vbs) { $sc.TargetPath = Join-Path $env:windir 'System32\wscript.exe'; $sc.Arguments = "`"$vbs`"" }
    else {
        $sc.TargetPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    }
    $sc.WorkingDirectory = $AppDir; $sc.Description = 'Glance overlay'; $sc.Save()
}
function Toggle-Visible { if ($win.IsVisible) { $win.Hide() } else { $win.Show(); Assert-Topmost } }
function New-MenuItem([string]$text, [scriptblock]$onClick) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    if ($onClick) { $mi.Add_Click($onClick) }
    $mi
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer
$miShow     = New-MenuItem 'Hide overlay'    { Toggle-Visible }
$miSettings = New-MenuItem 'Settings...'     { Show-Settings }
$miPanel    = New-MenuItem 'Panel layout'    { $script:Settings.Mode = 'Panel'; Apply-Setting 'Mode'; Refresh-SettingsUI }
$miBar      = New-MenuItem 'Top bar layout'  { $script:Settings.Mode = 'Bar';   Apply-Setting 'Mode'; Refresh-SettingsUI }
$miClick    = New-MenuItem 'Click-through'   { $script:Settings.ClickThrough = -not $script:Settings.ClickThrough; Apply-Setting 'ClickThrough'; Refresh-SettingsUI }
$miPos      = New-Object System.Windows.Forms.ToolStripMenuItem('Position')
foreach ($k in $AnchorNames.Keys) {
    if ($k -eq 'Custom') { continue }
    $mi = New-MenuItem $AnchorNames[$k] { param($sender, $e) Set-Anchor ([string]$sender.Tag) }
    $mi.Tag = $k; [void]$miPos.DropDownItems.Add($mi)
}
$miExit     = New-MenuItem 'Exit'            { Stop-App }
$miSettings.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
foreach ($item in @($miShow, $miSettings, '-', $miPanel, $miBar, $miPos, $miClick, '-', $miExit)) {
    if ($item -eq '-') { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) } else { [void]$menu.Items.Add($item) }
}
$menu.Add_Opening({
    $miShow.Text     = if ($win.IsVisible) { 'Hide overlay' } else { 'Show overlay' }
    $miPanel.Checked = $script:Settings.Mode -eq 'Panel'
    $miBar.Checked   = $script:Settings.Mode -eq 'Bar'
    $miClick.Checked = [bool]$script:Settings.ClickThrough
    foreach ($i in $miPos.DropDownItems) { $i.Checked = [string]$i.Tag -eq [string]$script:Settings.Anchor }
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon; $tray.Text = 'Glance'; $tray.ContextMenuStrip = $menu
$tray.Visible = -not $Headless
$tray.Add_MouseClick({ param($sender, $e) if ($e.Button -eq 'Left') { Toggle-Visible } })
$tray.Add_DoubleClick({ Show-Settings })
function Show-Menu {
    # NotifyIcon's own routine handles focus so the menu closes when clicking elsewhere.
    try { $tray.GetType().GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'NonPublic,Instance').Invoke($tray, $null) | Out-Null }
    catch { $menu.Show([System.Windows.Forms.Cursor]::Position) }
}

# ---------------------------------------------------------------- lifecycle
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:TickN = 0; $script:Quitting = $false

function Stop-App {
    $script:Quitting = $true; $sync.Run = $false
    try { $timer.Stop(); $saveTimer.Stop() } catch {}
    try { $tray.Visible = $false; $tray.Dispose() } catch {}
    Save-Settings
    try { if ($script:Set) { $script:Set.Close() } } catch {}
    try { $worker.Stop() } catch {}
    try { $worker.Dispose(); $rs.Close(); $rs.Dispose() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
    try { $app.Shutdown() } catch {}
}

$timer.Add_Tick({
    try {
        $s = Drain-Queue
        if ($s -and $s.ContainsKey('Down')) {
            $txt = 'Glance  {0}{1}  {2}{3}  CPU {4:0}%  RAM {5:0}%' -f $CH.Down, (Format-Rate $s.Down).Trim(), $CH.Up, (Format-Rate $s.Up).Trim(), $s.Cpu, ($s.RamUsed / $s.RamTotal * 100)
            if ($txt.Length -gt 63) { $txt = $txt.Substring(0, 63) }
            $tray.Text = $txt
        }
        $script:TickN++
        if ($script:TickN % 12 -eq 0 -and $win.IsVisible) { Assert-Topmost }
    } catch { Write-ErrorLog "tick: $_" }
})

$win.Add_SourceInitialized({ $script:Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle; Apply-ExStyle })
$win.Add_Loaded({ Apply-Position; $timer.Start() })
$win.Add_MouseLeftButtonDown({ param($sender, $e) try { $win.DragMove(); Save-Position } catch {} })
$win.Add_MouseRightButtonUp({ Show-Menu })
$win.Add_MouseEnter({ $Header.Opacity = 1.0 })
$win.Add_MouseLeave({ $Header.Opacity = 0.75 })
$BtnSettings.Add_MouseLeftButtonDown({ param($sender, $e) $e.Handled = $true; Show-Settings })
$BtnHide.Add_MouseLeftButtonDown({ param($sender, $e) $e.Handled = $true; $win.Hide() })
foreach ($b in $BtnSettings, $BtnHide) {
    $b.Add_MouseEnter({ param($sender, $e) $sender.Foreground = $Palette.Text })
    $b.Add_MouseLeave({ param($sender, $e) $sender.Foreground = $Palette.Dim })
}

Apply-Appearance
Apply-Mode

# ---------------------------------------------------------------- headless smoke test / screenshots
function Save-WindowShot($w, [string]$path) {
    $w.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Start-Sleep -Milliseconds 350
    $w.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $src = [System.Windows.PresentationSource]::FromVisual($w); $m = $src.CompositionTarget.TransformToDevice
    $x = [int]($w.Left * $m.M11); $y = [int]($w.Top * $m.M22); $cx = [int]($w.ActualWidth * $m.M11); $cy = [int]($w.ActualHeight * $m.M22)
    $bmp = New-Object System.Drawing.Bitmap $cx, $cy
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size); $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

if ($Headless) {
    $code = 0
    try {
        Start-Sleep -Milliseconds 3500
        $s = Drain-Queue
        if (-not $s) { throw 'worker produced no samples' }
        Write-Output "adapters : $($s.NetNames)  [all: $($s.Adapters -join ', ')]"
        if ($s.GpuName) { Write-Output "gpu      : $($s.GpuName)" }
        foreach ($r in $Rows.Values) { if ($r.Grid.Visibility -eq 'Visible') { Write-Output ('{0,-12} {1}' -f $r.LabelText, $r.Value.Text) } }
        if ($s.Err.Count) { Write-Output "errors   : $($s.Err -join ' | ')" }
        New-SettingsWindow | Out-Null
        foreach ($name in $script:SetPages.Keys) { Show-SettingsPage $name; Write-Output ('page {0,-10} sections={1}' -f $name, $script:SetPages[$name].Panel.Children.Count) }
        Build-AdapterChips; Refresh-SettingsUI
        Write-Output "bound    : $($script:Bound.Count) controls"
        if ($ShotDir) {
            New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
            $win.Add_Loaded({ Apply-Position; $timer.Start() })
            $shot = New-Object System.Windows.Threading.DispatcherTimer
            $shot.Interval = [TimeSpan]::FromMilliseconds(4500)
            $shot.Add_Tick({
                $shot.Stop()
                try {
                    $script:Settings.Mode = 'Panel'; $script:Settings.ClickThrough = $false; $script:Settings.BgAlpha = 1.0; Apply-Appearance; Apply-Mode; Apply-Position
                    Save-WindowShot $win (Join-Path $ShotDir 'overlay-panel.png')
                    $script:Settings.Mode = 'Bar'; Apply-Mode; Apply-Position
                    Save-WindowShot $win (Join-Path $ShotDir 'overlay-bar.png')
                    $script:Settings.Mode = 'Panel'; Apply-Mode; Apply-Position
                    Show-SettingsPage 'General'
                    Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-general.png')
                    $sv = [System.Windows.Media.VisualTreeHelper]::GetParent($script:S_PageHost); while ($sv -and $sv -isnot [System.Windows.Controls.ScrollViewer]) { $sv = [System.Windows.Media.VisualTreeHelper]::GetParent($sv) }
                    if ($sv) { $sv.ScrollToEnd(); Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-general-2.png'); $sv.ScrollToTop() }
                    Show-SettingsPage 'Appearance'
                    Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-appearance.png')
                } catch { Write-ErrorLog "shot failed: $_" }
                Stop-App
            })
            $win.Show(); $script:Set.Topmost = $true; $script:Set.Show(); $shot.Start()
            [void]$app.Run()
        }
    } catch { Write-Output "FAILED: $_"; $code = 1 }
    $sync.Run = $false
    try { $worker.Stop() } catch {}
    try { $tray.Dispose(); $rs.Close(); $mutex.ReleaseMutex() } catch {}
    exit $code
}

try {
    [void]$app.Run($win)
} catch {
    Write-ErrorLog "fatal: $_"
    try { [System.Windows.MessageBox]::Show("Glance crashed:`n$_", 'Glance') | Out-Null } catch {}
} finally {
    $sync.Run = $false
    try { $tray.Visible = $false; $tray.Dispose() } catch {}
    try { $worker.Stop(); $rs.Close() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
}
