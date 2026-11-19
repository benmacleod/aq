#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../bin/cq"

setup() {
  export CQ_DIR="$(mktemp -d)"
  export REPO="$(mktemp -d)"
  export MOCK_DIR="$(mktemp -d)"
  export PATH="$MOCK_DIR:$PATH"
  NOW="$(date +%s)"

  for cmd in zed tmux pbcopy open osascript terminal-notifier; do
    cat > "$MOCK_DIR/$cmd" << EOF
#!/usr/bin/env bash
echo "$cmd \$*" >> "$MOCK_DIR/calls"
EOF
    chmod +x "$MOCK_DIR/$cmd"
  done
  echo 'cat > /dev/null' >> "$MOCK_DIR/pbcopy"
  # The script on stdin isn't needed; print the outcome the test asks for.
  printf 'cat > /dev/null\necho "${OSASCRIPT_RESULT:-ok}"\n' >> "$MOCK_DIR/osascript"
}

teardown() {
  rm -rf "$CQ_DIR" "$REPO" "$MOCK_DIR"
}

# state <id> <status> <seconds ago> [extra jq]
state() {
  jq -n --arg id "$1" --arg status "$2" --arg cwd "$REPO" \
    --argjson at "$((NOW - $3))" \
    "{session_id: \$id, status: \$status, cwd: \$cwd, updated_at: \$at, entrypoint: \"sdk-ts\", title: \"title \" + \$id} | ${4:-.}" \
    > "$CQ_DIR/$1.json"
}

@test "says so when nothing is waiting" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "Nothing waiting for you." ]
}

@test "lists needs-input, then idle, then working, oldest first, and hides new" {
  state busy working 5
  state idle-old idle 600
  state needs-new needs-input 10
  state needs-old needs-input 300
  state fresh new 5
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ids="$(grep -o '\[zed [a-z-]*' <<<"$output" | cut -d' ' -f2)"
  [ "$ids" = "$(printf 'needs-ol\nneeds-ne\nidle-old\nbusy')" ]
}

@test "-a also lists new and snoozed sessions" {
  state fresh new 5
  state sleepy idle 5 ".snoozed_until = $((NOW + 3600))"
  run bash "$SCRIPT"
  [ "$output" = "Nothing waiting for you." ]
  run bash "$SCRIPT" -a
  [[ "$output" == *fresh* ]]
  [[ "$output" == *sleepy* ]]
}

@test "--swiftbar shows working sessions in blue, without counting them" {
  state busy working 5
  run bash "$SCRIPT" --swiftbar
  [ "${lines[0]}" = "✓" ]
  [[ "$output" == *"🔵 "*"| bash="*"param1=open param2=busy"* ]]
}

@test "keeps empty fields in their columns" {
  state s1 idle 5 '.title = "" | .branch = ""'
  run bash "$SCRIPT"
  [[ "$output" == *"[zed s1]"* ]]
}

@test "open focuses the Zed window for a Zed session, by row number" {
  state s1 needs-input 5
  run bash "$SCRIPT" open 1
  [ "$status" -eq 0 ]
  grep -q "^osascript - $(basename "$REPO")$" "$MOCK_DIR/calls"
  # The zed CLI opens a new window rather than switching to the open one.
  ! grep -q "^zed" "$MOCK_DIR/calls"
}

@test "open says so when no Zed window has the folder open" {
  state s1 needs-input 5
  OSASCRIPT_RESULT=no-window run bash "$SCRIPT" open s1
  [ "$status" -eq 1 ]
  [[ "$output" == *"No Zed window is open on"* ]]
  grep -q "^terminal-notifier" "$MOCK_DIR/calls"
}

@test "open explains the missing Accessibility permission" {
  state s1 needs-input 5
  OSASCRIPT_RESULT="execution error: osascript is not allowed assistive access. (-1728)" \
    run bash "$SCRIPT" open s1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Accessibility permission"* ]]
}

@test "open copies the resume command for a CLI session outside tmux" {
  state abc123 idle 5 '.entrypoint = "cli" | .term_program = "ghostty"'
  run bash "$SCRIPT" open abc
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude --resume abc123"* ]]
  grep -q "^pbcopy" "$MOCK_DIR/calls"
}

@test "open fails when the directory has gone" {
  state s1 idle 5 '.cwd = "/nonexistent/dir"'
  run bash "$SCRIPT" open s1
  [ "$status" -eq 1 ]
}

