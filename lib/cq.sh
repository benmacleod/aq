# Shared helpers for cq and cq-hook. Source this file; do not execute it.
#
# Each Claude session has one JSON file, $CQ_DIR/<session_id>.json.
# Timestamps are epoch seconds.

CQ_DIR="${CQ_DIR:-$HOME/.claude/attention}"

# Hooks run in whatever environment launched Claude (e.g. Zed's agent
# process), and SwiftBar runs plugins with a bare PATH. Make sure Homebrew's
# jq, tmux and terminal-notifier are found either way. Appended, so anything
# earlier on PATH still wins.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

# Without a UTF-8 locale, cut fails on titles that contain emoji or smart
# quotes.
export LC_ALL=en_US.UTF-8

cq_now() {
  date +%s
}

cq_state_file() {
  printf '%s/%s.json' "$CQ_DIR" "$1"
}

# cq_merge_state <session_id> <jq filter> [jq args...]
#
# Runs the filter over the session's current state ({} if there is none) and
# writes the result back. The write goes through a temp file and mv, so a
# reader never sees a half-written file.
cq_merge_state() {
  local file tmp
  file="$(cq_state_file "$1")"
  mkdir -p "$CQ_DIR"
  tmp="$(mktemp "$CQ_DIR/.tmp.XXXXXX")"
  if { [ -f "$file" ] && cat "$file" || echo '{}'; } | jq "${@:3}" "$2" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Prints when a process started, or nothing if it isn't running. Comparing
# this with the recorded value tells a live session from a reused PID.
cq_process_started() {
  ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'
}
