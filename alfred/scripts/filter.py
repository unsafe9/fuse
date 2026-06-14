#!/usr/bin/env python3
"""Alfred Script Filter for the Fuse menubar timer.

Previews how Fuse will parse the typed query and emits Script Filter JSON.
The Fuse app re-parses the expression authoritatively at run time — this
script only mirrors the rules to show a live preview.

Accepted EXPR forms:
  durations  5m, 1h, 1h30m, 45s, 90s
  bare int   25            -> minutes
  24h clock  10:00, 23:30  -> next occurrence of that wall-clock time
  minute mark :15, :00     -> next time the clock minute hits MM (:00 = top of hour)
A trailing NAME may follow the expression: "5m tea", "10:00 standup", ":15 sync".

Empty query: the default item list comes from the app's configured presets, in
order. If a timer is running, a Stop item is shown at the top.
"""
import json
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timedelta

# Used only when the app's presets can't be read (app not running and no stored
# "presets" key). Mirrors SettingsStore.defaultPresets in the app.
FALLBACK_PRESETS = ["1m", "3m", "5m", "10m", "15m", "20m", "30m", "45m", "60m",
                    "90m", "120m", ":15", ":30", ":45", ":00"]
STOP_WORDS = {"stop", "cancel"}
REPEAT_LAST_WORD = "!last"  # arg passed to the action to call `repeat last timer`
BUNDLE_ID = "com.unsafe9.fuse"

DURATION_RE = re.compile(r"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$", re.IGNORECASE)
CLOCK_RE = re.compile(r"^(\d{1,2}):(\d{2})$")
MARK_RE = re.compile(r"^:(\d{2})$")  # leading colon, exactly 2 digits, 00..59
REPEAT_SUFFIX_RE = re.compile(r"^x(\d+)$", re.IGNORECASE)  # trailing "xN" repeat token


def parse_duration(expr):
    """Return total seconds for a duration/bare-int EXPR, or None."""
    if expr.isdigit():  # bare integer = minutes
        return int(expr) * 60
    m = DURATION_RE.match(expr)
    if not m or not any(m.groups()):
        return None
    h, mi, s = (int(g) if g else 0 for g in m.groups())
    return h * 3600 + mi * 60 + s


def parse_clock(expr):
    """Return (hour, minute) for a 24h-clock EXPR, or None."""
    m = CLOCK_RE.match(expr)
    if not m:
        return None
    hour, minute = int(m.group(1)), int(m.group(2))
    if hour > 23 or minute > 59:
        return None
    return hour, minute


def parse_mark(expr):
    """Return the minute (0..59) for a minute-of-hour mark EXPR, or None.

    A mark is a leading colon followed by exactly two digits (":15", ":00").
    ":00" means the top of the hour.
    """
    m = MARK_RE.match(expr)
    if not m:
        return None
    return int(m.group(1))


def next_mark_time(minute, now=None):
    """Next instant strictly after `now` whose clock minute equals `minute`
    (seconds zero). On an exact mark, the next occurrence is used."""
    now = now or datetime.now()
    target = now.replace(minute=minute, second=0, microsecond=0)
    while target <= now:
        target += timedelta(hours=1)
    return target


def human_duration(seconds):
    h, rem = divmod(seconds, 3600)
    mi, s = divmod(rem, 60)
    parts = []
    if h:
        parts.append(f"{h} h")
    if mi:
        parts.append(f"{mi} min")
    if s:
        parts.append(f"{s} sec")
    return " ".join(parts) if parts else "0 sec"


def human_remaining(seconds):
    """mm:ss, or h:mm:ss when an hour or more remains."""
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    mi, s = divmod(rem, 60)
    if h:
        return f"{h}:{mi:02d}:{s:02d}"
    return f"{mi}:{s:02d}"


def named_suffix(name):
    return f"named '{name}' — " if name else ""


def item(title, subtitle, arg, *, valid=True, autocomplete=None, uid=None):
    it = {"title": title, "subtitle": subtitle, "arg": arg, "valid": valid,
          "icon": {"path": "icon.png"}}
    if autocomplete is not None:
        it["autocomplete"] = autocomplete
    if uid is not None:
        it["uid"] = uid
    return it


