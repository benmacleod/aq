#!/usr/bin/env bats

HOOK="$BATS_TEST_DIRNAME/../bin/aq-codex-hook"

setup() {
  export AQ_STATE_DIR="$(mktemp -d)"
  export AQ_SUMMARIZE=0
  export REPO="$(mktemp -d)"
  STATE="$AQ_STATE_DIR/s1.json"
}

teardown() {
  rm -rf "$AQ_STATE_DIR" "$REPO"
}

hook() {
  printf '%s' "$1" | /bin/bash "$HOOK"
}

field() {
  jq -r ".$1" "$STATE"
}

@test "SessionStart records a new Codex session" {
  hook "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"cwd\":\"$REPO\",\"source\":\"startup\"}"
  [ "$(field status)" = "new" ]
  [ "$(field agent)" = "codex" ]
  [ "$(field cwd)" = "$REPO" ]
}

@test "UserPromptSubmit marks the session working, titled with the prompt" {
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","turn_id":"t1","prompt":"Fix the footer"}'
  [ "$(field status)" = "working" ]
  [ "$(field title)" = "Fix the footer" ]
}

@test "PermissionRequest marks the session as needing input, with the command" {
  hook '{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"make clean","description":null}}'
  [ "$(field status)" = "needs-input" ]
  [ "$(field message)" = "Approve Bash: make clean" ]
}

@test "PermissionRequest without a command names the tool" {
  hook '{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"apply_patch","tool_input":{}}'
  [ "$(field message)" = "Approve apply_patch" ]
}

@test "PostToolUse after a permission request marks the session working again" {
  hook '{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"shell"}'
  hook '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"shell"}'
  [ "$(field status)" = "working" ]
  [ "$(field message)" = "null" ]
}

@test "Stop and Interrupt mark the session idle" {
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi"}'
  hook '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done"}'
  [ "$(field status)" = "idle" ]
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi"}'
  hook '{"hook_event_name":"Interrupt","session_id":"s1"}'
  [ "$(field status)" = "idle" ]
}

@test "SessionEnd removes the state" {
  hook '{"hook_event_name":"Stop","session_id":"s1"}'
  hook '{"hook_event_name":"SessionEnd","session_id":"s1","reason":"archived"}'
  [ ! -f "$STATE" ]
}

@test "prints nothing and exits 0, even on input it can't parse" {
  run hook 'not json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run hook '{"hook_event_name":"Stop","session_id":"s1"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
