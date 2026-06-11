#!/usr/bin/env python3
"""Generate alfred/info.plist via plistlib (no hand-concatenated XML)."""
import plistlib
import os

SF = "98CA8C73-9A9E-4FD6-ACD7-B01B55351900"  # Script Filter
RUN = "C3C073DC-4A22-4C87-8C57-39752CC98772"  # Run Script
NOTE = "36882643-ABB0-42BA-929D-AF9B38DA0E1C"  # Post Notification

doc = {
    "bundleid": "com.unsafe9.fuse.alfred",
    "name": "Fuse Timer",
    "description": "Start Fuse timers from Alfred",
    "createdby": "unsafe9",
    "category": "Productivity",
    "disabled": False,
    "version": "1.0",
    "webaddress": "",
    "readme": (
        "## Usage\n\n"
        "Type the keyword (default <kbd>timer</kbd>) then a timer expression:\n\n"
        "- `5m`, `1h`, `1h30m`, `45s` — durations\n"
        "- `25` — a bare number means minutes\n"
        "- `10:00`, `23:30` — the next occurrence of that wall-clock time\n\n"
        "Add an optional name after the expression: `5m tea`, `10:00 standup`.\n"
        "An empty query lists quick suggestions and a stop action; type `stop` "
        "(or `cancel`) to cancel the running timer.\n\n"
        "Requires the Fuse menubar app; telling it auto-launches it."
    ),
    "variables": {},
    "userconfigurationconfig": [
        {
            "type": "textfield",
            "variable": "keyword",
            "label": "Keyword",
            "description": "Keyword that triggers the Fuse timer Script Filter.",
            "config": {
                "default": "timer",
                "placeholder": "timer",
                "required": False,
                "trim": True,
            },
        }
    ],
    "objects": [
        {
            "uid": SF,
            "type": "alfred.workflow.input.scriptfilter",
            "version": 3,
            "config": {
                "alfredfiltersresults": False,
                "alfredfiltersresultsmatchmode": 0,
                "argumenttreatemptyqueryasnil": False,
                "argumenttrimmode": 0,
                "argumenttype": 1,
                "escaping": 102,
                "keyword": "{var:keyword}",
                "queuedelaycustom": 3,
                "queuedelayimmediatelyinitially": True,
                "queuedelaymode": 0,
                "queuemode": 1,
                "runningsubtext": "Parsing…",
                "script": 'python3 scripts/filter.py "$1"',
                "scriptargtype": 1,
                "scriptfile": "",
                "skipuniversalaction": True,
                "subtext": "Start a Fuse timer: 5m, 1h30m, 25, 10:00 — optionally with a name",
                "title": "Fuse Timer",
                "type": 11,
                "withspace": True,
            },
        },
        {
            "uid": RUN,
            "type": "alfred.workflow.action.script",
            "version": 2,
            "config": {
                "concurrently": False,
                "escaping": 102,
                "script": './scripts/action.sh "$1"',
                "scriptargtype": 1,
                "scriptfile": "",
                "type": 11,
            },
        },
        {
            "uid": NOTE,
            "type": "alfred.workflow.output.notification",
            "version": 1,
            "config": {
                "lastpathcomponent": False,
                "onlyshowifquerypopulated": False,
                "removeextension": False,
                "text": "{query}",
                "title": "Fuse",
            },
        },
    ],
    "connections": {
        SF: [
            {
                "destinationuid": RUN,
                "modifiers": 0,
                "modifiersubtext": "",
                "vitoclose": False,
            }
        ],
        RUN: [
            {
                "destinationuid": NOTE,
                "modifiers": 0,
                "modifiersubtext": "",
                "vitoclose": False,
            }
        ],
        NOTE: [],
    },
    "uidata": {
        SF: {
            "xpos": 60.0,
            "ypos": 60.0,
            "note": "Type a timer expression; items preview the parse",
            "colorindex": 9,
        },
        RUN: {
            "xpos": 260.0,
            "ypos": 60.0,
            "note": "Parse argv, call Fuse via osascript",
        },
        NOTE: {
            "xpos": 460.0,
            "ypos": 60.0,
            "note": "Confirm start/stop",
        },
    },
}

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "alfred", "info.plist")
with open(out, "wb") as f:
    plistlib.dump(doc, f, sort_keys=True)
print("wrote", out)
