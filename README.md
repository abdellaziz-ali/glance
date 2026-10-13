<p align="center">
  <img src="docs/screenshots/overlay-panel.png" alt="Glance overlay" width="340">
</p>

<h1 align="center">Glance</h1>

<p align="center">
  An always-on-top system monitor for Windows — CPU, memory, GPU, disk and network at a glance.<br>
  One small <code>.exe</code>. No runtime to download, no dependencies, no admin rights.
</p>

<p align="center">
  <a href="../../releases/latest"><img alt="Download" src="https://img.shields.io/badge/download-Glance--Setup.exe-F5A524?style=flat-square"></a>
  <img alt="Windows 10/11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-5DB7F0?style=flat-square">
  <img alt="Size" src="https://img.shields.io/badge/size-~100%20KB-4FD1A5?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-8A94A0?style=flat-square">
</p>

---

## Features

| | |
|---|---|
| **Live metrics, 1 s refresh** | CPU %, per-core graph, RAM used / total, GPU % + VRAM + temperature, GPU engines, download / upload speed, adapter + Wi-Fi signal, read / write per drive, top process, uptime, battery |
| **Always on top, never in the way** | Borderless, semi-transparent (down to fully transparent), never steals focus. Optional **click-through** so the mouse goes straight to whatever is underneath, **auto-hide over full-screen apps** (per monitor), and a global **show/hide hotkey** |
| **Two layouts** | Floating **panel** with 60-second sparklines and usage tracks, or a slim **bar** - horizontal along the top/bottom edge or vertical along the left/right edge, optionally compact (icons + values only) |
| **Preset positions** | Snap to any corner or edge of any monitor from a 3×3 picker, or drag it anywhere |
| **Make it yours** | Reorder metrics, pick which drives to show, per-metric icon (55 glyphs) and colours for icon and text - swatches or any hex, text size, accent colour |
| **Alerts** | Per-metric limits (CPU/GPU load and temperature, memory, disk busy, battery) turn the reading into the alert colour |
| **Proper settings window** | Everything above plus startup, refresh interval, which network adapter to measure, bytes or bits. Changes apply instantly |
| **Tray icon** | Left-click to show/hide, double-click for settings, right-click for the menu; tooltip shows current speeds |
| **Zero footprint** | Per-user install in `%LocalAppData%`, listed in *Apps & Features*, clean uninstall. Nothing else is installed. Drop a file named `portable` next to the exe to keep settings beside it |

## Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/overlay-panel.png" width="300"><br><sub>Panel layout</sub></td>
    <td align="center"><img src="docs/screenshots/settings-general.png" width="520"><br><sub>Settings — General</sub></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="docs/screenshots/overlay-bar.png" width="820"><br><sub>Bar layout, docked to the top edge</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/overlay-vbar.png" width="180"><br><sub>Vertical bar, docked to the right edge</sub></td>
    <td align="center"><img src="docs/screenshots/settings-metrics.png" width="520"><br><sub>Settings — Metrics (toggle and reorder)</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/settings-general-2.png" width="420"><br><sub>Monitor, full-screen auto-hide, hotkey</sub></td>
    <td align="center"><img src="docs/screenshots/settings-metrics-2.png" width="420"><br><sub>Alert limits</sub></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="docs/screenshots/settings-appearance-2.png" width="520"><br><sub>Icons and colours per metric</sub></td>
  </tr>
</table>

## Install

1. Download **[Glance-Setup.exe](../../releases/latest)** (or the equivalent `Glance-Setup.cmd` if you prefer a plain script).
2. Run it. It asks whether to start with Windows, then launches Glance in the top-right corner.

> **SmartScreen:** the installer isn't code-signed, so Windows may show *"Windows protected your PC"*. Click **More info → Run anyway**. Everything the installer does is in [`installer/Install.ps1`](installer/Install.ps1).

Silent install for scripts and deployment:

```bat
Glance-Setup.exe /S            :: silent
Glance-Setup.exe /S /STARTUP   :: silent + start with Windows
```

Uninstall from **Settings → Apps**, from Glance's own **Settings → About → Uninstall**, or `"%LocalAppData%\Programs\Glance\Uninstall.cmd" /S`.

## Using it

| Action | How |
|---|---|
| Move | Drag the panel (switches position to *Free*) |
| Settings | Gear icon on the panel · double-click tray icon · tray menu → *Settings…* |
| Show / hide | Left-click the tray icon · the `—` button on the panel · your hotkey (Settings → General → Behaviour) |
| Change layout / position / click-through | Tray menu, or Settings → General |
| Reorder or hide metrics, set alert limits | Settings → Metrics |
| Icons, colours, text size | Settings → Appearance |
| Quit | Tray menu → *Exit* |

Settings live in `%AppData%\Glance\settings.json` and apply instantly. With a file named `portable` next to `Glance.exe` they live in `data\` beside it instead. A row showing a small warning icon means that metric's counter failed - hover it for the reason; details are in `error.log` in the same folder.

### Where the numbers come from

| Metric | Source |
|---|---|
| CPU, per-core, RAM, disks | Windows performance counters (locale-independent CIM classes); disk throughput is averaged over ~5 s because writes reach the disk in cache-flush bursts |
| CPU temperature | ACPI thermal zone — only shown when the firmware exposes one |
| GPU | `nvidia-smi` when present (load, VRAM, temperature); otherwise Windows GPU engine counters. The *GPU engines* row always uses the Windows counters |
| Network | Byte counters of every *physical* adapter that is up — virtual adapters (Hyper-V, VMware, VPN) are skipped unless you pick one explicitly. Wi-Fi signal comes from `netsh wlan` |

## How it works

Glance is a WPF application written in PowerShell. `Glance.exe` is a ~110 KB native host that embeds the script and runs it in-process through the Windows PowerShell 5.1 engine that is part of every Windows install — so there is no `powershell.exe` in Task Manager and nothing to download.

Everything, including the exe and the installer, is compiled with the C# compiler that ships inside the .NET Framework on Windows. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for building, testing and the project layout.

## Requirements

Windows 10 or 11 (64-bit). Nothing else.

## License

[MIT](LICENSE)