def stop_item(name="", remaining=None):
    title = f"Stop “{name}”" if name else "Stop timer"
    if remaining is not None:
        subtitle = f"{human_remaining(remaining)} remaining"
    else:
        subtitle = "Cancel Fuse's active timer"
    return item(title, subtitle, "stop", autocomplete="stop", uid="fuse-stop")


def repeat_last_item(last_ended_at="", last_started="", last_started_name=""):
    """An item that re-starts the most recently started timer (single shot).

    The app re-resolves the stored expression authoritatively and is a no-op if
    nothing has been started yet. When the previous timer is known, the subtitle
    leads with what will be restarted (its expression and name); `last_ended_at`
    (HH:MM, may be empty) follows as a secondary hint.
    """
    if last_started:
        what = last_started
        if last_started_name:
            what += f' “{last_started_name}”'
        subtitle = f"Restart {what}"
    else:
        subtitle = "Re-start the most recent timer"
    if last_ended_at:
        subtitle += f" — last ended at {last_ended_at}"
    return item("Repeat last timer", subtitle, REPEAT_LAST_WORD,
                autocomplete=REPEAT_LAST_WORD, uid="fuse-repeat-last")


def preset_item(expr):
    """A default-list item for a stored preset expression, previewing what it does."""
    secs = parse_duration(expr)
    if secs is not None and secs > 0:
        end = datetime.now() + timedelta(seconds=secs)
        return item(
            f"Start {human_duration(secs)} timer",
            f"ends at {end.strftime('%H:%M')}",
            expr, autocomplete=f"{expr} ", uid=f"fuse-{expr}")

    minute = parse_mark(expr)
    if minute is not None:
        target = next_mark_time(minute)
        label = "top of the hour" if minute == 0 else f":{minute:02d}"
        return item(
            f"Next {label} timer",
            f"ends at {target.strftime('%H:%M')}",
            expr, autocomplete=f"{expr} ", uid=f"fuse-{expr}")

    clock = parse_clock(expr)
    if clock is not None:
        hour, minute = clock
        now = datetime.now()
        target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if target <= now:
            target += timedelta(days=1)
        return item(
            f"Start timer until {hour:02d}:{minute:02d}",
            f"ends at {hour:02d}:{minute:02d}",
            expr, autocomplete=f"{expr} ", uid=f"fuse-{expr}")

    # Unknown shape: still offer it; the app re-parses authoritatively.
    return item(expr, "Start this preset timer", expr,
                autocomplete=f"{expr} ", uid=f"fuse-{expr}")


# --- Data sources -----------------------------------------------------------

# ASCII unit separator: cannot appear in preset tokens, names, or our scalars.
US = "\x1f"


def app_is_running():
    """True if Fuse is already running. Does NOT launch it."""
    try:
        out = subprocess.run(
            ["osascript", "-e", 'application "Fuse" is running'],
            capture_output=True, text=True, timeout=5)
        return out.returncode == 0 and out.stdout.strip() == "true"
    except Exception:
        return False


def fetch_running_state():
    """One osascript call returning (presets, running, remaining, name,
    last_ended_at, last_started, last_started_name).

    Joins presets with the unit separator and separates scalar fields with it
    too, so the blob parses unambiguously. Returns None on any failure.
    """
    script = (
        'tell application "Fuse"\n'
        '  set AppleScript\'s text item delimiters to "\x1f"\n'
        '  set ps to presets as text\n'
        '  set AppleScript\'s text item delimiters to ""\n'
        '  return ps & "\x1e" & (running as text) & "\x1e" & '
        '(remaining as text) & "\x1e" & (timer name) & "\x1e" & '
        '(last ended at) & "\x1e" & (last started) & "\x1e" & '
        '(last started name)\n'
        'end tell'
    )
    try:
        out = subprocess.run(["osascript", "-e", script],
                             capture_output=True, text=True, timeout=5)
        if out.returncode != 0:
            return None
        blob = out.stdout.rstrip("\n")
        fields = blob.split("\x1e")
        if len(fields) < 7:
            return None
        (presets_raw, running_raw, remaining_raw, name, last_ended,
         last_started, last_started_name) = fields[:7]
        presets = [p for p in presets_raw.split(US) if p] if presets_raw else []
        running = running_raw.strip().lower() == "true"
        try:
            remaining = int(remaining_raw.strip())
        except ValueError:
            remaining = 0
        return (presets, running, remaining, name.strip(), last_ended.strip(),
                last_started.strip(), last_started_name.strip())
    except Exception:
        return None


