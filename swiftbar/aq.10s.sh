#!/usr/bin/env bash
# <xbar.title>Agent queue</xbar.title>
# <xbar.desc>Coding agent sessions waiting for you, from aq.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>

# This file is a link into the aq repo; run the aq next to it.
dir="$(dirname "$(readlink -f "$0")")"
state="${XDG_STATE_HOME:-$HOME/.local/state}/aq"
mkdir -p "$state"

# SwiftBar's Show Error doesn't always show anything, so keep a log.
exec "$dir/../bin/aq" --swiftbar 2>>"$state/swiftbar-errors.log"
