<img src="assets/icon.png" width="128">

# Fuse

A menubar-only timer for macOS that burns a glowing fuse along the edge of your screen.

When a timer runs, Fuse draws a line across a full screen edge — over fullscreen apps and every Space — that shrinks as time burns down, with a glowing tip at the receding end. One glance tells you how much is left without ever leaving what you're doing.

## Features

- **Menubar-only** — no Dock icon, no window. Lives entirely in a status-bar menu (`LSUIElement`).
- **Burning-fuse overlay** — a line spanning a full screen edge, visible over all apps, fullscreen windows, and Spaces, shrinking toward a glowing tip as the timer counts down. Configurable color, thickness, edge, and target display.
- **Presets** — duration presets (default `1/3/5/10/15/20/30/45/60/90/120` minutes) and deadline presets that target the next minute-of-hour mark (default `:15/:30/:45/top of hour`). Show duration only, deadline only, or both.
- **Custom timer panel** — type a time expression (and an optional name) for anything the presets don't cover.
- **Single timer** — exactly one timer runs at a time; starting a new one silently replaces the running one.
- **Completion notification** — delivered via the system notification center, with a configurable body and an optional sound.
- **Remaining time in the menu bar** — optionally show the live countdown next to the icon.
- **Caffeinate-style power options** — prevent system idle sleep while a timer runs, and optionally keep the Mac awake even with the lid closed.
- **AppleScript and Alfred** — start and stop timers from scripts or from an Alfred keyword.

## Install

### From a release (DMG)

1. Download the latest `Fuse-x.y.z.dmg` from [GitHub Releases](../../releases).
2. Open it and drag **Fuse.app** into **Applications**.

The app is **ad-hoc signed and not notarized**, so Gatekeeper blocks the first launch. To open it, either:

- Right-click **Fuse.app** → **Open**, then confirm in the dialog, or
- Clear the quarantine attribute from a terminal:

  ```sh
  xattr -d com.apple.quarantine /Applications/Fuse.app
  ```

### From source

Requires macOS 13+ and a Swift toolchain (Xcode command-line tools).

```sh
make install
```

This builds the app, bundles it, and installs it to `/Applications/Fuse.app`.

## Usage

Click the menubar icon to open the menu. It lists your presets in two flavors:

- **Duration** presets start a timer for a fixed length (e.g. *25 min*).
- **Deadline** presets target the next time the clock reaches a given minute-of-hour mark (e.g. at 14:50, *:15* ends at 15:15, *:30* at 15:30, *:45* at 15:45, and *top of hour* at 15:00). Exactly on a mark, the next occurrence is used (at 15:15 sharp, *:15* ends at 16:15).

Use **Custom Timer…** for anything else. The panel accepts a time expression and an optional name:

| Expression        | Meaning                                                            |
| ----------------- | ----------------------------------------------------------------- |
| `5m`              | 5 minutes                                                         |
| `1h30m`           | 1 hour 30 minutes (compound `(\d+h)?(\d+m)?(\d+s)?`)              |
| `90`              | a bare number means minutes → 90 minutes                          |
| `45s`             | 45 seconds                                                        |
| `10:00`           | the next occurrence of that 24-hour wall-clock time (today if still in the future, else tomorrow) |
| `23:30`           | next occurrence of 23:30                                          |

Invalid input (empty, garbage, a zero or negative total, or a clock time with minutes > 59 / hours > 23) is rejected with an inline message.

**Single-timer semantics:** Fuse runs one timer at a time. Starting a new timer — from a preset, the custom panel, AppleScript, or Alfred — silently replaces whatever was running.

## AppleScript

Fuse exposes two commands.

Start a timer (the optional `named` argument sets the timer name):

```sh
osascript -e 'tell application "Fuse" to start timer "5m" named "tea"'
osascript -e 'tell application "Fuse" to start timer "10:00"'
```

Stop the running timer:

```sh
osascript -e 'tell application "Fuse" to stop timer'
```

The expression grammar is identical to the custom panel. On bad input the command sets an AppleScript error with the same human-readable reason shown in the panel.

