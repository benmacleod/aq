#!/usr/bin/env bats

RECORD="$BATS_TEST_DIRNAME/../bin/aq-record"

setup() {
  export AQ_STATE_DIR="$(mktemp -d)"
  export AQ_SUMMARIZE=0
}

teardown() {
  rm -rf "$AQ_STATE_DIR"
}

@test "records a session for any agent" {
  run /bin/bash "$RECORD" --agent my-agent --session s1 --cwd /tmp prompt "Do the thing"
  [ "$status" -eq 0 ]
  [ "$(jq -r .agent "$AQ_STATE_DIR/s1.json")" = "my-agent" ]
  [ "$(jq -r .status "$AQ_STATE_DIR/s1.json")" = "working" ]
  [ "$(jq -r .title "$AQ_STATE_DIR/s1.json")" = "Do the thing" ]
}

@test "records the PID it is given" {
  /bin/bash "$RECORD" --agent my-agent --session s1 --pid $$ idle
  [ "$(jq -r .pid "$AQ_STATE_DIR/s1.json")" = "$$" ]
}

@test "explains its usage when an argument is missing" {
  run /bin/bash "$RECORD" --session s1 idle
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: aq-record --agent"* ]]
  [ ! -f "$AQ_STATE_DIR/s1.json" ]
}

@test "rejects events it doesn't know" {
  run /bin/bash "$RECORD" --agent a --session s1 dancing
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown event dancing"* ]]
}
