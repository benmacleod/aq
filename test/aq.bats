#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../bin/aq"

setup() {
  export AQ_STATE_DIR="$(mktemp -d)"
  export REPO="$(mktemp -d)"
  export MOCK_DIR="$(mktemp -d)"
  export AQ_CONFIG_DIR="$(mktemp -d)"
  export PATH="$MOCK_DIR:$PATH"
  NOW="$(date +%s)"

  for cmd in zed tmux open osascript terminal-notifier ps; do
    cat > "$MOCK_DIR/$cmd" << EOF
#!/usr/bin/env bash
echo "$cmd \$*" >> "$MOCK_DIR/calls"
EOF
    chmod +x "$MOCK_DIR/$cmd"
  done
  # The script on stdin isn't needed; print the outcome the test asks for.
  printf 'cat > /dev/null\necho "${OSASCRIPT_RESULT:-ok}"\n' >> "$MOCK_DIR/osascript"
  # tmux reports the panes and attached terminals in $TMUX_PANES and
  # $TMUX_CLIENTS, as tab-separated lines.
  cat >> "$MOCK_DIR/tmux" << 'EOF'
case "$1" in
  list-panes) printf '%b' "${TMUX_PANES:-}" ;;
  list-clients) printf '%b' "${TMUX_CLIENTS:-}" ;;
esac
EOF
  # ps -E reports $PS_BUNDLE as a process's app. Anything else is real ps.
  cat >> "$MOCK_DIR/ps" << 'EOF'
if [ "$1" = "-E" ]; then
  echo "tmux attach __CFBundleIdentifier=${PS_BUNDLE:-org.tabby}"
else
  exec /bin/ps "$@"
fi
EOF
}

teardown() {
  rm -rf "$AQ_STATE_DIR" "$REPO" "$MOCK_DIR" "$AQ_CONFIG_DIR"
}

# state <id> <status> <seconds ago> [extra jq]
state() {
  jq -n --arg id "$1" --arg status "$2" --arg cwd "$REPO" \
    --argjson at "$((NOW - $3))" \
    "{session_id: \$id, status: \$status, cwd: \$cwd, updated_at: \$at, app: \"dev.zed.Zed\", title: \"title \" + \$id} | ${4:-.}" \
    > "$AQ_STATE_DIR/$1.json"
}

@test "says so when nothing is waiting" {
  run /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "Nothing waiting for you." ]
}

@test "lists needs-input, then idle, then working, oldest first, and hides new" {
  state busy working 5
  state idle-old idle 600
  state needs-new needs-input 10
  state needs-old needs-input 300
  state fresh new 5
  run /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ids="$(grep -o 'Zed [a-z-]*' <<<"$output" | cut -d' ' -f2)"
  [ "$ids" = "$(printf 'needs-ol\nneeds-ne\nidle-old\nbusy')" ]
}

@test "-a also lists new and snoozed sessions" {
  state fresh new 5
  state sleepy idle 5 ".snoozed_until = $((NOW + 3600))"
  run /bin/bash "$SCRIPT"
  [ "$output" = "Nothing waiting for you." ]
  run /bin/bash "$SCRIPT" -a
  [[ "$output" == *fresh* ]]
  [[ "$output" == *sleepy* ]]
}

@test "--swiftbar shows working sessions in blue, without counting them" {
  state busy working 5
  run /bin/bash "$SCRIPT" --swiftbar
  [ "${lines[0]}" = "✓" ]
  [[ "$output" == *"🔵 "*"| bash="*"param1=open param2=busy"* ]]
}

@test "keeps empty fields in their columns" {
  state s1 idle 5 '.title = "" | .branch = ""'
  run /bin/bash "$SCRIPT"
  [[ "$output" == *"[Claude in Zed s1]"* ]]
}

