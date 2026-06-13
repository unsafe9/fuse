# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] - 2026-06-13

### Added

- New **"Keep display awake while timer runs"** option in the Power settings tab (on by
  default). While a timer is active the screen no longer sleeps, so the burning fuse
  overlay stays visible and the Mac won't dim out behind a password lock screen. It's
  independent of "Prevent system idle sleep" — turn it off to save battery on a laptop.

## [0.1.2] - 2026-06-12

### Added

- Hovering over the on-screen fuse now shows a compact tooltip with the running timer's
  name and remaining time.

## [0.1.1] - 2026-06-12

### Added

- Selectable fuse design in the Fuse settings tab: a **Texture** for the line (Solid,
  Rope — a braided twist, default — or Wick — a wrapped cord), a **Burning tip** effect
  (Glow — the classic dot, Flame — a licking flame, default, or Sparks — a flame with
  trailing embers), and a **Tip size** slider (0.5×–3×, default 1×).
  The flame/sparks flicker, and the live appearance preview animates them. Textures only
  shade the configured-thickness line; the burning tip bulges a little past it (the
  overlay strip carries interior headroom that scales with the tip size) so the flame
  reads as fire without widening the line itself.
- A "Reset to Defaults" button in the Fuse settings tab restores the appearance
  settings — color, thickness, texture, burning tip, and position — to their defaults,
  leaving presets, display, notifications, and power options untouched.
- New `:MM` minute-of-hour mark time expression (leading colon, `MM` 00–59): targets
  the next instant whose clock minute equals `MM` with seconds zero (`:00` = the top
  of the hour). Distinct from absolute `HH:MM` clock times, which have hour digits
  before the colon. Works in the Custom Timer panel, AppleScript, and presets.
- AppleScript read-only properties on the application: `presets` (the stored preset
  expressions, in order), `running` (whether a timer is active), `remaining` (whole
  seconds left), and `timer name` (the running timer's name). For example:
  `osascript -e 'tell application "Fuse" to get presets'`.

### Changed

- Removed the `⌘,` (Settings) and `⌘.` (Cancel Timer) key-equivalent hints from the
  status-bar menu. As a menu-bar-only app with no focusable window, Fuse can't receive
  those as global shortcuts — they only fired while the menu was already open, which
  misleadingly implied a global hotkey. The menu items still work by click; `⌘Q` (Quit)
  is kept as the conventional in-menu shortcut.
- Presets are now a single ordered list of time expressions (e.g. `5m`, `1h30m`,
  `:15`, `:00`) that mixes durations and minute-of-hour marks freely, replacing the
  separate duration/deadline lists and the duration/deadline/both mode switch. The
  list is added to via a validating text field, deduplicated, reorderable by drag or
  up/down buttons, and its order drives the menu order. Existing duration/deadline
  presets are migrated into the unified list on first launch.
- The menu's "Notifications disabled — click to fix" item now deep-links System Settings
  straight to Fuse's own row in the Notifications pane (the per-app
  `…Notifications-Settings.extension?id=<bundle id>` URL) instead of just opening the
  general Notifications list, so "Allow Notifications" is one click away.
- Alfred workflow default keyword changed from `timer` to `fuse`.
- Alfred workflow's empty-query default items now come from the app's configured
  presets in order (read live from the running app, or from stored settings when it's
  idle, falling back to the built-in default list) instead of a hardcoded suggestion
  list, and minute-of-hour marks preview as "Next :15 timer" / "ends at HH:MM". When a
  timer is running, a Stop item (showing the timer's name and remaining time) is placed
  at the top of the list.
- Starting a timer from the Alfred workflow no longer fires a "Timer started"
  notification — the on-screen fuse is the confirmation. Stopping a timer still shows a
  brief "Timer stopped" banner, since there is no fuse left on screen to confirm it.
- Keep-awake-with-lid-closed no longer requires an administrator password. It now
  disables clamshell-close sleep through the rootless `IOPMrootDomain` user client
  instead of `pmset disablesleep`, and re-asserts the state across Apple Silicon
  power-source changes (with a periodic heartbeat) so it survives plugging or
  unplugging the charger. Because that clamshell bit is global kernel state that the
  kernel does not release when the app dies, Fuse persists a flag while it holds the bit
  and reconciles on the next launch — so a crash or force-quit mid-timer can't leave the
  lid permanently awake (a reboot also clears the bit regardless).

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
