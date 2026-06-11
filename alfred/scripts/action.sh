#!/bin/zsh
# Fuse timer action. Receives the raw Script Filter arg as $1.
#   "stop" / "cancel"  -> stop the running timer
#   "EXPR [NAME]"      -> start a timer; first token = EXPR, remainder = NAME
# Prints a human status line to stdout (consumed by the Post Notification).
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

expr="${raw%% *}"
name=""
if [[ "$raw" == *" "* ]]; then
  name="${raw#* }"
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
fi

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

print -r -- "Timer started: $raw"