@test "open focuses the Zed window for a Zed session, by row number" {
  state s1 needs-input 5
  run /bin/bash "$SCRIPT" open 1
  [ "$status" -eq 0 ]
  grep -q "^osascript - $(basename "$REPO")$" "$MOCK_DIR/calls"
  # The zed CLI opens a new window rather than switching to the open one.
  ! grep -q "^zed" "$MOCK_DIR/calls"
}

@test "open says so when no Zed window has the folder open" {
  state s1 needs-input 5
  OSASCRIPT_RESULT=no-window run /bin/bash "$SCRIPT" open s1
  [ "$status" -eq 1 ]
  [[ "$output" == *"No Zed window is open on"* ]]
  grep -q "^terminal-notifier" "$MOCK_DIR/calls"
}

@test "open explains the missing Accessibility permission" {
  state s1 needs-input 5
  OSASCRIPT_RESULT="execution error: osascript is not allowed assistive access. (-1728)" \
    run /bin/bash "$SCRIPT" open s1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Accessibility permission"* ]]
}

@test "open brings a terminal session's app forward and says which tab it's in" {
  state abc123 idle 5 'del(.app) | .term_program = "Tabby" | .app = "org.tabby" | .tty = "ttys008"'
  run /bin/bash "$SCRIPT" open abc
  [ "$status" -eq 0 ]
  grep -q "^open -b org.tabby$" "$MOCK_DIR/calls"
  [[ "$output" == *"is in Tabby (ttys008). Switch to its tab."* ]]
  grep -q "^terminal-notifier" "$MOCK_DIR/calls"
  # Resuming a live session would start a second Claude on it.
  ! grep -q "^pbcopy" "$MOCK_DIR/calls"
}

@test "open brings forward a terminal recorded without a bundle ID by name" {
  state abc123 idle 5 'del(.app) | .term_program = "ghostty"'
  run /bin/bash "$SCRIPT" open abc
  grep -q "^open -a ghostty$" "$MOCK_DIR/calls"
}

@test "open switches the terminal showing a session's tmux session, and brings it forward" {
  # The hook recorded Zed, but tmux session 4 is showing in Tabby: tmux's
  # environment comes from whichever app started the tmux server.
  state abc123 idle 5 'del(.app) | .app = "dev.zed.Zed" | .tmux_pane = "%3"'
  export TMUX_PANES='%3\t4\n' TMUX_CLIENTS='4\t100\t/dev/ttys008\t555\n' PS_BUNDLE=org.tabby
  run /bin/bash "$SCRIPT" open abc
  [ "$status" -eq 0 ]
  grep -q "^tmux switch-client -c /dev/ttys008 -t %3$" "$MOCK_DIR/calls"
  grep -q "^tmux select-pane -t %3$" "$MOCK_DIR/calls"
  grep -q "^open -b org.tabby$" "$MOCK_DIR/calls"
  ! grep -q "^terminal-notifier" "$MOCK_DIR/calls"
  ! grep -q "^osascript" "$MOCK_DIR/calls"
}

@test "a tmux session uses the terminal most recently active on it" {
  state abc123 idle 5 'del(.app) | .tmux_pane = "%3"'
  export TMUX_PANES='%3\t4\n' TMUX_CLIENTS='4\t100\t/dev/ttys008\t555\n4\t200\t/dev/ttys013\t556\n'
  run /bin/bash "$SCRIPT" open abc
  grep -q "^tmux switch-client -c /dev/ttys013 -t %3$" "$MOCK_DIR/calls"
}

@test "shows the app of the terminal showing a session's tmux session" {
  state abc123 idle 5 'del(.app) | .app = "dev.zed.Zed" | .tmux_pane = "%3"'
  export TMUX_PANES='%3\t4\n' TMUX_CLIENTS='4\t100\t/dev/ttys008\t555\n' PS_BUNDLE=org.tabby
  run /bin/bash "$SCRIPT" --swiftbar
  [[ "$output" == *"🐈⚪ "*'tooltip="Claude, running in tmux session 4, in Tabby.'* ]]
}

