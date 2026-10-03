# Changelog

## 2.2 — 2026-10-03

- Renamed to **Glance**. The installer removes a previous "SysMonitor" install and carries over its settings and start-with-Windows preference.
- Native `Glance.exe`: the script now runs inside a small host executable (in-process Windows PowerShell 5.1) instead of `powershell.exe`.
- Both installers (`Glance-Setup.exe`, `Glance-Setup.cmd`) ship the exe only.

## 2.1

- Preset positions: 3×3 picker in Settings → General and a *Position* submenu in the tray menu. Dragging switches to *Free*.
- Bar layout snaps flush to the top or bottom edge with matching corner rounding.
- One-file installers with `/S` and `/STARTUP`, Apps & Features registration and a self-deleting uninstaller.

## 2.0

- Redesigned overlay: colour-coded rails, monospace values, 60-second sparklines, usage tracks, header with settings / hide buttons.
- Full settings window (General, Appearance, Metrics, Network, About) with live-applying controls.
- Accent colours, per-metric visibility, adapter selection, bytes/bits, refresh interval, size and opacity.

## 1.0

- Initial single-file PowerShell + WPF overlay: CPU, RAM, GPU, disks, network, top process, uptime, battery; tray icon; panel/bar layout.
