#!/usr/bin/env bash
# <xbar.title>Claude attention queue</xbar.title>
# <xbar.desc>Claude sessions waiting for you, from cq.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>

# SwiftBar's Show Error doesn't always show anything, so keep a log.
exec "$HOME/.claude/bin/cq" --swiftbar 2>>"$HOME/.claude/attention/swiftbar-errors.log"
