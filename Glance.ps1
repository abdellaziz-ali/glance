#requires -Version 5.1
<#
  Glance - always-on-top CPU / RAM / GPU / disk / network overlay for Windows.
  Single script, no dependencies: Windows PowerShell 5.1 + WPF (both built into Windows).

  Run from source:    double-click Start-Glance.vbs  (or: powershell -STA -ExecutionPolicy Bypass -File .\Glance.ps1)
  Build .exe:         .\Build.ps1  ->  dist\Glance.exe + dist\Glance-Setup.exe (uses the csc.exe that ships with Windows)
  Smoke test:         $env:GLANCE_HEADLESS=1  (add $env:GLANCE_SHOT=<dir> to also save PNG screenshots)
  Settings:           %AppData%\Glance\settings.json  (or <app folder>\data\ when a file named 'portable' sits next to the exe/script)

  Overlay: drag = move, gear = settings, right-click = menu. Tray: left-click = show/hide, double-click = settings.
#>

$ErrorActionPreference = 'Stop'
$Version  = '2.3'
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
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder buf, int max);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
public static long GetExStyle(IntPtr h) { return IntPtr.Size == 8 ? GetWindowLongPtr(h, -20).ToInt64() : GetWindowLong32(h, -20); }
public static long GetStyle(IntPtr h) { return IntPtr.Size == 8 ? GetWindowLongPtr(h, -16).ToInt64() : GetWindowLong32(h, -16); }
public static void SetExStyle(IntPtr h, long v) { if (IntPtr.Size == 8) SetWindowLongPtr(h, -20, new IntPtr(v)); else SetWindowLong32(h, -20, (int)v); }
public static string ClassOf(IntPtr h) { var sb = new System.Text.StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
'@
[void][Glance.Native]::SetProcessDPIAware()

# Global hotkey needs a window procedure; a WinForms NativeWindow is the smallest host for one.
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System; using System.Windows.Forms; using System.Runtime.InteropServices;
namespace Glance {
  public class HotKeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public event EventHandler Pressed;
    bool registered;
    public HotKeyWindow() { CreateHandle(new CreateParams()); }
    public bool Register(uint mods, uint vk) { Unregister(); registered = RegisterHotKey(Handle, 1, mods | 0x4000, vk); return registered; }
    public void Unregister() { if (registered) { UnregisterHotKey(Handle, 1); registered = false; } }
    protected override void WndProc(ref Message m) { if (m.Msg == 0x0312 && Pressed != null) Pressed(this, EventArgs.Empty); base.WndProc(ref m); }
    public void Dispose() { Unregister(); DestroyHandle(); }
  }
}
'@

$mutexName = if ($Headless) { 'Local\Glance_Headless' } else { 'Local\Glance_SingleInstance' }
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