## Alfred workflow

The workflow source lives in [`alfred/`](alfred/). It drives Fuse through the same AppleScript commands, so the menubar app must be installed (the workflow auto-launches it).

To install, run `make alfred` (packages `build/Fuse.alfredworkflow`) and open the result with Alfred. `scripts/build_alfred_plist.py` regenerates `alfred/info.plist` from source.

Default keyword: **`timer`** (configurable in the workflow's user settings).

```
timer 5m tea          # start a 5-minute "tea" timer
timer 10:00 standup   # start a timer until the next 10:00, named "standup"
timer stop            # stop the running timer (or "cancel")
```

An empty query lists quick suggestions plus a stop action. Each result previews how Fuse will parse the expression before you press Enter.

## Settings

Settings open from the menu and are grouped into four tabs. Everything persists in `UserDefaults`.

**General**
- Preset mode: duration only, deadline only, or both (default both).
- Duration presets — an editable list of minute values (default `1/3/5/10/15/20/30/45/60/90/120`); add with a numeric field, remove per row. Kept sorted and deduplicated.
- Deadline presets — an editable list of minute-of-hour marks, 1–60, where 60 means the top of the hour (default `:15/:30/:45/top of hour`), with the same add/remove list controls.
- Show remaining time in the menu bar (default on).

**Fuse**
- Enable overlay (master toggle, default on).
- Fuse color (default pure red).
- Thickness, 1–20 pt (default 4).
- Position: top, bottom, left, or right edge (default top).
- Display: main display, all displays, or a specific screen (default main display).

While the Fuse tab is open, a live overlay preview is drawn on screen so color, thickness, position, and display changes are visible immediately, even with no timer running. A real running timer always takes over.

**Notifications**
- Enable notifications (default on).
- Notification body template (default *Time's up!*).
- Play sound (default on).

**Power**
- Prevent system idle sleep while a timer runs (default on).
- Keep Mac awake with the lid closed (default off; see below).

## Permissions

**Notifications.** Completion notifications need notification permission. If it hasn't been granted, the menu surfaces a *Notifications disabled — click to fix* item that requests authorization, or opens the System Settings Notifications pane when it has been denied.

**Keep awake with lid closed.** This option uses `pmset disablesleep`, which requires administrator rights. macOS prompts for your password when a timer starts. Fuse restores the setting (`pmset disablesleep 0`) when the timer ends or the app quits — and only if it actually set it.

> If Fuse crashes or is force-killed while this option is active, it may leave the system stuck with sleep disabled. Restore it manually:
>
> ```sh
> sudo pmset -b disablesleep 0
> ```

## Development

The build is driven by `make` and Swift Package Manager.

| Target          | Does                                                                 |
| --------------- | ------------------------------------------------------------------- |
| `make build`    | Compile with `swift build -c release`.                              |
| `make bundle`   | Assemble `build/Fuse.app` (Info.plist, icon, sdef, ad-hoc codesign).|
| `make dmg`      | Build a compressed DMG with an `/Applications` symlink.             |
| `make install`  | Bundle and install to `/Applications/Fuse.app`.                    |
| `make run`      | Bundle and launch the app.                                          |
| `make clean`    | Remove `.build/` and `build/`.                                      |

Pass `ARCHS=universal` to build a fat binary for arm64 + x86_64 (used by the release pipeline).

### Releasing

Releases are tag-driven. The `version-bump` skill takes a `patch` / `minor` / `major` (or explicit `X.Y.Z`) argument and:

1. Commits any remaining changes.
2. Rolls `CHANGELOG.md` (renames `## [Unreleased]` to the new version + date) and bumps the `VERSION` file in one `chore(release)` commit.
3. Creates an annotated `vX.Y.Z` tag and pushes it.

Pushing the tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml), which verifies the tag matches `VERSION`, builds a **universal** DMG (`make dmg ARCHS=universal`), extracts that version's changelog section as the release notes, and publishes a GitHub Release with the DMG attached.