@test "open says so when no terminal is showing a session's tmux session" {
  state abc123 idle 5 'del(.app) | .tmux_pane = "%3"'
  export TMUX_PANES='%3\t4\n'
  run /bin/bash "$SCRIPT" --swiftbar
  [[ "$output" == *"💻⚪ "*'tooltip="Claude, running in tmux session 4, which no terminal is showing.'* ]]
  run /bin/bash "$SCRIPT" open abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"Run: tmux attach -t 4"* ]]
  ! grep -q "^tmux switch-client" "$MOCK_DIR/calls"
}

@test "config.json overrides and adds apps" {
  cat > "$AQ_CONFIG_DIR/config.json" << 'EOF'
{"apps": {"org.tabby": {"emoji": "🐱"}, "com.mitchellh.ghostty": {"name": "Ghostty", "emoji": "👻"}}}
EOF
  state tabby idle 5 'del(.app) | .app = "org.tabby"'
  state ghostty idle 5 'del(.app) | .app = "com.mitchellh.ghostty"'
  run /bin/bash "$SCRIPT" --swiftbar
  [[ "$output" == *"🐱⚪ "*'param2=tabby '*'running in Tabby.'* ]]
  [[ "$output" == *"👻⚪ "*'param2=ghostty '*'running in Ghostty.'* ]]
}

@test "a config.json that isn't valid JSON is ignored, with a notification" {
  echo '{not json' > "$AQ_CONFIG_DIR/config.json"
  state tabby idle 5 'del(.app) | .app = "org.tabby"'
  run /bin/bash "$SCRIPT" --swiftbar
  [ "$status" -eq 0 ]
  [[ "$output" == *"🐈⚪ "* ]]
  grep -q "^terminal-notifier.*Ignoring" "$MOCK_DIR/calls"
}

@test "shows the emoji config.json gives the session's repo" {
  echo '{"repos": {"tc": "📰"}}' > "$AQ_CONFIG_DIR/config.json"
  state news idle 5 '.repo = "tc"'
  state other idle 5 '.repo = "other"'
  run /bin/bash "$SCRIPT" --swiftbar
  [[ "$output" == *"📰⚡⚪ "*"param2=news "* ]]
  [[ "$output" == *$'\n⚡⚪ '*"param2=other "* ]]
  run /bin/bash "$SCRIPT"
  [[ "$output" == *"📰 $(basename "$REPO")"* ]]
}

@test "shows each session's agent" {
  state claude idle 5 '.agent = "claude"'
  state codex idle 5 '.agent = "codex"'
  state other idle 5 '.agent = "other-agent"'
  run /bin/bash "$SCRIPT" --swiftbar
  [[ "$output" == *$'\n⚡⚪ '*"param2=claude "*'tooltip="Claude, running in Zed.'* ]]
  [[ "$output" == *"⚡🤖⚪ "*"param2=codex "*'tooltip="Codex, running in Zed.'* ]]
  [[ "$output" == *$'\n⚡⚪ '*"param2=other "*'tooltip="other-agent, running in Zed.'* ]]
  run /bin/bash "$SCRIPT"
  [[ "$output" == *"[Codex in Zed codex]"* ]]
}

@test "shows only the last part of the session's directory" {
  mkdir -p "$REPO/worktrees/tc-123"
  state s1 idle 5 ".cwd = \"$REPO/worktrees/tc-123\""
  run /bin/bash "$SCRIPT" --swiftbar
  [[ "$output" == *"⚪ tc-123 · "* ]]
  [[ "$output" != *"worktrees/"* ]]
}