# ---------------------------------------------------------------- settings
$Portable     = (Test-Path (Join-Path $AppDir 'portable')) -or (Test-Path (Join-Path $AppDir 'portable.txt'))
$DataDir      = if ($Portable) { Join-Path $AppDir 'data' } else { Join-Path $env:APPDATA 'Glance' }
$SettingsPath = Join-Path $DataDir 'settings.json'
$SchemaVersion = 3
$Defaults = @{
    SchemaVersion = $SchemaVersion
    Mode = 'Panel'; Anchor = 'TopRight'; PanelLeft = $null; PanelTop = $null; BarLeft = $null; BarTop = $null; BarOrientation = 'Horizontal'; BarCompact = $false
    Monitor = ''; HideFullscreen = $false; Hotkey = ''
    BgAlpha = 0.92; Scale = 1.0; TextScale = 1.0; Accent = 'Amber'; ClickThrough = $false; ShowHeader = $true
    ShowSparklines = $true; ShowBars = $true; Interval = 1000
    ShowCpu = $true; ShowRam = $true; ShowGpu = $true; ShowNet = $true; ShowDisk = $true
    ShowTop = $true; ShowUptime = $true; ShowBattery = $true; ShowCores = $false; ShowGpuEngines = $false; ShowAdapter = $false
    Disks = @(); Order = @(); Colors = @{}; Icons = @{}; IconColors = @{}; Alerts = @{}; AlertColor = '#E5484D'
    NetBits = $false; Adapter = ''
}
$Accents = [ordered]@{ Amber = '#F5A524'; Mint = '#4FD1A5'; Ice = '#5DB7F0'; Coral = '#FF6E4F' }
$ColorGroups = [ordered]@{ cpu = 'CPU'; cores = 'CPU cores'; ram = 'Memory'; gpu = 'GPU'; gpueng = 'GPU engines'; net = 'Network'; adapter = 'Adapter'; disk = 'Disks'; top = 'Top process'; uptime = 'Uptime'; bat = 'Battery' }
$IconGroups  = [ordered]@{ cpu = 'CPU'; cores = 'CPU cores'; ram = 'Memory'; gpu = 'GPU'; gpueng = 'GPU engines'; down = 'Download'; up = 'Upload'; adapter = 'Adapter'; disk = 'Disks'; top = 'Top process'; uptime = 'Uptime'; bat = 'Battery' }
$RowColors   = @{ cpu = '#F5A524'; cores = '#F7C56B'; ram = '#4FD1A5'; gpu = '#FF6E4F'; gpueng = '#FF9A85'; down = '#5DB7F0'; up = '#C3D94E'; adapter = '#7FB8E8'; disk = '#7F8FA6'; top = '#E8EDF2'; uptime = '#8A94A0'; bat = '#4FD1A5' }
$RowIcons    = @{ cpu = 'E950'; cores = 'E9D9'; ram = 'E964'; gpu = 'F211'; gpueng = 'E7F4'; down = 'E896'; up = 'E898'; adapter = 'E839'; disk = 'EDA2'; top = 'E9F5'; uptime = 'E823'; bat = 'E83F' }
# One entry per toggle on the Metrics page; Rows lists the overlay rows it owns ('disk' stands for the per-drive panel).
$MetricDefs = @(
    @{ Id = 'cpu';     Key = 'ShowCpu';        Label = 'CPU';         Desc = 'Total processor load, plus package temperature when the firmware exposes it.'; Rows = @('cpu') }
    @{ Id = 'cores';   Key = 'ShowCores';      Label = 'CPU cores';   Desc = 'One bar per logical core, drawn as a compact text graph.'; Rows = @('cores') }
    @{ Id = 'ram';     Key = 'ShowRam';        Label = 'Memory';      Desc = 'Physical RAM in use vs installed.'; Rows = @('ram') }
    @{ Id = 'gpu';     Key = 'ShowGpu';        Label = 'GPU';         Desc = 'Load, VRAM and temperature. NVIDIA via nvidia-smi; others via Windows GPU counters.'; Rows = @('gpu') }
    @{ Id = 'gpueng';  Key = 'ShowGpuEngines'; Label = 'GPU engines'; Desc = 'Per-engine load from Windows (3D, Copy, Video decode/encode, Compute).'; Rows = @('gpueng') }
    @{ Id = 'net';     Key = 'ShowNet';        Label = 'Network';     Desc = 'Download and upload throughput.'; Rows = @('down','up') }
    @{ Id = 'adapter'; Key = 'ShowAdapter';    Label = 'Adapter';     Desc = 'Name of the measured adapter, with signal strength on Wi-Fi.'; Rows = @('adapter') }
    @{ Id = 'disk';    Key = 'ShowDisk';       Label = 'Disks';       Desc = 'Read / write throughput per drive letter.'; Rows = @('disk') }
    @{ Id = 'top';     Key = 'ShowTop';        Label = 'Top process'; Desc = 'The process using the most CPU right now.'; Rows = @('top') }
    @{ Id = 'uptime';  Key = 'ShowUptime';     Label = 'Uptime';      Desc = 'Time since the last boot.'; Rows = @('uptime') }
    @{ Id = 'bat';     Key = 'ShowBattery';    Label = 'Battery';     Desc = 'Charge and remaining time. Hidden automatically on desktops.'; Rows = @('bat') }
)
$AlertColors = [ordered]@{ Red = '#E5484D'; Coral = '#FF6E4F'; Amber = '#F5A524'; Gold = '#F2D45C'; Pink = '#F28CB1' }
$Blocks = [string[]]@([char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584, [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588)
# Segoe MDL2 Assets glyphs offered in the icon picker (all verified to render on Windows 10/11).
$IconCatalog = @('E950','E964','F211','EDA2','E896','E898','E9F5','E823','E83F','EDA3','E7F8','E770','E7F4','E9D9','E121','E917','EBAA','EBA9','E8B7','E745','E9CE','E71C','E8F1','E9E9','E8B2','E965','E9A6','E7F7','E955','E956','E957','E958','EC06','EC08','E70F','E77B','E8CB','E81E','E8EB','E8B0','E7EF','E97A','E9A8','EA18','EC7A','ED56','F0E2','F0E3','F08C','F0A0','E714','E7E8','E7E7','E7C4','EC4F')
$Swatches = [ordered]@{ Default = ''; Amber = '#F5A524'; Mint = '#4FD1A5'; Ice = '#5DB7F0'; Coral = '#FF6E4F'; Lime = '#C3D94E'; Gold = '#F2D45C'; Teal = '#39C5BB'; Pink = '#F28CB1'; Red = '#E5484D'; Slate = '#8A94A0' }
$AnchorNames = [ordered]@{
    TopLeft = 'Top left'; TopCenter = 'Top center'; TopRight = 'Top right'
    MiddleLeft = 'Middle left'; Custom = 'Free (dragged)'; MiddleRight = 'Middle right'
    BottomLeft = 'Bottom left'; BottomCenter = 'Bottom center'; BottomRight = 'Bottom right'
}

$MapKeys  = 'Colors','Icons','IconColors','Alerts'
$ListKeys = 'Disks','Order'
function New-DefaultSettings { $s = $Defaults.Clone(); foreach ($k in $ListKeys) { $s[$k] = @() }; foreach ($k in $MapKeys) { $s[$k] = @{} }; $s }
# Each entry upgrades a settings file from (version) to (version + 1); runs in order, so old files pass through every step.
$Migrations = @{
    1 = { param($j, $s) }                                                                                   # 2.0/2.1: nothing structural
    2 = { param($j, $s) if ($j.PSObject.Properties['DisksMode'] -and $j.DisksMode -eq 'System' -and @($s.Disks).Count -eq 0) { $s.Disks = @($env:SystemDrive) } }  # 2.2 -> 2.3
}
function Load-Settings {
    $s = New-DefaultSettings
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if (-not $s.ContainsKey($p.Name)) { continue }
                switch ($p.Name) {
                    { $_ -in $ListKeys } { $s[$p.Name] = @($p.Value | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
                    { $_ -in $MapKeys }  { $h = @{}; if ($p.Value) { foreach ($q in $p.Value.PSObject.Properties) { if ($null -ne $q.Value -and "$($q.Value)" -ne '') { $h[$q.Name] = $q.Value } } }; $s[$p.Name] = $h }
                    default              { $s[$p.Name] = $p.Value }
                }
            }
            $from = if ($j.PSObject.Properties['SchemaVersion']) { [int]$j.SchemaVersion } else { 1 }
            for ($v = $from; $v -lt $SchemaVersion; $v++) { if ($Migrations.ContainsKey($v)) { & $Migrations[$v] $j $s } }
        } catch {}
    }
    $s.SchemaVersion = $SchemaVersion
    if (-not $Accents.Contains([string]$s.Accent)) { $s.Accent = 'Amber' }
    if (-not $AnchorNames.Contains([string]$s.Anchor)) { $s.Anchor = 'TopRight' }
    if ([string]$s.AlertColor -notmatch '^#[0-9A-Fa-f]{6}$') { $s.AlertColor = $Defaults.AlertColor }
    $s
}
function Save-Settings {
    if ($Headless) { return }
    try {
        New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
        $tmp = "$SettingsPath.tmp"
        $script:Settings | ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $SettingsPath -Force
    } catch {}
}
$script:LoggedErrors = New-Object 'System.Collections.Generic.HashSet[string]'
function Write-ErrorLog([string]$msg, [switch]$Once) {
    if ($Once -and -not $script:LoggedErrors.Add($msg)) { return }
    try { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null; Add-Content -Path (Join-Path $DataDir 'error.log') -Value "$(Get-Date -Format s) $msg" } catch {}
}
# Settings written by the pre-rename "SysMonitor" builds are adopted on first run.
$legacyDir = Join-Path $env:APPDATA 'SysMonitor'
if (-not $Portable -and -not (Test-Path $SettingsPath) -and (Test-Path (Join-Path $legacyDir 'settings.json'))) {
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
    $diskHist = @{}
    $cpuTemp = $null; $thermalOk = $true; $bat = $null; $wifiSignal = $null
    $tick = 0

    while ($sync.Run) {
        $start = $sw.Elapsed.TotalMilliseconds
        $s = @{ Time = Get-Date; Err = New-Object System.Collections.ArrayList }

        try { $s.Cpu = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime } catch { [void]$s.Err.Add("cpu: $_") }

        if ($sync.WantCores) {
            try {
                $s.Cores = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object { $_.Name -match '^\d+$' } |
                             Sort-Object { [int]$_.Name } | ForEach-Object { [double]$_.PercentProcessorTime })
            } catch { [void]$s.Err.Add("cores: $_") }
        }

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
            if ($sync.WantAdapter -and $sel.Count -gt 0) {
                $ni0 = $sel[0]
                $s.AdapterName = $ni0.Name; $s.AdapterWifi = $ni0.NetworkInterfaceType -eq 'Wireless80211'
                if ($s.AdapterWifi) {
                    if ($tick % 5 -eq 0 -or $null -eq $wifiSignal) {
                        # netsh output is localised; the only '%' line inside an interface block is the signal.
                        $psi = New-Object System.Diagnostics.ProcessStartInfo('netsh.exe', 'wlan show interfaces')
                        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
                        $p = [System.Diagnostics.Process]::Start($psi); $txt = $p.StandardOutput.ReadToEnd(); [void]$p.WaitForExit(2000)
                        $m = [regex]::Match($txt, '(\d{1,3})\s*%')
                        $wifiSignal = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
                    }
                    if ($null -ne $wifiSignal) { $s.WifiSignal = $wifiSignal }
                }
            }
        } catch { [void]$s.Err.Add("net: $_") }

        try {
            $raw = @(Get-CimInstance Win32_PerfRawData_PerfDisk_LogicalDisk | Where-Object { $_.Name -match '^[A-Z]:$' } | Sort-Object Name)
            $list = New-Object System.Collections.ArrayList
            foreach ($d in $raw) {
                $cur = @{ T = [double]$d.Timestamp_Sys100NS; R = [double]$d.DiskReadBytesPersec; W = [double]$d.DiskWriteBytesPersec; I = [double]$d.PercentIdleTime }
                if (-not $diskHist.ContainsKey($d.Name)) { $diskHist[$d.Name] = New-Object 'System.Collections.Generic.Queue[hashtable]' }
                $q = $diskHist[$d.Name]; $q.Enqueue($cur)
                # Writes hit the disk in cache-flush bursts, so a 1 s window reads 0 most ticks; average over ~5 s.
                while ($q.Count -gt 1 -and ($cur.T - $q.Peek().T) -gt 50000000) { [void]$q.Dequeue() }
                $old = $q.Peek(); $dt = $cur.T - $old.T
                if ($dt -le 0) { continue }
                $sec = $dt / 1e7
                [void]$list.Add(@{ Name = $d.Name; Read = [Math]::Max(0.0, ($cur.R - $old.R) / $sec); Write = [Math]::Max(0.0, ($cur.W - $old.W) / $sec)
                                   Busy = [Math]::Max(0.0, [Math]::Min(100.0, 100 - ($cur.I - $old.I) / $dt * 100)) })
            }
            $s.Disks = @($list)
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

        if ($sync.WantEngines) {
            try {
                $eng = @{}
                foreach ($e in Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine) {
                    if ($e.Name -match 'engtype_(.+)$') { $t = $Matches[1]; $eng[$t] = [double]$eng[$t] + [double]$e.UtilizationPercentage }
                }
                $s.Engines = $eng
            } catch { [void]$s.Err.Add("gpueng: $_") }
        }

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
                                     WantCores = [bool]$script:Settings.ShowCores; WantEngines = [bool]$script:Settings.ShowGpuEngines; WantAdapter = [bool]$script:Settings.ShowAdapter
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
function Glyph-Hex([string]$hex) { [string][char][Convert]::ToInt32($hex, 16) }

# ---------------------------------------------------------------- overlay rows
function New-Row([string]$Id, [string]$Label, [string]$Color, [string]$Key, [bool]$Pct = $true, [double]$MinScale = 1, [bool]$BarHidden = $false, [bool]$HasSpark = $true, [bool]$NoTrack = $false) {
    $accent = Brush $Color
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = Thick 0 2 0 2; $g.Visibility = 'Collapsed'
    foreach ($w in @([System.Windows.GridLength]::Auto, (New-Object System.Windows.GridLength(1, 'Star')), [System.Windows.GridLength]::Auto)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd)
    }
    foreach ($h in @([System.Windows.GridLength]::Auto, [System.Windows.GridLength]::Auto)) {
        $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = $h; $g.RowDefinitions.Add($rd)
    }

    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.FontFamily = $IconFont; $icon.FontSize = 13
    $icon.VerticalAlignment = 'Center'; $icon.Width = 18; $icon.TextAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetRowSpan($icon, 2); $g.Children.Add($icon) | Out-Null

    $text = New-Object System.Windows.Controls.StackPanel
    $text.Margin = Thick 10 0 10 0; $text.VerticalAlignment = 'Center'
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Label.ToUpperInvariant(); $lbl.FontSize = 9; $lbl.FontWeight = 'SemiBold'; $lbl.Foreground = $Palette.Dim
    $val = New-Object System.Windows.Controls.TextBlock
    $val.Text = '--'; $val.FontSize = 14; $val.FontFamily = $MonoFont; $val.Foreground = $Palette.Text; $val.Margin = Thick 0 0 0 0
    $warn = New-Object System.Windows.Controls.TextBlock
    $warn.Text = Glyph 0xE7BA; $warn.FontFamily = $IconFont; $warn.FontSize = 10; $warn.Visibility = 'Collapsed'; $warn.VerticalAlignment = 'Center'; $warn.Margin = Thick 0 1 0 0
    $text.Children.Add($lbl) | Out-Null; $text.Children.Add($val) | Out-Null; $text.Children.Add($warn) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($text, 1); $g.Children.Add($text) | Out-Null

    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = 84; $cv.Height = 24; $cv.VerticalAlignment = 'Center'; $cv.ClipToBounds = $true; $cv.Margin = Thick 0 0 0 0
    $fill = New-Object System.Windows.Shapes.Polygon; $fill.Fill = $accent; $fill.Opacity = 0.16
    $line = New-Object System.Windows.Shapes.Polyline; $line.Stroke = $accent; $line.StrokeThickness = 1.5; $line.StrokeLineJoin = 'Round'
    $cv.Children.Add($fill) | Out-Null; $cv.Children.Add($line) | Out-Null
    if (-not $HasSpark) { $cv.Visibility = 'Collapsed' }
    [System.Windows.Controls.Grid]::SetColumn($cv, 2); $g.Children.Add($cv) | Out-Null

    $track = New-Object System.Windows.Controls.Grid
    $track.Height = 2; $track.Margin = Thick 8 4 0 0; $track.Background = $Palette.Track
    $fc = New-Object System.Windows.Controls.ColumnDefinition; $fc.Width = New-Object System.Windows.GridLength(0, 'Star')
    $rc = New-Object System.Windows.Controls.ColumnDefinition; $rc.Width = New-Object System.Windows.GridLength(100, 'Star')
    $track.ColumnDefinitions.Add($fc); $track.ColumnDefinitions.Add($rc)
    $tf = New-Object System.Windows.Controls.Border; $tf.Background = $accent
    $track.Children.Add($tf) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($track, 1); [System.Windows.Controls.Grid]::SetColumn($track, 1); [System.Windows.Controls.Grid]::SetColumnSpan($track, 2)
    $g.Children.Add($track) | Out-Null

    @{ Id = $Id; LabelText = $Label; Key = $Key; Color = $Color; Grid = $g; Icon = $icon; Text = $text; Label = $lbl; Value = $val; Warn = $warn; Spark = $cv; Line = $line; Fill = $fill
       Track = $track; FillCol = $fc; RestCol = $rc; Hist = New-Object 'System.Collections.Generic.Queue[double]'
       Pct = $Pct; MinScale = $MinScale; BarHidden = $BarHidden; HasSpark = $HasSpark; NoTrack = $NoTrack; HasData = $false; Alert = $false; Err = '' }
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
    if ($on -and $row.Id -like 'disk_*' -and @($S.Disks).Count -gt 0) { $on = @($S.Disks) -contains $row.LabelText }
    $want = if ($on) { 'Visible' } else { 'Collapsed' }
    if ($row.Grid.Visibility -ne $want) { $row.Grid.Visibility = $want }
}
function Get-ColorGroup([string]$id) { if ($id -in 'down','up') { 'net' } elseif ($id -like 'disk_*') { 'disk' } else { $id } }
function Get-IconGroup([string]$id) { if ($id -like 'disk_*') { 'disk' } else { $id } }
function Apply-RowColor($row) {
    $alert = Brush ([string]$script:Settings.AlertColor)
    $hex = [string]$script:Settings.Colors[(Get-ColorGroup $row.Id)]
    $row.Value.Foreground = if ($row.Alert) { $alert } elseif ($hex) { Brush $hex } else { $Palette.Text }
    $g = Get-IconGroup $row.Id
    $code = [string]$script:Settings.Icons[$g]; if (-not $code) { $code = $RowIcons[$g] }
    $row.Icon.Text = Glyph-Hex $code
    $ihex = [string]$script:Settings.IconColors[$g]; if (-not $ihex) { $ihex = $row.Color }
    $row.Icon.Foreground = if ($row.Alert) { $alert } else { Brush $ihex }
    $row.Warn.Foreground = $alert
}
function Apply-Colors { foreach ($r in $Rows.Values) { Apply-RowColor $r } }
function Set-RowAlert($row, [bool]$on) { if ($row.Alert -ne $on) { $row.Alert = $on; Apply-RowColor $row } }
function Set-RowError($row, [string]$msg) {
    if ($row.Err -eq $msg) { return }
    $row.Err = $msg
    $row.Warn.Visibility = if ($msg) { 'Visible' } else { 'Collapsed' }
    $row.Warn.ToolTip = if ($msg) { $msg } else { $null }
    if ($msg) { Write-ErrorLog "metric $($row.Id): $msg" -Once; if (-not $row.HasData) { $row.HasData = $true; Update-RowVisibility $row } }
}
function Alert-Limit([string]$k) { $v = $script:Settings.Alerts[$k]; if ($null -ne $v -and "$v" -ne '') { [double]$v } else { 0.0 } }
function Format-Blocks([double[]]$vals, [int]$maxCols = 32) {
    # Fold many cores into column pairs so the row never outgrows the panel.
    while ($vals.Count -gt $maxCols) { $vals = @(for ($i = 0; $i -lt $vals.Count; $i += 2) { if ($i + 1 -lt $vals.Count) { ($vals[$i] + $vals[$i + 1]) / 2 } else { $vals[$i] } }) }
    -join @($vals | ForEach-Object { $Blocks[[Math]::Min(7, [Math]::Max(0, [int][Math]::Floor($_ / 12.5)))] })
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
$EdgeBrush = $BrushConv.ConvertFromString('#2A313B'); $Root.BorderBrush = $EdgeBrush
$LineBrush = $BrushConv.ConvertFromString($C.Line); $HeaderLine.Background = $LineBrush
$TextShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$TextShadow.BlurRadius = 6; $TextShadow.ShadowDepth = 0; $TextShadow.Opacity = 0.9; $TextShadow.Color = [System.Windows.Media.Colors]::Black
$RowsPanel = $Rows

$script:Rows = [ordered]@{}
$Rows['cpu']     = New-Row 'cpu'     'CPU'         $RowColors.cpu     'ShowCpu'
$Rows['cores']   = New-Row 'cores'   'CPU cores'   $RowColors.cores   'ShowCores'      $true 1 $false $false $true
$Rows['ram']     = New-Row 'ram'     'Memory'      $RowColors.ram     'ShowRam'
$Rows['gpu']     = New-Row 'gpu'     'GPU'         $RowColors.gpu     'ShowGpu'
$Rows['gpueng']  = New-Row 'gpueng'  'GPU engines' $RowColors.gpueng  'ShowGpuEngines' $true 1 $false $false $true
$Rows['down']    = New-Row 'down'    'Download'    $RowColors.down    'ShowNet' $false 50KB
$Rows['up']      = New-Row 'up'      'Upload'      $RowColors.up      'ShowNet' $false 50KB
$Rows['adapter'] = New-Row 'adapter' 'Adapter'     $RowColors.adapter 'ShowAdapter'    $true 1 $false $false $true
$DiskPanel = New-Object System.Windows.Controls.StackPanel; $DiskPanel.Orientation = 'Vertical'
$Rows['top']     = New-Row 'top'     'Top process' $RowColors.top     'ShowTop'     $true 1 $true  $false $true
$Rows['uptime']  = New-Row 'uptime'  'Uptime'      $RowColors.uptime  'ShowUptime'  $true 1 $true  $false $true
$Rows['bat']     = New-Row 'bat'     'Battery'     $RowColors.bat     'ShowBattery'

function Get-MetricOrder {
    $known = @($MetricDefs | ForEach-Object { $_.Id })
    $ord = @(@($script:Settings.Order) | Where-Object { $known -contains $_ } | Select-Object -Unique)
    foreach ($id in $known) { if ($ord -notcontains $id) { $ord += $id } }
    $ord
}
function Apply-Order {
    $RowsPanel.Children.Clear()
    foreach ($id in Get-MetricOrder) {
        $def = $MetricDefs | Where-Object { $_.Id -eq $id }
        foreach ($rid in $def.Rows) { $el = if ($rid -eq 'disk') { $DiskPanel } else { $Rows[$rid].Grid }; $RowsPanel.Children.Add($el) | Out-Null }
    }
}
Apply-Order

function Apply-Appearance {
    $alpha = [Math]::Max(0.0, [Math]::Min(1.0, [double]$script:Settings.BgAlpha))
    $BgBrush.Opacity = $alpha; $EdgeBrush.Opacity = $alpha; $LineBrush.Opacity = $alpha
    # Without a surface the text needs its own contrast against the wallpaper.
    $Outer.Effect = if ($alpha -lt 0.35) { $TextShadow } else { $null }
    $Root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform([double]$script:Settings.Scale, [double]$script:Settings.Scale)
    $acc = Brush (Accent-Hex)
    $Mark.Background = $acc
    if ($script:Set) { $script:Set.Resources['Accent'] = $acc }
}

function Apply-Mode {
    $S = $script:Settings; $bar = $S.Mode -eq 'Bar'; $vbar = $bar -and $S.BarOrientation -eq 'Vertical'; $hbar = $bar -and -not $vbar
    $orient = if ($hbar) { 'Horizontal' } else { 'Vertical' }
    $RowsPanel.Orientation = $orient; $DiskPanel.Orientation = $orient
    $RowsPanel.MinWidth = if ($bar) { 0 } else { 232 }
    $edge = Get-BarEdge
    $Root.CornerRadius = if (-not $bar) { New-Object System.Windows.CornerRadius(8) }
                         else { switch ($edge) { 'Top' { New-Object System.Windows.CornerRadius(0, 0, 8, 8) } 'Bottom' { New-Object System.Windows.CornerRadius(8, 8, 0, 0) }
                                                 'Left' { New-Object System.Windows.CornerRadius(0, 8, 8, 0) } 'Right' { New-Object System.Windows.CornerRadius(8, 0, 0, 8) } default { New-Object System.Windows.CornerRadius(8) } } }
    $Root.Padding = if ($hbar) { Thick 12 4 12 5 } elseif ($vbar) { Thick 8 6 10 6 } else { Thick 12 8 12 10 }
    $hv = if (-not $bar -and $S.ShowHeader) { 'Visible' } else { 'Collapsed' }
    $Header.Visibility = $hv; $HeaderLine.Visibility = $hv
    $compact = $bar -and $S.BarCompact
    foreach ($r in $Rows.Values) {
        $r.Text.Orientation = $orient
        $r.Text.Margin = if ($compact) { Thick 2 0 0 0 } elseif ($hbar) { Thick 6 0 0 0 } else { Thick 8 0 10 0 }
        $r.Grid.Margin = if ($compact -and $hbar) { Thick 4 0 6 0 } elseif ($hbar) { Thick 6 0 10 0 } elseif ($vbar) { Thick 0 3 0 3 } else { Thick 0 2 0 2 }
        $r.Label.Margin = if ($hbar) { Thick 0 0 8 0 } else { Thick 0 0 0 0 }
        $r.Label.Visibility = if ($compact) { 'Collapsed' } else { 'Visible' }
        $r.Warn.Margin = if ($hbar) { Thick 6 0 0 0 } else { Thick 0 1 0 0 }
        $r.Label.VerticalAlignment = 'Center'; $r.Value.VerticalAlignment = 'Center'
        $ts = [double]$S.TextScale
        $r.Value.FontSize = $(if ($bar) { 13 } else { 14 }) * $ts
        $r.Label.FontSize = 9 * $ts
        $r.Icon.FontSize = $(if ($bar) { 12 } else { 13 }) * $ts; $r.Icon.Width = 18 * $ts
        $r.Value.Margin = Thick 0 0 0 0
        $r.Spark.Visibility = if (-not $bar -and $S.ShowSparklines -and $r.HasSpark) { 'Visible' } else { 'Collapsed' }
        $r.Track.Visibility = if (-not $bar -and $S.ShowBars -and -not $r.NoTrack) { 'Visible' } else { 'Collapsed' }
        Update-RowVisibility $r
    }
}
function Apply-Visibility { foreach ($r in $Rows.Values) { Update-RowVisibility $r } }

# Bar mode docks to a screen edge; the anchor only makes sense along that edge, so snap mismatched anchors.
function Get-BarAnchor {
    $S = $script:Settings; $a = [string]$S.Anchor
    if ($S.Mode -ne 'Bar' -or $a -eq 'Custom') { return $a }
    if ($S.BarOrientation -eq 'Vertical') { if ($a -like '*Left' -or $a -like '*Right') { $a } else { 'MiddleRight' } }
    else { if ($a -like 'Top*' -or $a -like 'Bottom*') { $a } else { 'TopCenter' } }
}
function Get-BarEdge {
    $S = $script:Settings; if ($S.Mode -ne 'Bar') { return '' }
    $a = Get-BarAnchor
    if ($a -eq 'Custom') { return '' }
    if ($S.BarOrientation -eq 'Vertical') { if ($a -like '*Left') { 'Left' } else { 'Right' } } else { if ($a -like 'Bottom*') { 'Bottom' } else { 'Top' } }
}

function Get-WorkArea {
    $name = [string]$script:Settings.Monitor
    $scr = $null
    if ($name) { $scr = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $name } | Select-Object -First 1 }
    if (-not $scr) { return [System.Windows.SystemParameters]::WorkArea }
    # Screen gives pixels; the window works in DIPs.
    $k = 1.0
    try { $src = [System.Windows.PresentationSource]::FromVisual($win); if ($src) { $k = $src.CompositionTarget.TransformFromDevice.M11 } } catch {}
    $wa = $scr.WorkingArea
    # Explicit doubles: New-Object picks the wrong Rect overload for int*double arguments and tears the process down.
    New-Object System.Windows.Rect(([double]$wa.Left * $k), ([double]$wa.Top * $k), ([double]$wa.Width * $k), ([double]$wa.Height * $k))
}
function Clamp-Position([double]$l, [double]$t, [double]$w, [double]$h) {
    $sp = [System.Windows.SystemParameters]
    $l = [Math]::Max($sp::VirtualScreenLeft, [Math]::Min($l, $sp::VirtualScreenLeft + $sp::VirtualScreenWidth - $w))
    $t = [Math]::Max($sp::VirtualScreenTop,  [Math]::Min($t, $sp::VirtualScreenTop + $sp::VirtualScreenHeight - $h))
    @($l, $t)
}
$script:Positioning = $false
function Apply-Position {
    if (-not $win.IsLoaded -or $script:Positioning) { return }
    $script:Positioning = $true
    try { Apply-PositionCore } finally { $script:Positioning = $false }
}
function Apply-PositionCore {
    $win.UpdateLayout()
    $w = $win.ActualWidth; $h = $win.ActualHeight; $S = $script:Settings
    $bar = $S.Mode -eq 'Bar'; $a = Get-BarAnchor
    $l = $null; $t = $null
    if ($a -eq 'Custom') {
        if ($bar) { $l = $S.BarLeft; $t = $S.BarTop } else { $l = $S.PanelLeft; $t = $S.PanelTop }
        if ($null -eq $l -or $null -eq $t) { $a = if (-not $bar) { 'TopRight' } elseif ($S.BarOrientation -eq 'Vertical') { 'MiddleRight' } else { 'TopCenter' } }
    }
    if ($a -ne 'Custom') {
        $wa = Get-WorkArea
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
$ErrRows = @{ cpu = @('cpu'); cores = @('cores'); ram = @('ram'); gpu = @('gpu'); gpueng = @('gpueng'); net = @('down','up','adapter'); disk = @('disk'); top = @('top') }
function Apply-Errors($s) {
    $failed = @{}
    foreach ($e in $s.Err) { if ($e -match '^(\w+):\s*(.*)$') { $failed[$Matches[1]] = $Matches[2] } }
    foreach ($src in $ErrRows.Keys) {
        $msg = [string]$failed[$src]
        foreach ($rid in $ErrRows[$src]) {
            if ($rid -eq 'disk') { foreach ($r in $Rows.Values) { if ($r.Id -like 'disk_*') { Set-RowError $r $msg } } }
            elseif ($Rows.Contains($rid)) { Set-RowError $Rows[$rid] $msg }
        }
    }
}
function Apply-Sample($s) {
    $script:LastSample = $s
    if ($s.ContainsKey('Cpu')) {
        $t = '{0,3:0} %' -f $s.Cpu
        if ($s.CpuTemp) { $t += '   {0:0}{1}C' -f $s.CpuTemp, $CH.Deg }
        Set-RowValue $Rows['cpu'] $t $s.Cpu
        $lim = Alert-Limit 'cpu'; $tl = Alert-Limit 'cputemp'
        Set-RowAlert $Rows['cpu'] (($lim -gt 0 -and $s.Cpu -ge $lim) -or ($tl -gt 0 -and $s.CpuTemp -and $s.CpuTemp -ge $tl))
    }
    if ($s.Cores) {
        $avg = ($s.Cores | Measure-Object -Average).Average
        Set-RowValue $Rows['cores'] ('{0}  {1,3:0} %' -f (Format-Blocks ([double[]]$s.Cores)), $avg) $null
    }
    if ($s.RamTotal) {
        $pct = $s.RamUsed / $s.RamTotal * 100
        Set-RowValue $Rows['ram'] ('{0:0.0} / {1:0.0} GB' -f ($s.RamUsed / 1GB), ($s.RamTotal / 1GB)) $pct
        $lim = Alert-Limit 'ram'; Set-RowAlert $Rows['ram'] ($lim -gt 0 -and $pct -ge $lim)
    }
    if ($s.ContainsKey('Gpu')) {
        $t = '{0,3:0} %' -f $s.Gpu
        if ($s.VramTotal -gt 0) { $t += '  {0:0.0}/{1:0}G' -f ($s.VramUsed / 1GB), ($s.VramTotal / 1GB) }
        if ($s.GpuTemp) { $t += '  {0:0}{1}' -f $s.GpuTemp, $CH.Deg }
        Set-RowValue $Rows['gpu'] $t $s.Gpu
        $lim = Alert-Limit 'gpu'; $tl = Alert-Limit 'gputemp'
        Set-RowAlert $Rows['gpu'] (($lim -gt 0 -and $s.Gpu -ge $lim) -or ($tl -gt 0 -and $s.GpuTemp -and $s.GpuTemp -ge $tl))
    }
    if ($s.Engines) {
        $short = @{ '3D' = '3D'; 'Copy' = 'Copy'; 'VideoDecode' = 'Dec'; 'VideoEncode' = 'Enc'; 'VideoProcessing' = 'VP'; 'Compute' = 'Comp'; 'Security' = 'Sec' }
        $parts = foreach ($k in ($s.Engines.Keys | Sort-Object)) { $v = [Math]::Min(100.0, [double]$s.Engines[$k]); if ($v -ge 0.5 -or $k -eq '3D') { $n = if ($short.ContainsKey($k)) { $short[$k] } else { $k.Substring(0, [Math]::Min(4, $k.Length)) }; '{0} {1:0}' -f $n, $v } }
        if (-not $parts) { $parts = @('idle') }
        Set-RowValue $Rows['gpueng'] ($parts -join '  ') $null
    }
    if ($s.ContainsKey('Down')) {
        Set-RowValue $Rows['down'] (Format-Rate $s.Down) $s.Down
        Set-RowValue $Rows['up']   (Format-Rate $s.Up)   $s.Up
    }
    if ($s.AdapterName) {
        $t = Truncate-Text $s.AdapterName 18
        if ($s.AdapterWifi -and $s.ContainsKey('WifiSignal')) { $t += '  {0:0} %' -f $s.WifiSignal }
        Set-RowValue $Rows['adapter'] $t $null
    }
    $dlim = Alert-Limit 'disk'
    foreach ($d in $s.Disks) {
        $id = 'disk_' + $d.Name.Substring(0, 1)
        if (-not $Rows.Contains($id)) {
            $r = New-Row $id $d.Name $RowColors.disk 'ShowDisk'
            $r.Label.Text = 'Disk ' + $d.Name
            $Rows[$id] = $r; $DiskPanel.Children.Add($r.Grid) | Out-Null
            Apply-RowColor $r; Apply-Mode
            $script:DisksDirty = $true
        }
        Set-RowValue $Rows[$id] ('R {0,-6} W {1,-6}' -f (Format-Short $d.Read), (Format-Short $d.Write)) $d.Busy
        Set-RowAlert $Rows[$id] ($dlim -gt 0 -and $d.Busy -ge $dlim)
    }
    if ($s.TopName) { Set-RowValue $Rows['top'] ('{0}  {1:0} %' -f (Truncate-Text $s.TopName 14), $s.TopPct) $null }
    if ($s.Uptime) { $u = $s.Uptime; Set-RowValue $Rows['uptime'] ('{0}d {1:00}:{2:00}:{3:00}' -f $u.Days, $u.Hours, $u.Minutes, $u.Seconds) $null }
    if ($s.Battery) {
        $b = $s.Battery; $t = '{0:0} %' -f $b.Pct
        if ($b.Status -in 1, 4, 5) { if ($b.Mins -gt 0 -and $b.Mins -lt 71582788) { $t += '  {0}h{1:00}m' -f [int][Math]::Floor($b.Mins / 60), ($b.Mins % 60) } }
        else { $t += '  ' + $CH.Bolt }
        Set-RowValue $Rows['bat'] $t $b.Pct
        $lim = Alert-Limit 'bat'; Set-RowAlert $Rows['bat'] ($lim -gt 0 -and $b.Pct -le $lim)
    }
    Apply-Errors $s
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

    <Style x:Key="ChipCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="0,3,6,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
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

    <Style x:Key="Swatch" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,2,6,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Width="26" Height="26" Background="Transparent">
              <Ellipse x:Name="Ring" Width="26" Height="26" Stroke="Transparent" StrokeThickness="2"/>
              <Ellipse Width="16" Height="16" Fill="{TemplateBinding Background}"/>
              <TextBlock x:Name="Check" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#0B0D10" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Stroke" Value="{StaticResource Line2}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Ring" Property="Stroke" Value="{StaticResource Text}"/>
                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
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
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{StaticResource Raised}" BorderBrush="{StaticResource Line2}" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
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

function New-SwitchControl([string]$key) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $script:Set.Resources['Switch']; $cb.Tag = $key; $cb.IsChecked = [bool]$script:Settings[$key]
    $h = { param($sender, $e) if ($script:Suppress) { return }; $script:Settings[$sender.Tag] = [bool]$sender.IsChecked; Apply-Setting $sender.Tag }
    $cb.Add_Checked($h); $cb.Add_Unchecked($h)
    [void]$script:Bound.Add(@{ Kind = 'Switch'; Key = $key; Control = $cb })
    $cb
}
function New-Switch([string]$key, [string]$title, [string]$desc) { New-SettingRow $title $desc (New-SwitchControl $key) }
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

function New-DarkTextBox([double]$width) {
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Width = $width; $tb.Height = 26; $tb.Padding = Thick 6 2 6 2; $tb.VerticalContentAlignment = 'Center'; $tb.BorderThickness = Thick 1 1 1 1
    $tb.FontFamily = $MonoFont; $tb.FontSize = 12; $tb.CaretBrush = $Palette.Text
    $tb.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Surface')
    $tb.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Text')
    $tb.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'Line2')
    $tb
}
function New-SwatchPanel([string]$key, [string]$group, $defaultBrush) {
    $wp = New-Object System.Windows.Controls.WrapPanel; $wp.MaxWidth = 520; $wp.HorizontalAlignment = 'Left'
    foreach ($name in $Swatches.Keys) {
        $hex = $Swatches[$name]
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $script:Set.Resources['Swatch']; $rb.GroupName = "grp_${key}_$group"; $rb.ToolTip = $name
        $rb.Background = if ($hex) { Brush $hex } else { $defaultBrush }
        $rb.Tag = @{ Key = $key; Group = $group; Value = $hex }
        $rb.IsChecked = ([string]$script:Settings[$key][$group] -eq $hex)
        $rb.Add_Checked({ param($sender, $e) if ($script:Suppress) { return }
            $t = $sender.Tag
            if ($t.Value) { $script:Settings[$t.Key][$t.Group] = $t.Value } else { $script:Settings[$t.Key].Remove($t.Group) }
            Apply-Setting $t.Key; Refresh-SettingsUI })
        $wp.Children.Add($rb) | Out-Null
        [void]$script:Bound.Add(@{ Kind = 'Swatch'; Key = $key; Control = $rb })
    }
    # Free-form colour: any #RRGGBB, applied as soon as it is valid.
    $hx = New-DarkTextBox 74; $hx.MaxLength = 7; $hx.ToolTip = 'Custom colour, e.g. #3FA9F5'; $hx.Margin = Thick 4 0 0 0; $hx.VerticalAlignment = 'Center'
    $hx.Tag = @{ Key = $key; Group = $group }
    $hx.Add_TextChanged({ param($sender, $e) if ($script:Suppress) { return }
        $t = $sender.Tag; $v = $sender.Text.Trim()
        if ($v -match '^#?([0-9A-Fa-f]{6})$') { $script:Settings[$t.Key][$t.Group] = '#' + $Matches[1].ToUpperInvariant(); Apply-Setting $t.Key; Refresh-SettingsUI }
        elseif ($v -eq '' -and $script:Settings[$t.Key].ContainsKey($t.Group) -and ($Swatches.Values -notcontains $script:Settings[$t.Key][$t.Group])) { $script:Settings[$t.Key].Remove($t.Group); Apply-Setting $t.Key; Refresh-SettingsUI } })
    $wp.Children.Add($hx) | Out-Null
    [void]$script:Bound.Add(@{ Kind = 'HexBox'; Key = $key; Control = $hx })
    $wp
}
function New-SwatchRow([string]$group, [string]$title) { New-SettingRow $title '' (New-SwatchPanel 'Colors' $group $Palette.Text) $true }

function New-IconRow([string]$group, [string]$title) {
    $hp = New-Object System.Windows.Controls.StackPanel; $hp.Orientation = 'Horizontal'
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $script:Set.Resources['Btn']; $btn.Padding = Thick 0 0 0 0; $btn.Width = 34; $btn.Height = 30; $btn.Margin = Thick 0 0 12 0
    $btn.FontFamily = $IconFont; $btn.FontSize = 14; $btn.ToolTip = 'Choose icon'
    $btn.Tag = @{ Group = $group }
    $pop = New-Object System.Windows.Controls.Primitives.Popup
    $pop.PlacementTarget = $btn; $pop.Placement = 'Bottom'; $pop.StaysOpen = $false; $pop.AllowsTransparency = $true; $pop.VerticalOffset = 4
    $frame = New-Object System.Windows.Controls.Border
    $frame.CornerRadius = New-Object System.Windows.CornerRadius(6); $frame.Padding = Thick 6 6 6 6; $frame.BorderThickness = Thick 1 1 1 1; $frame.Width = 318
    $frame.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Raised')
    $frame.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Line2')
    $grid = New-Object System.Windows.Controls.WrapPanel
    foreach ($code in $IconCatalog) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $script:Set.Resources['Chip']; $rb.GroupName = "grp_Icons_$group"; $rb.Width = 32; $rb.Height = 32; $rb.Padding = Thick 0 0 0 0; $rb.Margin = Thick 2 2 2 2
        $rb.FontFamily = $IconFont; $rb.FontSize = 15; $rb.Content = Glyph-Hex $code
        if ($code -eq $RowIcons[$group]) { $rb.ToolTip = 'Default' }
        $rb.Tag = @{ Key = 'Icons'; Group = $group; Value = $code; Popup = $pop }
        $rb.Add_Checked({ param($sender, $e) if ($script:Suppress) { return }
            $t = $sender.Tag
            if ($t.Value -eq $RowIcons[$t.Group]) { $script:Settings.Icons.Remove($t.Group) } else { $script:Settings.Icons[$t.Group] = $t.Value }
            Apply-Setting 'Icons'; Refresh-SettingsUI; $t.Popup.IsOpen = $false })
        $grid.Children.Add($rb) | Out-Null
        [void]$script:Bound.Add(@{ Kind = 'IconPick'; Key = 'Icons'; Control = $rb })
    }
    $frame.Child = $grid; $pop.Child = $frame
    $btn.Add_Click({ param($sender, $e) $sender.Tag.Popup.IsOpen = $true })
    $btn.Tag.Popup = $pop
    [void]$script:Bound.Add(@{ Kind = 'IconBtn'; Key = 'Icons'; Control = $btn })
    $hp.Children.Add($btn) | Out-Null; $hp.Children.Add($pop) | Out-Null
    $hp.Children.Add((New-SwatchPanel 'IconColors' $group (Brush $RowColors[$group]))) | Out-Null
    $hp.HorizontalAlignment = 'Left'
    New-SettingRow $title '' $hp $true
}
function Get-IconCode([string]$group) { $c = [string]$script:Settings.Icons[$group]; if ($c) { $c } else { $RowIcons[$group] } }

function New-MapSliderRow([string]$map, [string]$group, [string]$title, [string]$desc, [double]$min, [double]$max, [double]$step, [string]$unit) {
    $wrap = New-Object System.Windows.Controls.Grid; $wrap.Width = 260
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(64)
    $wrap.ColumnDefinitions.Add($c1); $wrap.ColumnDefinitions.Add($c2)
    $sl = New-Object System.Windows.Controls.Slider
    $sl.Style = $script:Set.Resources['DarkSlider']; $sl.Minimum = $min; $sl.Maximum = $max; $sl.TickFrequency = $step; $sl.IsSnapToTickEnabled = $true
    $sl.Value = Alert-Limit $group
    $fmt = { param($v) if ($v -le 0) { 'Off' } else { '{0:0} {1}' -f $v, $unit } }
    $lbl = New-Text (& $fmt $sl.Value) 12.5 $Palette.Text; $lbl.FontFamily = $MonoFont; $lbl.HorizontalAlignment = 'Right'; $lbl.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($lbl, 1)
    $sl.Tag = @{ Map = $map; Group = $group; Label = $lbl; Fmt = $fmt }
    $sl.Add_ValueChanged({ param($sender, $e)
        $t = $sender.Tag; $t.Label.Text = (& $t.Fmt $sender.Value)
        if ($script:Suppress) { return }
        if ($sender.Value -le 0) { $script:Settings[$t.Map].Remove($t.Group) } else { $script:Settings[$t.Map][$t.Group] = [double]$sender.Value }
        Apply-Setting $t.Map })
    $wrap.Children.Add($sl) | Out-Null; $wrap.Children.Add($lbl) | Out-Null
    [void]$script:Bound.Add(@{ Kind = 'MapSlider'; Key = $map; Control = $sl })
    New-SettingRow $title $desc $wrap
}

$ModKeys = 'LeftCtrl','RightCtrl','LeftShift','RightShift','LeftAlt','RightAlt','LWin','RWin','System'
function Format-Hotkey([string]$hk) { if (-not $hk) { 'None' } elseif ($script:HotkeyOk) { $hk } else { "$hk  (in use by another app)" } }
function New-HotkeyRow {
    $hp = New-Object System.Windows.Controls.StackPanel; $hp.Orientation = 'Horizontal'
    $tb = New-DarkTextBox 190; $tb.IsReadOnly = $true; $tb.Cursor = 'Hand'; $tb.Text = Format-Hotkey $script:Settings.Hotkey
    $tb.ToolTip = 'Click, then press the key combination (e.g. Ctrl+Shift+G). Esc clears.'
    $tb.Add_GotKeyboardFocus({ param($sender, $e) $sender.Text = 'Press keys...' })
    $tb.Add_LostKeyboardFocus({ param($sender, $e) $sender.Text = Format-Hotkey $script:Settings.Hotkey })
    $tb.Add_PreviewKeyDown({ param($sender, $e)
        $e.Handled = $true
        $key = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
        if ([string]$key -in $ModKeys) { return }
        if ($key -in 'Escape','Back','Delete') { $script:Settings.Hotkey = ''; Apply-Setting 'Hotkey'; $sender.Text = Format-Hotkey ''; [System.Windows.Input.Keyboard]::ClearFocus(); return }
        $m = [System.Windows.Input.Keyboard]::Modifiers; $parts = @()
        if ($m -band [System.Windows.Input.ModifierKeys]::Control) { $parts += 'Ctrl' }
        if ($m -band [System.Windows.Input.ModifierKeys]::Alt)     { $parts += 'Alt' }
        if ($m -band [System.Windows.Input.ModifierKeys]::Shift)   { $parts += 'Shift' }
        if ($m -band [System.Windows.Input.ModifierKeys]::Windows) { $parts += 'Win' }
        # Bare letters/digits would hijack typing everywhere; function keys are fine on their own.
        if ($parts.Count -eq 0 -and [string]$key -notmatch '^F\d+$') { return }
        $script:Settings.Hotkey = ($parts + [string]$key) -join '+'
        Apply-Setting 'Hotkey'; $sender.Text = Format-Hotkey $script:Settings.Hotkey; [System.Windows.Input.Keyboard]::ClearFocus() })
    $clr = New-Object System.Windows.Controls.Button; $clr.Content = 'Clear'; $clr.Style = $script:Set.Resources['Btn']; $clr.Margin = Thick 8 0 0 0; $clr.Padding = Thick 10 3 10 3
    $clr.Add_Click({ $script:Settings.Hotkey = ''; Apply-Setting 'Hotkey'; Refresh-SettingsUI })
    $hp.Children.Add($tb) | Out-Null; $hp.Children.Add($clr) | Out-Null
    [void]$script:Bound.Add(@{ Kind = 'Hotkey'; Key = 'Hotkey'; Control = $tb })
    New-SettingRow 'Show / hide hotkey' 'Global shortcut that toggles the overlay, handy with click-through on. Function keys may be used alone; other keys need a modifier.' $hp
}

function Build-MetricList {
    if (-not $script:MetricHost) { return }
    $keys = @($MetricDefs | ForEach-Object { $_.Key })
    $script:Bound = [System.Collections.ArrayList]@($script:Bound | Where-Object { -not ($_.Kind -eq 'Switch' -and $keys -contains $_.Key) })
    $sp = New-Object System.Windows.Controls.StackPanel
    $ord = Get-MetricOrder
    $move = { param($sender, $e)
        $t = $sender.Tag; $list = [System.Collections.ArrayList]@(Get-MetricOrder); $i = $list.IndexOf($t.Id); $j = $i + $t.Dir
        if ($i -lt 0 -or $j -lt 0 -or $j -ge $list.Count) { return }
        $list.RemoveAt($i); $list.Insert($j, $t.Id)
        $script:Settings.Order = @($list); Apply-Setting 'Order'; Build-MetricList }
    for ($i = 0; $i -lt $ord.Count; $i++) {
        $def = $MetricDefs | Where-Object { $_.Id -eq $ord[$i] }
        $ctl = New-Object System.Windows.Controls.StackPanel; $ctl.Orientation = 'Horizontal'
        foreach ($dir in @(-1, 1)) {
            $b = New-Object System.Windows.Controls.Button
            $b.Style = $script:Set.Resources['Btn']; $b.Padding = Thick 0 0 0 0; $b.Width = 26; $b.Height = 24; $b.Margin = Thick 0 0 4 0
            $b.FontFamily = $IconFont; $b.FontSize = 10; $b.Content = Glyph $(if ($dir -lt 0) { 0xE70E } else { 0xE70D })
            $b.ToolTip = if ($dir -lt 0) { 'Move up' } else { 'Move down' }
            $b.IsEnabled = -not (($dir -lt 0 -and $i -eq 0) -or ($dir -gt 0 -and $i -eq $ord.Count - 1))
            $b.Opacity = if ($b.IsEnabled) { 1 } else { 0.35 }
            $b.Tag = @{ Id = $def.Id; Dir = $dir }; $b.Add_Click($move)
            $ctl.Children.Add($b) | Out-Null
        }
        $sw = New-SwitchControl $def.Key; $sw.Margin = Thick 10 0 0 0; $sw.VerticalAlignment = 'Center'
        $ctl.Children.Add($sw) | Out-Null
        $sp.Children.Add((New-SettingRow $def.Label $def.Desc $ctl)) | Out-Null
    }
    $script:MetricHost.Child = $sp
}

function Build-MonitorChips {
    if (-not $script:MonitorHost) { return }
    $script:Bound = [System.Collections.ArrayList]@($script:Bound | Where-Object { $_.Key -ne 'Monitor' })
    $opts = @((Opt 'Primary' ''))
    $i = 1
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $tag = if ($scr.Primary) { ' (primary)' } else { '' }
        $opts += Opt ('Display {0}  {1}x{2}{3}' -f $i, $scr.Bounds.Width, $scr.Bounds.Height, $tag) $scr.DeviceName; $i++
    }
    $script:MonitorHost.Child = New-ChipGroup 'Monitor' $opts
}

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
                'Swatch'   { $t = $b.Control.Tag; $b.Control.IsChecked = ([string]$script:Settings[$t.Key][$t.Group] -eq [string]$t.Value) }
                'HexBox'   { $t = $b.Control.Tag; $cur = [string]$script:Settings[$t.Key][$t.Group]
                             $custom = $cur -and ($Swatches.Values -notcontains $cur)
                             if ($b.Control.Text -ne $(if ($custom) { $cur } else { '' })) { $b.Control.Text = if ($custom) { $cur } else { '' } }
                             $b.Control.BorderBrush = if ($custom) { Brush $cur } else { $script:Set.Resources['Line2'] } }
                'MapSlider' { $t = $b.Control.Tag; $b.Control.Value = Alert-Limit $t.Group }
                'Hotkey'   { if (-not $b.Control.IsKeyboardFocused) { $b.Control.Text = Format-Hotkey $script:Settings.Hotkey } }
                'IconPick' { $t = $b.Control.Tag; $b.Control.IsChecked = ((Get-IconCode $t.Group) -eq $t.Value) }
                'IconBtn'  { $b.Control.Content = Glyph-Hex (Get-IconCode $b.Control.Tag.Group) }
                'Disk'   { $d = [string]$b.Control.Tag; $b.Control.IsChecked = if ($d) { @($script:Settings.Disks) -contains $d } else { @($script:Settings.Disks).Count -eq 0 } }
            }
        }
        if ($script:StartupSwitch) { $script:StartupSwitch.IsChecked = Test-Path (Get-StartupLink) }
    } finally { $script:Suppress = $false }
}

