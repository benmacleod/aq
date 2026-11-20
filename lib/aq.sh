# shellcheck shell=bash
# Shared helpers for aq and aq-record. Source this file; do not execute it.
#
# Each agent session has one JSON file, $AQ_STATE_DIR/<session_id>.json.
# Agents use UUIDs as session IDs, so sessions of different agents don't
# clash.
# Timestamps are epoch seconds.

AQ_STATE_DIR="${AQ_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/aq}"
AQ_CONFIG_DIR="${AQ_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aq}"

# Hooks run in whatever environment launched Claude (e.g. Zed's agent
# process), and SwiftBar runs plugins with a bare PATH. Make sure Homebrew's
# jq, tmux and terminal-notifier are found either way. Appended, so anything
# earlier on PATH still wins.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

# Without a UTF-8 locale, cut fails on titles that contain emoji or smart
# quotes.
export LC_ALL=en_US.UTF-8

aq_now() {
  date +%s
}

aq_state_file() {
  printf '%s/%s.json' "$AQ_STATE_DIR" "$1"
}

# aq_merge_state <session_id> <jq filter> [jq args...]
#
# Runs the filter over the session's current state ({} if there is none) and
# writes the result back. The write goes through a temp file and mv, so a
# reader never sees a half-written file.
aq_merge_state() {
  local file tmp
  file="$(aq_state_file "$1")"
  mkdir -p "$AQ_STATE_DIR"
  tmp="$(mktemp "$AQ_STATE_DIR/.tmp.XXXXXX")"
  if { [ -f "$file" ] && cat "$file" || echo '{}'; } | jq "${@:3}" "$2" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Prints when a process started, or nothing if it isn't running. Comparing
# this with the recorded value tells a live session from a reused PID.
aq_process_started() {
  ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'
}