@test "snooze hides a session" {
  state s1 idle 5
  run bash "$SCRIPT" snooze s1 30m
  [ "$status" -eq 0 ]
  run bash "$SCRIPT"
  [ "$output" = "Nothing waiting for you." ]
}

@test "snooze rejects a duration it can't read" {
  state s1 idle 5
  run bash "$SCRIPT" snooze s1 soon
  [ "$status" -eq 1 ]
}

@test "dismiss removes the session" {
  state s1 idle 5
  run bash "$SCRIPT" dismiss s1
  [ "$status" -eq 0 ]
  [ ! -f "$CQ_DIR/s1.json" ]
}

@test "an ambiguous ID prefix fails" {
  state abc1 idle 5
  state abc2 idle 5
  run bash "$SCRIPT" dismiss abc
  [ "$status" -eq 1 ]
}

@test "prune removes gone, stale and stuck sessions, and keeps the rest" {
  state fresh idle 60
  state gone idle 60 '.cwd = "/nonexistent/dir"'
  state stale idle $((4 * 86400))
  state stuck working $((2 * 86400))
  run bash "$SCRIPT" prune
  [ "$status" -eq 0 ]
  [ -f "$CQ_DIR/fresh.json" ]
  [ ! -f "$CQ_DIR/gone.json" ]
  [ ! -f "$CQ_DIR/stale.json" ]
  [ ! -f "$CQ_DIR/stuck.json" ]
}

@test "--swiftbar shows the counts and a menu entry per session" {
  state s1 needs-input 5 '.message = "Needs | permission"'
  state s2 idle 5
  run bash "$SCRIPT" --swiftbar
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "🟠 1 ⚪ 1" ]
  [[ "$output" == *"🟠 "*" · title s1 | bash="*"param1=open param2=s1"*'tooltip="Needs  permission. Option-click to dismiss"'* ]]
  [[ "$output" == *"✕ Dismiss: "*"title s2 | bash="*"param1=dismiss param2=s2"*"alternate=true"* ]]
  [[ "$output" != *"param1=snooze"* ]]
  [[ "$output" != *"length="* ]]
}

@test "--swiftbar gives session lines an action, not a submenu" {
  # SwiftBar drops the submenu of an item whose text changes between runs.
  state s1 idle 5
  run bash "$SCRIPT" --swiftbar
  session_line="$(grep -n '^⚪ .*param1=open' <<<"$output" | cut -d: -f1)"
  [ -n "$session_line" ]
  next="$(sed -n "$((session_line + 1))p" <<<"$output")"
  [[ "$next" == "---" || "$next" != --* ]]
}

@test "--swiftbar shows a tick when nothing is waiting" {
  run bash "$SCRIPT" --swiftbar
  [ "${lines[0]}" = "✓" ]
}

@test "drops sessions whose Claude process has exited" {
  sleep 30 &
  pid=$!
  started="$(ps -o lstart= -p "$pid" | sed -e 's/^ *//' -e 's/ *$//')"
  state alive idle 5 ".pid = $$ | .pid_started = \"$(ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')\""
  state dead idle 5 ".pid = $pid | .pid_started = \"$started\""
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$CQ_DIR/alive.json" ]
  [ ! -f "$CQ_DIR/dead.json" ]
}

@test "drops a session whose PID now belongs to a different process" {
  state reused idle 5 ".pid = $$ | .pid_started = \"Thu Jan  1 00:00:00 1970\""
  run bash "$SCRIPT"
  [ ! -f "$CQ_DIR/reused.json" ]
}

@test "keeps sessions with no recorded process" {
  state old idle 5
  run bash "$SCRIPT"
  [ -f "$CQ_DIR/old.json" ]
}

@test "--swiftbar shortens long titles itself" {
  state s1 idle 5 ".title = \"$(printf 'x%.0s' {1..120})\""
  run bash "$SCRIPT" --swiftbar
  line="$(grep '^⚪' <<<"$output")"
  [[ "$line" == *"… | bash="* ]]
  [[ "$line" != *"$(printf 'x%.0s' {1..80})"* ]]
}

@test "prune removes sessions that were never prompted after a day" {
  state unprompted new $((2 * 86400))
  run bash "$SCRIPT" prune
  [ ! -f "$CQ_DIR/unprompted.json" ]
}