function Apply-Setting([string]$key) {
    if ($key -in 'Mode','BarOrientation') { $script:Settings.Anchor = Get-BarAnchor; Refresh-SettingsUI }
    switch -Regex ($key) {
        '^(BgAlpha|Scale|Accent)$'                 { Apply-Appearance; if ($key -eq 'Scale') { Apply-Position } }
        '^(Mode|Anchor|BarOrientation|BarCompact|ShowSparklines|ShowBars|ShowHeader|TextScale)$' { Apply-Mode; Apply-Position }
        '^(ShowCores|ShowGpuEngines|ShowAdapter)$' { $sync.WantCores = [bool]$script:Settings.ShowCores; $sync.WantEngines = [bool]$script:Settings.ShowGpuEngines; $sync.WantAdapter = [bool]$script:Settings.ShowAdapter; Apply-Visibility; Apply-Position }
        '^(Show|Disks$)'                           { Apply-Visibility; Apply-Position }
        '^Order$'                                  { Apply-Order; Apply-Position }
        '^Monitor$'                                { Apply-Position }
        '^(Colors|Icons|IconColors|Alerts|AlertColor)$' { Apply-Colors }
        '^ClickThrough$'                           { Apply-ExStyle }
        '^Hotkey$'                                 { Apply-Hotkey }
        '^HideFullscreen$'                         { if (-not $script:Settings.HideFullscreen -and $script:AutoHidden) { $script:AutoHidden = $false; $win.Show(); Assert-Topmost } }
        '^Interval$'                               { $sync.Interval = [double]$script:Settings.Interval }
        '^Adapter$'                                { $sync.Adapter = [string]$script:Settings.Adapter }
    }
    Request-Save
}
function Reset-AllSettings {
    $script:Settings = New-DefaultSettings; Refresh-SettingsUI
    Apply-Appearance; Apply-Mode; Apply-Order; Apply-Visibility; Apply-Colors; Apply-ExStyle; Apply-Hotkey; Apply-Position
    $sync.Interval = [double]$script:Settings.Interval; $sync.Adapter = ''; $sync.WantCores = $false; $sync.WantEngines = $false; $sync.WantAdapter = $false
    if ($script:Set) { Build-MetricList; Build-DiskChips; Build-AdapterChips; Build-MonitorChips }
    Save-Settings
}

