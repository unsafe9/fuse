# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Duration and deadline presets can now be reordered manually — drag a row or use
  its up/down buttons — and that order drives the menu order. New values append to
  the end; the lists are still deduplicated but no longer force-sorted on insert.
- Alfred workflow default keyword changed from `timer` to `fuse`.
- Keep-awake-with-lid-closed no longer requires an administrator password. It now
  disables clamshell-close sleep through the rootless `IOPMrootDomain` user client
  instead of `pmset disablesleep`, and re-asserts the state across Apple Silicon
  power-source changes (with a periodic heartbeat) so it survives plugging or
  unplugging the charger.

## [0.1.0] - 2026-06-11

### Added

- Menubar-only (LSUIElement) timer app with a status item menu of timer presets.
- Duration presets (configurable minutes; default 1/3/5/10/15/20/30/45/60/90/120)
  and deadline presets (configurable minute-of-hour marks, 1–60; default
  15/30/45/60) that target the next time the clock reaches that minute, with 60
  meaning the top of the hour.
- Preset display mode: duration, deadline, or both (default both).
- Custom Timer panel accepting time expressions (`5m`, `1h30m`, `90`, `10:00`,
  `23:30`) plus an optional name.
- Burning-fuse overlay drawn full-width/height along a configurable screen edge,
  visible over all apps, fullscreen windows, and Spaces, with a glowing tip at
  the receding (burning) end.
- Completion notification via UNUserNotificationCenter with a configurable body
  template and optional sound.
- Settings (persisted in UserDefaults): duration presets, deadline presets,
  preset mode, fuse color, thickness, edge position, target display (main
  display by default, all displays, or a specific screen), overlay
  master toggle, show-remaining-time-in-menubar toggle, notification settings,
  prevent-system-sleep toggle, and keep-awake-with-lid-closed toggle. Presets
  are edited as native add/remove lists (sorted, deduplicated), and the Fuse
  tab draws a live overlay preview so appearance changes are visible without a
  running timer.
- Single-timer model: starting a new timer silently replaces the running one.
- Custom monochrome menu-bar glyph (stylized burning fuse); full-bleed app icon
  that renders edge-to-edge under the macOS squircle mask.
- AppleScript support: `start timer "5m" named "tea"` and `stop timer`.
- Notification-permission guidance surfaced in the menu when not granted.
