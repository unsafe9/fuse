# Alfred Workflow Changelog

All notable changes to the **Fuse Alfred workflow** are documented here. The workflow is
released independently of the Fuse app, under `workflow-v*` tags (the app uses `v*`). It
drives the app through its AppleScript contract, so it also requires a compatible Fuse
app version — noted per release when a contract change makes a minimum app version
necessary.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repeat suffix: append `xN` to a duration to auto-repeat it (`25m x4` runs four
  rounds). A name may still follow (`25m x4 pomodoro`). The expression is passed whole
  to the app's `start timer`, which parses the `xN` authoritatively; repeat only applies
  to durations, not clock times.
- Repeat-last entry: a "Repeat last timer" item in the empty-query list, and the `!last`
  argument, both call the app's `repeat last timer` to re-start the most recent timer as
  a single shot. Requires a Fuse app version that supports the `repeat last timer`
  command and the `last ended at` property.

## [1.0.0] - 2026-06-12

First independently-versioned release. Requires the Fuse app (any released version;
auto-launched on use).

### Added

- Script Filter under the keyword `fuse` (configurable in the workflow's user settings)
  that starts a Fuse timer from a time expression: `5m`, `1h30m`, `45s`, a bare number
  for minutes, `10:00`/`23:30` clock times, and `:15`/`:00` minute-of-hour marks, each
  with an optional trailing name (`5m tea`).
- Empty-query items come from the app's configured presets in order — read live from the
  running app, or from stored settings when it is idle, with a built-in fallback list.
  Minute-of-hour marks preview as "Next :15 timer" / "ends at HH:MM".
- A Stop item is shown at the top of the list (with the running timer's name and time
  left) when a timer is active; `stop` / `cancel` also cancels it.
- Starting a timer is silent — the on-screen fuse is the confirmation. Stopping a timer
  shows a brief "Timer stopped" banner, since there is no fuse left on screen.
