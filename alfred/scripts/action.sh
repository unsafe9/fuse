#!/bin/zsh
# Fuse timer action. Receives the raw Script Filter arg as $1.
#   "stop" / "cancel"  -> stop the running timer
#   "EXPR [NAME]"      -> start a timer; first token = EXPR, remainder = NAME
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

# Intentionally silent on start: the on-screen fuse is the confirmation.