@test "open runs your own opener for an app, with the session's details" {
  mkdir -p "$AQ_CONFIG_DIR/openers"
  cat > "$AQ_CONFIG_DIR/openers/my-opener" << EOF
#!/usr/bin/env bash
env | grep '^AQ_' | sort > "$MOCK_DIR/opener_env"
echo "Opened it"
EOF
  chmod +x "$AQ_CONFIG_DIR/openers/my-opener"
  echo '{"apps": {"org.tabby": {"open": "my-opener"}}}' > "$AQ_CONFIG_DIR/config.json"
  state abc123 idle 5 'del(.app) | .app = "org.tabby" | .tty = "ttys008"'
  run /bin/bash "$SCRIPT" open abc
  [ "$status" -eq 0 ]
  grep -q "^AQ_SESSION_ID=abc123$" "$MOCK_DIR/opener_env"
  grep -q "^AQ_CWD=$REPO$" "$MOCK_DIR/opener_env"
  grep -q "^AQ_APP=org.tabby$" "$MOCK_DIR/opener_env"
  grep -q "^AQ_APP_NAME=Tabby$" "$MOCK_DIR/opener_env"
  grep -q "^AQ_TTY=ttys008$" "$MOCK_DIR/opener_env"
  grep -q "^terminal-notifier.*Opened it" "$MOCK_DIR/calls"
}

@test "an opener's exit status is open's" {
  mkdir -p "$AQ_CONFIG_DIR/openers"
  printf '#!/usr/bin/env bash\necho "Nope"\nexit 3\n' > "$AQ_CONFIG_DIR/openers/failing"
  chmod +x "$AQ_CONFIG_DIR/openers/failing"
  echo '{"apps": {"org.tabby": {"open": "failing"}}}' > "$AQ_CONFIG_DIR/config.json"
  state abc123 idle 5 'del(.app) | .app = "org.tabby"'
  run /bin/bash "$SCRIPT" open abc
  [ "$status" -eq 3 ]
  [[ "$output" == *"Nope"* ]]
}

@test "open says so when an app's opener doesn't exist" {
  echo '{"apps": {"org.tabby": {"open": "missing"}}}' > "$AQ_CONFIG_DIR/config.json"
  state abc123 idle 5 'del(.app) | .app = "org.tabby"'
  run /bin/bash "$SCRIPT" open abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"no aq opener called missing"* ]]
}

@test "shows each session's app" {
  state zed idle 5
  state tabby idle 5 'del(.app) | .app = "org.tabby"'
  state tabby-old idle 5 'del(.app) | .term_program = "Tabby"'
  state other idle 5 'del(.app) | .app = "com.mitchellh.ghostty" | .term_program = "ghostty"'
  run /bin/bash "$SCRIPT" --swiftbar
  [[ "$output" == *"⚡⚪ "*"param2=zed "* ]]
  [[ "$output" == *"🐈⚪ "*"param2=tabby "* ]]
  [[ "$output" == *"🐈⚪ "*"param2=tabby-old "* ]]
  [[ "$output" == *"💻⚪ "*"param2=other "*'tooltip="Claude, running in ghostty.'* ]]
  run /bin/bash "$SCRIPT"
  [[ "$output" == *"[Claude in Tabby tabby]"* ]]
  [[ "$output" == *"[Claude in ghostty other]"* ]]
}

@test "open fails when the directory has gone" {
  state s1 idle 5 '.cwd = "/nonexistent/dir"'
  run /bin/bash "$SCRIPT" open s1
  [ "$status" -eq 1 ]
}

@test "snooze hides a session" {
  state s1 idle 5
  run /bin/bash "$SCRIPT" snooze s1 30m
  [ "$status" -eq 0 ]
  run /bin/bash "$SCRIPT"
  [ "$output" = "Nothing waiting for you." ]
}

@test "snooze rejects a duration it can't read" {
  state s1 idle 5
  run /bin/bash "$SCRIPT" snooze s1 soon
  [ "$status" -eq 1 ]
}

@test "dismiss removes the session" {
  state s1 idle 5
  run /bin/bash "$SCRIPT" dismiss s1
  [ "$status" -eq 0 ]
  [ ! -f "$AQ_STATE_DIR/s1.json" ]
}

