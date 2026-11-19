#!/usr/bin/env bats

HOOK="$BATS_TEST_DIRNAME/../bin/cq-hook"

setup() {
  export CQ_DIR="$(mktemp -d)"
  export REPO="$(mktemp -d)"
  export MOCK_DIR="$(mktemp -d)"
  export PATH="$MOCK_DIR:$PATH"
  STATE="$CQ_DIR/s1.json"

  # A claude that records how it was called, then replies with a title
  # after $CLAUDE_DELAY seconds.
  cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "$* CQ_HOOK_DISABLED=$CQ_HOOK_DISABLED" >> "$MOCK_DIR/claude_calls"
sleep "${CLAUDE_DELAY:-0}"
echo '"Summarized title."'
EOF
  chmod +x "$MOCK_DIR/claude"
}

teardown() {
  rm -rf "$CQ_DIR" "$REPO" "$MOCK_DIR"
}

# Waits up to 5 seconds for the session's title to become $1.
wait_for_title() {
  local i
  for i in $(seq 50); do
    [ "$(field title)" = "$1" ] && return 0
    sleep 0.1
  done
  echo "title is $(field title)" >&2
  return 1
}

LONG_PROMPT="Please look into why the newsletter footer links fail the contrast check in dark mode"

hook() {
  printf '%s' "$1" | bash "$HOOK"
}

field() {
  jq -r ".$1" "$STATE"
}

@test "SessionStart records the session as new, with its entrypoint" {
  printf '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"%s"}' "$REPO" \
    | CLAUDE_CODE_ENTRYPOINT=sdk-ts bash "$HOOK"
  [ "$(field status)" = "new" ]
  [ "$(field cwd)" = "$REPO" ]
  [ "$(field entrypoint)" = "sdk-ts" ]
}

@test "prints nothing and exits 0" {
  run hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits 0 on input it can't parse" {
  run hook 'not json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a permission Notification marks the session as needing input" {
  hook '{"hook_event_name":"Notification","session_id":"s1","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
  [ "$(field status)" = "needs-input" ]
  [ "$(field message)" = "Claude needs your permission to use Bash" ]
}

@test "an idle_prompt Notification changes nothing" {
  hook '{"hook_event_name":"Stop","session_id":"s1"}'
  hook '{"hook_event_name":"Notification","session_id":"s1","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
  [ "$(field status)" = "idle" ]
}

@test "Stop marks the session idle" {
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi"}'
  hook '{"hook_event_name":"Stop","session_id":"s1"}'
  [ "$(field status)" = "idle" ]
}

@test "UserPromptSubmit clears needs-input and snooze, and titles the session with the latest prompt" {
  hook '{"hook_event_name":"Notification","session_id":"s1","notification_type":"permission_prompt","message":"m"}'
  jq '.snoozed_until = 9999999999' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Fix the\nfooter  "}'
  [ "$(field status)" = "working" ]
  [ "$(field message)" = "null" ]
  [ "$(field snoozed_until)" = "null" ]
  [ "$(field title)" = "Fix the footer" ]
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Something else"}'
  [ "$(field title)" = "Something else" ]
}

@test "short prompts aren't summarized" {
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Fix the footer"}'
  sleep 0.3
  [ ! -f "$MOCK_DIR/claude_calls" ]
}

@test "a long prompt gets a summarized title, from a Claude with no tools or settings" {
  hook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"$LONG_PROMPT\"}"
  wait_for_title "Summarized title"
  grep -q -- '--model haiku' "$MOCK_DIR/claude_calls"
  grep -q -- '--no-session-persistence' "$MOCK_DIR/claude_calls"
  grep -q -- '--tools  ' "$MOCK_DIR/claude_calls"
  grep -q 'CQ_HOOK_DISABLED=1' "$MOCK_DIR/claude_calls"
}

@test "the hook returns before the summary is ready" {
  export CLAUDE_DELAY=2
  start=$SECONDS
  hook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"$LONG_PROMPT\"}"
  [ $((SECONDS - start)) -lt 2 ]
  [ "$(field title)" != "Summarized title" ]
}

@test "a late summary doesn't replace a newer prompt's title" {
  export CLAUDE_DELAY=1
  hook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"$LONG_PROMPT\"}"
  CQ_SUMMARIZE=0 hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Newer prompt"}'
  sleep 1.5
  [ "$(field title)" = "Newer prompt" ]
}

@test "CQ_SUMMARIZE=0 turns summarizing off" {
  CQ_SUMMARIZE=0 hook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"$LONG_PROMPT\"}"
  sleep 0.3
  [ ! -f "$MOCK_DIR/claude_calls" ]
}

@test "CQ_HOOK_DISABLED=1 makes the hook do nothing" {
  CQ_HOOK_DISABLED=1 hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi"}'
  [ ! -f "$STATE" ]
}

@test "AskUserQuestion and ExitPlanMode mark the session as needing input" {
  hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"AskUserQuestion"}'
  [ "$(field status)" = "needs-input" ]
  hook '{"hook_event_name":"PreToolUse","session_id":"s2","tool_name":"ExitPlanMode"}'
  [ "$(jq -r .message "$CQ_DIR/s2.json")" = "Waiting for plan approval" ]
}

@test "other PreToolUse calls write nothing" {
  hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash"}'
  [ ! -f "$STATE" ]
}

@test "PostToolUse after a permission prompt marks the session working again" {
  hook '{"hook_event_name":"Notification","session_id":"s1","notification_type":"permission_prompt","message":"m"}'
  hook '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash"}'
  [ "$(field status)" = "working" ]
}

@test "PostToolUse leaves other states alone" {
  hook '{"hook_event_name":"Stop","session_id":"s1"}'
  hook '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash"}'
  [ "$(field status)" = "idle" ]
}

@test "Stop takes the title from the transcript when there isn't one" {
  transcript="$CQ_DIR/t.jsonl"
  echo '{"type":"user","message":{"content":[{"type":"text","text":"Resumed prompt"}]}}' > "$transcript"
  hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"transcript_path\":\"$transcript\"}"
  [ "$(field title)" = "Resumed prompt" ]
}

@test "SessionEnd removes the state" {
  hook '{"hook_event_name":"Stop","session_id":"s1"}'
  hook '{"hook_event_name":"SessionEnd","session_id":"s1"}'
  [ ! -f "$STATE" ]
}

@test "a permission Notification for AskUserQuestion keeps the plainer message" {
  hook '{"hook_event_name":"Notification","session_id":"s1","notification_type":"permission_prompt","message":"Claude needs your permission to use AskUserQuestion"}'
  [ "$(field message)" = "Asking you a question" ]
}

@test "records the PID of the nearest claude process" {
  # Run the hook under a process whose command mentions claude.
  printf '{"hook_event_name":"Stop","session_id":"s1"}' \
    | bash -c 'exec -a fake-claude bash -c "bash \"$0\"; :" ' "$HOOK"
  pid="$(field pid)"
  [ "$pid" != "null" ]
  [ -n "$(field pid_started)" ]
}