# ---------------------------------------------------------------- hotkey + fullscreen auto-hide
$script:HotKeyWin = $null; $script:HotkeyOk = $true
function Apply-Hotkey {
    if (-not $script:HotKeyWin) { $script:HotKeyWin = New-Object Glance.HotKeyWindow; $script:HotKeyWin.Add_Pressed({ Toggle-Visible }) }
    $script:HotKeyWin.Unregister(); $script:HotkeyOk = $true
    $hk = [string]$script:Settings.Hotkey
    if (-not $hk) { return }
    try {
        $parts = $hk -split '\+'; $mods = [uint32]0
        foreach ($p in $parts[0..($parts.Count - 2)]) { switch ($p) { 'Alt' { $mods = $mods -bor 1 } 'Ctrl' { $mods = $mods -bor 2 } 'Shift' { $mods = $mods -bor 4 } 'Win' { $mods = $mods -bor 8 } } }
        $key = [System.Windows.Input.Key]$parts[-1]
        $vk = [uint32][System.Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
        $script:HotkeyOk = $script:HotKeyWin.Register($mods, $vk)
        if (-not $script:HotkeyOk) { Write-ErrorLog "hotkey '$hk' is already taken by another app" -Once }
    } catch { $script:HotkeyOk = $false; Write-ErrorLog "hotkey '$hk': $_" -Once }
}
$script:AutoHidden = $false
function Get-OverlayScreen {
    # The overlay may be hidden (auto-hide), so locate it by its last position rather than its handle.
    $k = 1.0; try { $src = [System.Windows.PresentationSource]::FromVisual($win); if ($src) { $k = $src.CompositionTarget.TransformToDevice.M11 } } catch {}
    $cx = [int](($win.Left + $win.ActualWidth / 2) * $k); $cy = [int](($win.Top + $win.ActualHeight / 2) * $k)
    [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($cx, $cy)))
}
function Test-Fullscreen([IntPtr]$h = [IntPtr]::Zero) {
    if ($h -eq [IntPtr]::Zero) { $h = [Glance.Native]::GetForegroundWindow() }
    if ($h -eq [IntPtr]::Zero) { return $false }
    [uint32]$owner = 0; [void][Glance.Native]::GetWindowThreadProcessId($h, [ref]$owner)
    if ($owner -eq $PID) { return $false }
    if ([Glance.Native]::ClassOf($h) -in 'Progman','WorkerW','Shell_TrayWnd','Shell_SecondaryTrayWnd','Windows.UI.Core.CoreWindow') { return $false }
    $r = New-Object Glance.Native+RECT; if (-not [Glance.Native]::GetWindowRect($h, [ref]$r)) { return $false }
    # A maximized window with an auto-hidden taskbar also covers the whole monitor; real full-screen windows drop their caption.
    if (([Glance.Native]::GetStyle($h) -band 0x00C00000) -eq 0x00C00000) { return $false }
    $scr = [System.Windows.Forms.Screen]::FromHandle($h); $b = $scr.Bounds
    $covers = ($r.Left -le $b.Left) -and ($r.Top -le $b.Top) -and ($r.Right -ge $b.Right) -and ($r.Bottom -ge $b.Bottom)
    # A game on the other monitor should not hide an overlay that lives on this one.
    $covers -and ($scr.DeviceName -eq (Get-OverlayScreen).DeviceName)
}
function Update-FullscreenHide {
    if (-not $script:Settings.HideFullscreen) { return }
    $fs = Test-Fullscreen
    if ($fs -and $win.IsVisible) { $win.Hide(); $script:AutoHidden = $true }
    elseif (-not $fs -and $script:AutoHidden) { $script:AutoHidden = $false; $win.Show(); Assert-Topmost }
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

function Build-DiskChips {
    if (-not $script:DiskHost) { return }
    $script:DisksDirty = $false
    $script:Bound = [System.Collections.ArrayList]@($script:Bound | Where-Object { $_.Kind -ne 'Disk' })
    $live = @($Rows.Values | Where-Object { $_.Id -like 'disk_*' } | ForEach-Object { $_.LabelText })
    $names = @($live)
    foreach ($d in @($script:Settings.Disks)) { if ($names -notcontains $d) { $names += $d } }
    $wp = New-Object System.Windows.Controls.WrapPanel
    $toggle = { param($sender, $e) if ($script:Suppress) { return }
        $d = [string]$sender.Tag; $sel = [System.Collections.ArrayList]@($script:Settings.Disks)
        if (-not $d) { $sel.Clear() }
        elseif ($sender.IsChecked) { if ($sel -notcontains $d) { [void]$sel.Add($d) } }
        else { $sel.Remove($d) }
        $script:Settings.Disks = @($sel | Sort-Object)
        Apply-Setting 'Disks'; Refresh-SettingsUI }
    foreach ($d in @('') + @($names | Sort-Object)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $script:Set.Resources['ChipCheck']; $cb.Tag = $d
        $cb.Content = if (-not $d) { 'All drives' } elseif ($live -contains $d) { $d } else { "$d (offline)" }
        $cb.Add_Checked($toggle); $cb.Add_Unchecked($toggle)
        $wp.Children.Add($cb) | Out-Null
        [void]$script:Bound.Add(@{ Kind = 'Disk'; Key = 'Disks'; Control = $cb })
    }
    $script:DiskHost.Child = $wp
    Refresh-SettingsUI
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
    $sec.Children.Add((New-ChoiceRow 'Mode' 'Layout' 'Panel floats anywhere; Bar docks flush to a screen edge as a thin strip.' @((Opt 'Panel' 'Panel'), (Opt 'Bar' 'Bar')))) | Out-Null
    $sec.Children.Add((New-ChoiceRow 'BarOrientation' 'Bar orientation' 'Horizontal runs along the top or bottom edge; Vertical runs along the left or right edge.' @((Opt 'Horizontal' 'Horizontal'), (Opt 'Vertical' 'Vertical')))) | Out-Null
    $sec.Children.Add((New-Switch 'BarCompact' 'Compact bar' 'Bar layout shows only icon and value, no labels - roughly 40 % narrower.')) | Out-Null
    $sec.Children.Add((New-Switch 'ClickThrough' 'Click-through' 'Mouse clicks pass through the overlay to whatever is underneath. Use the tray icon to get back here.')) | Out-Null
    $sec.Children.Add((New-Switch 'ShowHeader' 'Show header' 'Title strip with the settings and hide buttons (panel layout only).')) | Out-Null
    $sec.Children.Add((New-SettingRow 'Position' 'Panel: pick a corner or edge, or drag it (Free). Bar: picks the edge it docks to and where it sits along that edge - top/bottom for a horizontal bar, left/right for a vertical one.' (New-AnchorPicker) $true)) | Out-Null
    $script:MonitorHost = New-Object System.Windows.Controls.Border
    $sec.Children.Add((New-SettingRow 'Monitor' 'Which display the preset positions refer to.' $script:MonitorHost $true)) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Behaviour'
    $sec.Children.Add((New-Switch 'HideFullscreen' 'Hide over full-screen apps' 'Hides the overlay while a game or video fills the monitor it sits on, and brings it back afterwards. Full-screen apps on other monitors are ignored.')) | Out-Null
    $sec.Children.Add((New-HotkeyRow)) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Sampling'
    $sec.Children.Add((New-SliderRow 'Interval' 'Refresh interval' 'How often metrics are sampled. Lower is smoother but uses a little more CPU.' 500 3000 250 { param($v) '{0:0.00} s' -f ($v / 1000) })) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $pages['General'] = @{ Icon = (Glyph 0xE713); Sub = 'Startup, layout, behaviour and sampling.'; Panel = $p }

    # Appearance
    $p = New-Object System.Windows.Controls.StackPanel
    $sec = New-Section 'Surface'
    $sec.Children.Add((New-SliderRow 'BgAlpha' 'Background opacity' 'Transparency of the overlay surface. Set to 0 % for no background; text stays fully opaque.' 0.0 1.0 0.04 { param($v) '{0:0} %' -f ($v * 100) })) | Out-Null
    $sec.Children.Add((New-SliderRow 'Scale' 'Size' 'Scales the whole overlay. Useful on high-DPI or TV displays.' 0.8 1.5 0.05 { param($v) '{0:0} %' -f ($v * 100) })) | Out-Null
    $sec.Children.Add((New-SliderRow 'TextScale' 'Text size' 'Scales only the metric text; sparklines and tracks keep their size.' 0.8 1.6 0.05 { param($v) '{0:0} %' -f ($v * 100) })) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Style'
    $accOpts = @(); foreach ($k in $Accents.Keys) { $accOpts += Opt $k $k }
    $sec.Children.Add((New-ChoiceRow 'Accent' 'Accent colour' 'Used for the brand mark and controls.' $accOpts)) | Out-Null
    $sec.Children.Add((New-Switch 'ShowSparklines' 'Sparklines' '60-second history graph next to each metric.')) | Out-Null
    $sec.Children.Add((New-Switch 'ShowBars' 'Usage tracks' 'Thin bar under each metric showing current load.')) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Metric text colours'
    $sec.Children.Add((New-Text 'Colour of the value text for each readout. First swatch = default (white); the box takes any #RRGGBB.' 11.5 $Palette.Dim)) | Out-Null
    foreach ($g in $ColorGroups.Keys) { $sec.Children.Add((New-SwatchRow $g $ColorGroups[$g])) | Out-Null }
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Metric icons'
    $sec.Children.Add((New-Text 'Click the icon to pick a different glyph; the swatches set its colour (first swatch = that metric''s default).' 11.5 $Palette.Dim)) | Out-Null
    foreach ($g in $IconGroups.Keys) { $sec.Children.Add((New-IconRow $g $IconGroups[$g])) | Out-Null }
    $p.Children.Add($sec) | Out-Null
    $pages['Appearance'] = @{ Icon = (Glyph 0xE790); Sub = 'Opacity, size, accent and colours.'; Panel = $p }

    # Metrics
    $p = New-Object System.Windows.Controls.StackPanel
    $sec = New-Section 'Shown on the overlay'
    $sec.Children.Add((New-Text 'Toggle each readout and use the arrows to change the order they appear in.' 11.5 $Palette.Dim)) | Out-Null
    $script:MetricHost = New-Object System.Windows.Controls.Border
    $sec.Children.Add($script:MetricHost) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Disks'
    $script:DiskHost = New-Object System.Windows.Controls.Border
    $sec.Children.Add((New-SettingRow 'Which drives' 'Pick the drive letters to show. Drives appear here once they have been measured.' $script:DiskHost $true)) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Alerts'
    $sec.Children.Add((New-Text 'When a reading crosses its limit the value and icon switch to the alert colour. Off = no alert.' 11.5 $Palette.Dim)) | Out-Null
    $alertOpts = @(); foreach ($k in $AlertColors.Keys) { $alertOpts += Opt $k $AlertColors[$k] }
    $sec.Children.Add((New-ChoiceRow 'AlertColor' 'Alert colour' '' $alertOpts)) | Out-Null
    foreach ($a in @(
        @('cpu','CPU load above','',0,100,5,'%'),
        @('cputemp','CPU temperature above','Only when the firmware exposes a CPU temperature.',0,100,5,([string][char]0xB0 + 'C')),
        @('ram','Memory use above','',0,100,5,'%'),
        @('gpu','GPU load above','',0,100,5,'%'),
        @('gputemp','GPU temperature above','',0,100,5,([string][char]0xB0 + 'C')),
        @('disk','Disk busy above','Applies to every shown drive.',0,100,5,'%'),
        @('bat','Battery below','',0,100,5,'%'))) {
        $sec.Children.Add((New-MapSliderRow 'Alerts' $a[0] $a[1] $a[2] $a[3] $a[4] $a[5] $a[6])) | Out-Null
    }
    $p.Children.Add($sec) | Out-Null
    $pages['Metrics'] = @{ Icon = (Glyph 0xE9D9); Sub = 'Choose which readouts appear, their order, and alert limits.'; Panel = $p }

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
    if ($Portable) { $pt = New-Text 'Portable mode: settings live in the data folder next to the executable.' 12 $Palette.Dim; $pt.Margin = Thick 0 6 0 0; $about.Children.Add($pt) | Out-Null }
    $sec.Children.Add($about) | Out-Null
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Files'
    $sec.Children.Add((New-ButtonRow 'Settings folder' $DataDir 'Open' { Start-Process explorer.exe -ArgumentList "`"$DataDir`"" })) | Out-Null
    $sec.Children.Add((New-ButtonRow $(if ($AppExe) { 'Install location' } else { 'Script location' }) $AppDir 'Open' { Start-Process explorer.exe -ArgumentList "`"$AppDir`"" })) | Out-Null
    $unins = Join-Path $AppDir 'Uninstall.cmd'
    if (Test-Path $unins) { $sec.Children.Add((New-ButtonRow 'Uninstall' 'Removes the app, shortcuts and the Apps & Features entry.' 'Uninstall...' { Start-Process cmd.exe -ArgumentList "/c `"`"$unins`"`"" } 'DangerBtn')) | Out-Null }
    $p.Children.Add($sec) | Out-Null
    $sec = New-Section 'Reset'
    $sec.Children.Add((New-ButtonRow 'Restore defaults' 'Resets every option and the overlay position. Start-with-Windows is left as is.' 'Reset all settings' { Reset-AllSettings } 'DangerBtn')) | Out-Null
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
    if ($name -eq 'Metrics') { Build-DiskChips; Build-MetricList }
    if ($name -eq 'General') { Build-MonitorChips }
}
function Show-Settings {
    if (-not $script:Set) { New-SettingsWindow | Out-Null }
    Refresh-SettingsUI; Build-AdapterChips; Build-DiskChips; Build-MetricList; Build-MonitorChips
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
$miBar      = New-MenuItem 'Horizontal bar'  { $script:Settings.Mode = 'Bar'; $script:Settings.BarOrientation = 'Horizontal'; Apply-Setting 'Mode'; Refresh-SettingsUI }
$miVBar     = New-MenuItem 'Vertical bar'    { $script:Settings.Mode = 'Bar'; $script:Settings.BarOrientation = 'Vertical';   Apply-Setting 'Mode'; Refresh-SettingsUI }
$miClick    = New-MenuItem 'Click-through'   { $script:Settings.ClickThrough = -not $script:Settings.ClickThrough; Apply-Setting 'ClickThrough'; Refresh-SettingsUI }
$miPos      = New-Object System.Windows.Forms.ToolStripMenuItem('Position')
foreach ($k in $AnchorNames.Keys) {
    if ($k -eq 'Custom') { continue }
    $mi = New-MenuItem $AnchorNames[$k] { param($sender, $e) Set-Anchor ([string]$sender.Tag) }
    $mi.Tag = $k; [void]$miPos.DropDownItems.Add($mi)
}
$miExit     = New-MenuItem 'Exit'            { Stop-App }
$miSettings.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
foreach ($item in @($miShow, $miSettings, '-', $miPanel, $miBar, $miVBar, $miPos, $miClick, '-', $miExit)) {
    if ($item -eq '-') { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) } else { [void]$menu.Items.Add($item) }
}
$menu.Add_Opening({
    $miShow.Text     = if ($win.IsVisible) { 'Hide overlay' } else { 'Show overlay' }
    $miPanel.Checked = $script:Settings.Mode -eq 'Panel'
    $miBar.Checked   = $script:Settings.Mode -eq 'Bar' -and $script:Settings.BarOrientation -ne 'Vertical'
    $miVBar.Checked  = $script:Settings.Mode -eq 'Bar' -and $script:Settings.BarOrientation -eq 'Vertical'
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
# An error inside a WPF event handler would otherwise end the process silently.
$app.Add_DispatcherUnhandledException({ param($sender, $e) Write-ErrorLog "ui: $($e.Exception.Message)" -Once; $e.Handled = $true })
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:TickN = 0; $script:Quitting = $false

function Stop-App {
    $script:Quitting = $true; $sync.Run = $false
    try { $timer.Stop(); $saveTimer.Stop() } catch {}
    try { if ($script:HotKeyWin) { $script:HotKeyWin.Dispose() } } catch {}
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
        if ($script:DisksDirty -and $script:Set -and $script:Set.IsVisible) { Build-DiskChips }
        if ($script:TickN % 4 -eq 0) { Update-FullscreenHide }
        if ($script:TickN % 12 -eq 0 -and $win.IsVisible) { Assert-Topmost }
    } catch { Write-ErrorLog "tick: $_" }
})

$win.Add_SourceInitialized({ $script:Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle; Apply-ExStyle })
$win.Add_Loaded({ try { Apply-Position } catch { Write-ErrorLog "position: $_" }; $timer.Start() })
# Rows appear as data arrives, so SizeToContent grows the window after Loaded; keep it anchored on screen.
$win.Add_SizeChanged({ try { Apply-Position } catch {} })
# Moving between monitors with different scaling changes the DIP geometry of the work area.
try { $win.Add_DpiChanged({ try { Apply-Mode; Apply-Position } catch {} }) } catch {}
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
Apply-Colors
if (-not $Headless) { Apply-Hotkey }

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
        $S0 = $script:Settings
        Write-Output ('settings : schema={0} mode={1}/{2} anchor={3} monitor="{4}" hotkey="{5}" order={6} alerts={7} portable={8}' -f $S0.SchemaVersion, $S0.Mode, $S0.BarOrientation, $S0.Anchor, $S0.Monitor, $S0.Hotkey, ((Get-MetricOrder) -join ','), (@($S0.Alerts.Keys) -join ','), $Portable)
        if ($S0.Hotkey) { Apply-Hotkey; Write-Output "hotkey   : registered=$($script:HotkeyOk)"; $script:HotKeyWin.Unregister() }
        New-SettingsWindow | Out-Null
        foreach ($name in $script:SetPages.Keys) { Show-SettingsPage $name; Write-Output ('page {0,-10} sections={1}' -f $name, $script:SetPages[$name].Panel.Children.Count) }
        Build-AdapterChips; Build-DiskChips; Build-MetricList; Build-MonitorChips; Refresh-SettingsUI
        Write-Output "bound    : $($script:Bound.Count) controls"
        # Round-trip: every default must survive JSON and the reset path must leave the UI consistent.
        $saved = $script:Settings
        $json = New-DefaultSettings | ConvertTo-Json; $back = $json | ConvertFrom-Json
        $missing = @($Defaults.Keys | Where-Object { -not $back.PSObject.Properties[$_] })
        if ($missing.Count) { throw "defaults did not round-trip: $($missing -join ', ')" }
        Reset-AllSettings
        if ((Get-MetricOrder).Count -ne $MetricDefs.Count) { throw 'reset left a bad metric order' }
        $script:Settings = $saved; Refresh-SettingsUI; Apply-Appearance; Apply-Mode; Apply-Order; Apply-Visibility; Apply-Colors
        $sync.WantCores = [bool]$saved.ShowCores; $sync.WantEngines = [bool]$saved.ShowGpuEngines; $sync.WantAdapter = [bool]$saved.ShowAdapter
        Write-Output ('reset    : ok ({0} keys, {1} metrics)' -f $Defaults.Count, $MetricDefs.Count)
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
                    $script:Settings.BarOrientation = 'Vertical'; $script:Settings.Anchor = 'MiddleRight'; Apply-Mode; Apply-Position
                    Save-WindowShot $win (Join-Path $ShotDir 'overlay-vbar.png')
                    $script:Settings.BarOrientation = 'Horizontal'; $script:Settings.Anchor = 'TopRight'
                    $script:Settings.Mode = 'Panel'; Apply-Mode; Apply-Position
                    Show-SettingsPage 'General'
                    Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-general.png')
                    $sv = [System.Windows.Media.VisualTreeHelper]::GetParent($script:S_PageHost); while ($sv -and $sv -isnot [System.Windows.Controls.ScrollViewer]) { $sv = [System.Windows.Media.VisualTreeHelper]::GetParent($sv) }
                    if ($sv) { $sv.ScrollToEnd(); Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-general-2.png'); $sv.ScrollToTop() }
                    Show-SettingsPage 'Appearance'
                    Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-appearance.png')
                    if ($sv) { $sv.ScrollToEnd(); Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-appearance-2.png'); $sv.ScrollToTop() }
                    Show-SettingsPage 'Metrics'
                    Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-metrics.png')
                    if ($sv) { $sv.ScrollToEnd(); Save-WindowShot $script:Set (Join-Path $ShotDir 'settings-metrics-2.png'); $sv.ScrollToTop() }
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
