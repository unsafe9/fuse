<img src="assets/icon.png" width="128">

# Fuse

A menubar-only timer for macOS that burns a glowing fuse along the edge of your screen.

When a timer runs, Fuse draws a line across a full screen edge — over fullscreen apps and every Space — that shrinks as time burns down, with a glowing tip at the receding end. One glance tells you how much is left without ever leaving what you're doing.

## Features

- **Menubar-only** — no Dock icon, no window. Lives entirely in a status-bar menu (`LSUIElement`).
- **Burning-fuse overlay** — a line spanning a full screen edge, visible over all apps, fullscreen windows, and Spaces, shrinking toward a glowing tip as the timer counts down. Configurable color, thickness, edge, and target display.
- **Presets** — one ordered, reorderable list of time expressions you mix freely: fixed durations (`5m`, `1h30m`, `90`, `45s`) and minute-of-hour marks (`:15`, `:30`, `:45`, `:00`). The list order sets the menu order.
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

Click the menubar icon to open the menu. It lists your presets in order. Each preset is a time expression:

- A **duration** expression starts a timer for a fixed length and shows as *25 min*, *1 h 30 min*, *45 sec*, etc.
- A **minute-of-hour mark** (`:MM`) targets the next time the clock reaches that minute, and shows the computed target time — e.g. at 14:50, *:15* ends at 15:15, *:30* at 15:30, *:45* at 15:45, and *:00* (top of the hour) at 15:00. Exactly on a mark, the next occurrence is used (at 15:15 sharp, *:15* ends at 16:15).

Use **Custom Timer…** for anything not in your preset list. The panel accepts the same time expressions plus an optional name:

| Expression        | Meaning                                                            |
| ----------------- | ----------------------------------------------------------------- |
| `5m`              | 5 minutes                                                         |
| `1h30m`           | 1 hour 30 minutes (compound `(\d+h)?(\d+m)?(\d+s)?`)              |
| `90`              | a bare number means minutes → 90 minutes                          |
| `45s`             | 45 seconds                                                        |
| `:15`             | minute-of-hour mark → the next time the clock minute hits 15 (`:00` = top of the hour) |
| `10:00`           | the next occurrence of that 24-hour wall-clock time (today if still in the future, else tomorrow) |
| `23:30`           | next occurrence of 23:30                                          |

A leading-colon `:MM` (no hour digits, `MM` 00–59) is a minute-of-hour mark; with hour digits before the colon it's an absolute `HH:MM` clock time. Invalid input (empty, garbage, a zero or negative total, a mark with `MM` > 59, or a clock time with minutes > 59 / hours > 23) is rejected with an inline message.

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

Fuse also exposes read-only properties on the application for querying presets and the current timer state:

| Property     | Type         | Meaning                                            |
| ------------ | ------------ | -------------------------------------------------- |
| `presets`    | list of text | The stored preset expressions, in order.           |
| `running`    | boolean      | `true` while a timer is active.                    |
| `remaining`  | integer      | Whole seconds left on the running timer (`0` if none). |
| `timer name` | text         | The running timer's name (`""` if none or unnamed). |

```sh
osascript -e 'tell application "Fuse" to get presets'
osascript -e 'tell application "Fuse" to get running'
osascript -e 'tell application "Fuse" to get remaining'
```

## Alfred workflow

The workflow source lives in [`alfred/`](alfred/). It drives Fuse through the same AppleScript commands, so the menubar app must be installed (the workflow auto-launches it).

To install, run `make alfred` (packages `build/Fuse.alfredworkflow`) and open the result with Alfred. `scripts/build_alfred_plist.py` regenerates `alfred/info.plist` from source.

Default keyword: **`fuse`** (configurable in the workflow's user settings).

```
fuse 5m tea          # start a 5-minute "tea" timer
fuse 10:00 standup   # start a timer until the next 10:00, named "standup"
fuse :15 sync        # start a timer until the next :15 minute mark, named "sync"
fuse stop            # stop the running timer (or "cancel")
```

An empty query lists your configured presets in order (read from the running app, or from stored settings when it's idle) as the default items — durations preview as "Start 5 min timer" / "ends at HH:MM" and minute-of-hour marks as "Next :15 timer" / "ends at HH:MM". When a timer is running, a Stop item (with the timer's name and remaining time) is shown at the top. Each result previews how Fuse will parse the expression before you press Enter.

## Settings

Settings open from the menu and are grouped into four tabs. Everything persists in `UserDefaults`.

**General**
- Presets — one editable, reorderable list of time expressions (default `1m/3m/5m/10m/15m/20m/30m/45m/60m/90m/120m/:15/:30/:45/:00`). Durations and minute-of-hour marks live in the same list; add with a text field that validates the expression (appended to the end, invalid input is rejected inline), remove per row, and reorder by dragging a row or using its up/down buttons. The list is deduplicated but not sorted — its order sets the menu order. There is no duration/deadline mode switch.
- Show remaining time in the menu bar (default on).

**Fuse**
- Enable overlay (master toggle, default on).
- Fuse color (default pure red).
- Thickness, 1–20 pt (default 4).
- Texture: Solid, Rope (a braided twist, default), or Wick (a wrapped cord). Drawn within the configured thickness.
- Burning tip: Glow (the classic dot), Flame (a licking flame, default), or Sparks (a flame with trailing embers). Flame and Sparks flicker and bulge a little past the line into the screen so the fire is visible without widening the line itself.
- Tip size: a 0.5×–3× slider (default 1×) that scales the burning tip (and the room it has to bulge into the screen).
- Position: top, bottom, left, or right edge (default top).
- Display: main display, all displays, or a specific screen (default main display).
- Reset to Defaults restores color, thickness, texture, burning tip, and position to their defaults (presets, display, notifications, and power options are left alone).

While the Fuse tab is open, a live overlay preview is drawn on screen so color, thickness, texture, burning tip, position, and display changes are visible immediately (the flame/sparks even animate), even with no timer running. A real running timer always takes over.

**Notifications**
- Enable notifications (default on).
- Notification body template (default *Time's up!*).
- Play sound (default on).

**Power**
- Prevent system idle sleep while a timer runs (default on).
- Keep Mac awake with the lid closed (default off; see below).

## Permissions

**Notifications.** Completion notifications need notification permission. If it hasn't been granted, the menu surfaces a *Notifications disabled — click to fix* item that requests authorization, or — once denied — deep-links System Settings straight to Fuse's own row in the Notifications pane (via the per-app `…Notifications-Settings.extension?id=<bundle id>` URL) so *Allow Notifications* is one click away.

**Keep awake with lid closed.** This option disables clamshell-close sleep through the `IOPMrootDomain` user client (the same rootless mechanism Amphetamine's Closed-Display Mode uses) — **no administrator password, ever.** Fuse sets the bit when a timer starts and clears it when the timer ends or the app quits. On Apple Silicon the bit can be dropped across a power-source change (plugging/unplugging the charger), so Fuse re-asserts it on power-source changes and on a periodic heartbeat while a timer runs.

> The kernel only re-evaluates lid-close sleep when this bit transitions, so Fuse always clears it on every stop path including app termination. The bit is global, in-RAM kernel state that the kernel does *not* release when the app dies, so Fuse also persists a flag while it holds the bit and reconciles on the next launch: if it finds the flag set with no timer running (i.e. a previous crash or force-quit), it drops the bit so a closed lid sleeps again. A reboot clears the bit regardless. The only case neither reaches — deleting the app while a timer is mid-run with the bit set — self-heals on the next reboot.

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