@test "an ambiguous ID prefix fails" {
  state abc1 idle 5
  state abc2 idle 5
  run /bin/bash "$SCRIPT" dismiss abc
  [ "$status" -eq 1 ]
}

@test "prune removes gone, stale and stuck sessions, and keeps the rest" {
  state fresh idle 60
  state gone idle 60 '.cwd = "/nonexistent/dir"'
  state stale idle $((4 * 86400))
  state stuck working $((2 * 86400))
  run /bin/bash "$SCRIPT" prune
  [ "$status" -eq 0 ]
  [ -f "$AQ_STATE_DIR/fresh.json" ]
  [ ! -f "$AQ_STATE_DIR/gone.json" ]
  [ ! -f "$AQ_STATE_DIR/stale.json" ]
  [ ! -f "$AQ_STATE_DIR/stuck.json" ]
}

@test "--swiftbar shows the counts and a menu entry per session" {
  state s1 needs-input 5 '.message = "Needs | permission"'
  state s2 idle 5
  run /bin/bash "$SCRIPT" --swiftbar
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "🟠 1 ⚪ 1" ]
  [[ "$output" == *"🟠 "*" · title s1 | bash="*"param1=open param2=s1"*'tooltip="Needs  permission. Claude, running in Zed. Option-click to dismiss"'* ]]
  [[ "$output" == *"✕ Dismiss: "*"title s2 | bash="*"param1=dismiss param2=s2"*"alternate=true"* ]]
  [[ "$output" != *"param1=snooze"* ]]
  [[ "$output" != *"length="* ]]
}

@test "--swiftbar gives session lines an action, not a submenu" {
  # SwiftBar drops the submenu of an item whose text changes between runs.
  state s1 idle 5
  run /bin/bash "$SCRIPT" --swiftbar
  session_line="$(grep -n '⚪ .*param1=open' <<<"$output" | cut -d: -f1)"
  [ -n "$session_line" ]
  next="$(sed -n "$((session_line + 1))p" <<<"$output")"
  [[ "$next" == "---" || "$next" != --* ]]
}

@test "--swiftbar shows a tick when nothing is waiting" {
  run /bin/bash "$SCRIPT" --swiftbar
  [ "${lines[0]}" = "✓" ]
}

@test "drops sessions whose agent process has exited" {
  sleep 30 &
  pid=$!
  started="$(ps -o lstart= -p "$pid" | sed -e 's/^ *//' -e 's/ *$//')"
  state alive idle 5 ".pid = $$ | .pid_started = \"$(ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')\""
  state dead idle 5 ".pid = $pid | .pid_started = \"$started\""
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  run /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$AQ_STATE_DIR/alive.json" ]
  [ ! -f "$AQ_STATE_DIR/dead.json" ]
}

@test "drops a session whose PID now belongs to a different process" {
  state reused idle 5 ".pid = $$ | .pid_started = \"Thu Jan  1 00:00:00 1970\""
  run /bin/bash "$SCRIPT"
  [ ! -f "$AQ_STATE_DIR/reused.json" ]
}

@test "keeps sessions with no recorded process" {
  state old idle 5
  run /bin/bash "$SCRIPT"
  [ -f "$AQ_STATE_DIR/old.json" ]
}

@test "--swiftbar shortens long titles itself" {
  state s1 idle 5 ".title = \"$(printf 'x%.0s' {1..120})\""
  run /bin/bash "$SCRIPT" --swiftbar
  line="$(grep 'param1=open' <<<"$output")"
  [[ "$line" == *"… | bash="* ]]
  [[ "$line" != *"$(printf 'x%.0s' {1..80})"* ]]
}

@test "prune removes sessions that were never prompted after a day" {
  state unprompted new $((2 * 86400))
  run /bin/bash "$SCRIPT" prune
  [ ! -f "$AQ_STATE_DIR/unprompted.json" ]
}
