#!/bin/zsh
# Fuse timer action. Receives the raw Script Filter arg as $1.
#   "stop" / "cancel"  -> stop the running timer
#   "!last"            -> re-start the most recently started timer (single shot)
#   "EXPR [xN] [NAME]" -> start a timer; EXPR keeps a trailing repeat suffix (xN),
#                         the remainder is NAME. EXPR is passed whole to `start timer`
#                         so the app authoritatively parses the xN repeat (e.g. "5m x4").
# On stop, prints a status line to stdout (shown by the Post Notification). On start it
# stays silent: the on-screen fuse is the confirmation, so no notification is fired
# (the Post Notification has onlyshowifquerypopulated set, so empty output = no banner).
set -e

raw="$1"
# trim leading/trailing whitespace
raw="${raw#"${raw%%[![:space:]]*}"}"
raw="${raw%"${raw##*[![:space:]]}"}"

lowered="${raw:l}"
if [[ "$lowered" == "stop" || "$lowered" == "cancel" ]]; then
  if ! osascript -e 'tell application "Fuse" to stop timer' 2>/tmp/fuse_alfred.err; then
    cat /tmp/fuse_alfred.err >&2
    exit 1
  fi
  print -r -- "Timer stopped"
  exit 0
fi

if [[ "$lowered" == "!last" ]]; then
  if ! osascript -e 'tell application "Fuse" to repeat last timer' 2>/tmp/fuse_alfred.err; then
    cat /tmp/fuse_alfred.err >&2
    exit 1
  fi
  exit 0
fi

# Split EXPR [xN] [NAME]: the first token is the time expression; if the next token is
# a repeat suffix (xN, case-insensitive), keep it on EXPR so the app parses the repeat;
# everything after that is the NAME.
expr="${raw%% *}"
rest=""
if [[ "$raw" == *" "* ]]; then
  rest="${raw#* }"
  rest="${rest#"${rest%%[![:space:]]*}"}"
fi
if [[ -n "$rest" ]]; then
  next="${rest%% *}"
  if [[ "${next:l}" == x<-> ]]; then
    expr="$expr $next"
    if [[ "$rest" == *" "* ]]; then
      rest="${rest#* }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
    else
      rest=""
    fi
  fi
fi
name="${rest%"${rest##*[![:space:]]}"}"

if [[ -n "$name" ]]; then
  if ! osascript \
      -e 'on run argv' \
      -e 'tell application "Fuse" to start timer (item 1 of argv) named (item 2 of argv)' \
      -e 'end run' \
      "$expr" "$name" 2>/tmp/fuse_alfred.err; then
    cat /tmp/fuse_alfred.err >&2
    exit 1
  fi
else
  if ! osascript \
      -e 'on run argv' \
      -e 'tell application "Fuse" to start timer (item 1 of argv)' \
      -e 'end run' \
      "$expr" 2>/tmp/fuse_alfred.err; then
    cat /tmp/fuse_alfred.err >&2
    exit 1
  fi
fi

# Intentionally silent on start: the on-screen fuse is the confirmation.
