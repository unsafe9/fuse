#!/usr/bin/env python3
"""Alfred Script Filter for the Fuse menubar timer.

Previews how Fuse will parse the typed query and emits Script Filter JSON.
The Fuse app re-parses the expression authoritatively at run time — this
script only mirrors the rules to show a live preview.

Accepted EXPR forms:
  durations  5m, 1h, 1h30m, 45s, 90s
  bare int   25            -> minutes
  24h clock  10:00, 23:30  -> next occurrence of that wall-clock time
A trailing NAME may follow the expression: "5m tea", "10:00 standup".
"""
import json
import re
import sys
from datetime import datetime, timedelta

SUGGESTIONS = ["5m", "10m", "15m", "30m", "1h", "2h"]
STOP_WORDS = {"stop", "cancel"}

DURATION_RE = re.compile(r"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$", re.IGNORECASE)
CLOCK_RE = re.compile(r"^(\d{1,2}):(\d{2})$")


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


def stop_item():
    return item("Stop the running timer", "Cancel Fuse's active timer",
                "stop", autocomplete="stop", uid="fuse-stop")


def suggestion_items():
    items = []
    for expr in SUGGESTIONS:
        secs = parse_duration(expr)
        items.append(item(
            f"Start {human_duration(secs)} timer",
            "Press Enter to start now, or Tab to add a name",
            expr, autocomplete=f"{expr} ", uid=f"fuse-{expr}"))
    items.append(stop_item())
    return items


def build(query):
    query = (query or "").strip()
    if not query:
        return suggestion_items()

    lowered = query.lower()
    if lowered in STOP_WORDS:
        return [stop_item()]

    parts = query.split(None, 1)
    expr = parts[0]
    name = parts[1].strip() if len(parts) > 1 else ""

    secs = parse_duration(expr)
    if secs is not None and secs > 0:
        end = datetime.now() + timedelta(seconds=secs)
        return [item(
            f"Start {human_duration(secs)} timer",
            f"{named_suffix(name)}ends at {end.strftime('%H:%M')}",
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
        "Try 5m, 1h30m, 45s, 25 (minutes), or 10:00 — optionally with a name",
        query, valid=False, uid="fuse-invalid")]


def main():
    query = sys.argv[1] if len(sys.argv) > 1 else ""
    print(json.dumps({"items": build(query), "skipknowledge": True}))


if __name__ == "__main__":
    main()
