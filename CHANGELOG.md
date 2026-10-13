# Changelog

## Unreleased

- Hide over full-screen apps now only reacts to full-screen windows on the monitor the overlay sits on; a game on another display leaves it visible. Maximized windows with a title bar are no longer mistaken for full-screen.

## 2.3 — 2026-10-13

### Added

- **Metric order** — arrows on Settings → Metrics reorder the readouts.
- **New readouts**: CPU cores (per-core text graph), GPU engines (3D / Copy / Decode / Encode / Compute), Adapter (name, Wi-Fi signal). All off by default.
- **Alerts** — limits for CPU/GPU load and temperature, memory, disk busy and battery; the value and icon switch to a configurable alert colour.
- **Show/hide hotkey** (Settings → General → Behaviour); shows when the combination is taken by another app.
- **Hide over full-screen apps** — the overlay disappears while a game or video fills the screen and returns afterwards.
- **Monitor** choice for the preset positions on multi-display setups.
- **Compact bar** — icon + value only.
- **Custom colours** — a `#RRGGBB` box next to every swatch row (text and icon colours).
- **Portable mode** — a file named `portable` next to the exe keeps settings in `data\` beside it.
- Per-metric **failure marker**: a small warning icon with the error as tooltip when a counter stops working; each distinct error is logged once.
- Settings → Appearance → Text size; Metric text colours; Metric icons (picker with 55 glyphs + colour).
- Settings → Metrics → Disks: pick exactly which drive letters to show (replaces *All / System drive only*; migrated).

### Changed

- Background opacity can go down to 0 % (surface-less overlay); border and divider fade with it and text gains a soft shadow.
- *Top bar* is now *Bar* with a **Bar orientation** choice (horizontal top/bottom, vertical left/right); corner rounding follows the docked edge. Tray menu: *Horizontal bar* / *Vertical bar*.
- Every readout has an icon (Segoe MDL2 Assets) in the metric's colour, replacing the colour rail and the ↓/↑ label arrows.
- Settings file carries a `SchemaVersion`; older files are upgraded step by step. Saves are atomic (temp file + move).

### Fixed

- Rows cut off at right/bottom anchors: the overlay re-anchors whenever its size changes.
- Disk rows flickering between 0 and spikes during downloads: throughput is computed from raw counters over a ~5 s rolling window.
- Overlay re-anchors on DPI changes; errors inside UI handlers are logged instead of ending the process.
- Headless/screenshot runs no longer overwrite the saved settings on exit.

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