def presets_from_defaults():
    """Read the stored 'presets' array via `defaults export` + plistlib.

    Returns the list, or None if the key is missing/empty or anything fails.
    """
    try:
        out = subprocess.run(["defaults", "export", BUNDLE_ID, "-"],
                             capture_output=True, timeout=5)
        if out.returncode != 0 or not out.stdout:
            return None
        data = plistlib.loads(out.stdout)
        presets = data.get("presets")
        if isinstance(presets, list) and presets:
            return [str(p) for p in presets]
        return None
    except Exception:
        return None


def default_items():
    """Build the empty-query item list: optional Stop item, a Repeat-last item, then
    presets in order."""
    if app_is_running():
        state = fetch_running_state()
        if state is not None:
            (presets, running, remaining, name, last_ended,
             last_started, last_started_name) = state
            if not presets:
                presets = FALLBACK_PRESETS
            items = []
            if running:
                items.append(stop_item(name, remaining))
            items.append(repeat_last_item(last_ended, last_started,
                                          last_started_name))
            items.extend(preset_item(expr) for expr in presets)
            return items
        # osascript failed despite app running: degrade gracefully.

    presets = presets_from_defaults() or FALLBACK_PRESETS
    return [repeat_last_item()] + [preset_item(expr) for expr in presets]


# --- Typed query preview ----------------------------------------------------

def split_repeat_and_name(rest):
    """Split the text after EXPR into (repeat_count, name).

    `rest` is everything after the time expression. A leading "xN" token (the same
    repeat suffix the app parses) is pulled off as the repeat count; the remainder is
    the name. Returns (None, name) when there is no repeat token.
    """
    rest = rest.strip()
    if not rest:
        return None, ""
    head, _, tail = rest.partition(" ")
    m = REPEAT_SUFFIX_RE.match(head)
    if m:
        return int(m.group(1)), tail.strip()
    return None, rest


def repeat_suffix(count):
    """A " ×N" badge for the preview title when repeating (count >= 2), else ""."""
    return f" ×{count}" if count and count >= 2 else ""


def build(query):
    query = (query or "").strip()
    if not query:
        return default_items()

    lowered = query.lower()
    if lowered in STOP_WORDS:
        return [stop_item()]
    if lowered == REPEAT_LAST_WORD:
        if app_is_running():
            state = fetch_running_state()
            if state is not None:
                _, _, _, _, last_ended, last_started, last_started_name = state
                return [repeat_last_item(last_ended, last_started,
                                         last_started_name)]
        return [repeat_last_item()]

    parts = query.split(None, 1)
    expr = parts[0]
    rest = parts[1] if len(parts) > 1 else ""
    repeat, name = split_repeat_and_name(rest)

    secs = parse_duration(expr)
    if secs is not None and secs > 0:
        end = datetime.now() + timedelta(seconds=secs)
        return [item(
            f"Start {human_duration(secs)} timer{repeat_suffix(repeat)}",
            f"{named_suffix(name)}ends at {end.strftime('%H:%M')}",
            query, uid="fuse-preview")]

    minute = parse_mark(expr)
    if minute is not None:
        target = next_mark_time(minute)
        label = "top of the hour" if minute == 0 else f":{minute:02d}"
        return [item(
            f"Next {label} timer",
            f"{named_suffix(name)}ends at {target.strftime('%H:%M')}",
            query, uid="fuse-preview")]

    clock = parse_clock(expr)
    if clock is not None:
        hour, minute = clock
        now = datetime.now()
        target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        when = "today"
        if target <= now:
            target += timedelta(days=1)
            when = "tomorrow"
        return [item(
            f"Start timer until {hour:02d}:{minute:02d}",
            f"{named_suffix(name)}ends at {hour:02d}:{minute:02d} ({when})",
            query, uid="fuse-preview")]

    return [item(
        "Unrecognised timer",
        "Try 5m, 1h30m, 45s, 25 (minutes), :15 (mark), or 10:00 — add ×N (x4) to repeat, plus a name",
        query, valid=False, uid="fuse-invalid")]


def main():
    query = sys.argv[1] if len(sys.argv) > 1 else ""
    print(json.dumps({"items": build(query), "skipknowledge": True}))


if __name__ == "__main__":
    main()
