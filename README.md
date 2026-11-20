# aq: agent queue

A queue of your coding agents' sessions that are waiting for you, across apps (Zed's agent panel, terminals, tmux) and agents (Claude Code, Codex).

Some apps tell you when an agent needs you, but forget once you switch to its window, whether or not you replied. In aq, a session stays flagged until you actually send it a prompt. A menu bar list shows what's waiting, and clicking a session takes you to it.

macOS only: aq finds apps by their bundle IDs, and switches windows through System Events.

## How it works

Each agent runs a hook on its lifecycle events: a session starts, you send a prompt, it asks for permission, it finishes its turn. An adapter per agent (`aq-claude-hook`, `aq-codex-hook`) turns those events into calls to `aq-record`, which keeps one JSON file per session in `~/.local/state/aq/` (or `$XDG_STATE_HOME/aq/`). `aq` reads those files.

## Install

```sh
make install
```

This installs the Homebrew dependencies, links `bin/*` into `~/.local/bin`, and links the SwiftBar plugin into SwiftBar's plugin folder, once you've chosen one in SwiftBar. Then hook up your agents.

### Claude Code

Add this to `~/.claude/settings.json`:

```json
"hooks": {
  "SessionStart":     [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-claude-hook" }] }],
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-claude-hook" }] }],
  "Notification":     [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-claude-hook" }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-claude-hook" }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-claude-hook" }] }],
  "PreToolUse":       [{ "matcher": "AskUserQuestion|ExitPlanMode", "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-claude-hook" }] }],
  "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-claude-hook" }] }]
}
```

This works for Claude in a terminal and in Zed's agent panel.

### Codex

Add this to `~/.codex/hooks.json`, then run `/hooks` in Codex to review and trust the hooks: Codex doesn't run hooks you haven't trusted.

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-codex-hook" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-codex-hook" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-codex-hook" }] }],
    "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-codex-hook" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-codex-hook" }] }],
    "Interrupt":         [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-codex-hook" }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "$HOME/.local/bin/aq-codex-hook" }] }]
  }
}
```

The Codex desktop app runs many sessions in one process, so its sessions don't drop off the list when one closes, only when Codex ends them or you prune them.

### Other agents

Write an adapter that calls `aq-record` from the agent's hooks. Run `aq-record --help` for its events and options. It finds the agent's process from its own ancestors, by the agent's name (pass `--pid` if that doesn't work), so aq can drop the session once the process has gone.

## Usage

**`aq`** lists your sessions. Sessions that need input (a permission prompt, a question, a plan to approve) come first, then idle ones, then working ones, oldest first.

```
aq                 # list sessions, the ones waiting for you first (-a: include snoozed and unprompted ones)
aq open 1          # switch to row 1's window, tab or tmux pane
aq snooze 1 2h     # hide row 1 for two hours
aq dismiss 1       # take row 1 off the list until you next prompt it
aq prune           # also remove sessions untouched for 3+ days
```

A session's title is its latest prompt. For prompts over 50 characters, if the `claude` CLI is installed, a background `claude -p --model haiku` call replaces it with a short summary a few seconds later. Set `AQ_SUMMARIZE=0` to turn that off.

**The SwiftBar plugin** (`swiftbar/aq.10s.sh`) shows the list in the menu bar: 🟠 for sessions that need input, ⚪ for idle ones, 🔵 for ones that are working. The count in the menu bar only includes the ones waiting for you. Before the dot, each session shows emoji for its repo (if you've given it one), its app (⚡ Zed, 🐈 Tabby, 💻 any other terminal) and its agent (🤖 Codex; Claude has none). Click a session to switch to it, or Option-click to dismiss it. Hover over a session to see its waiting message.

`aq open` switches to a session in one of two ways:

- **In tmux:** it switches the terminal showing the session's tmux session (the one most recently active, if there's more than one) to the session's pane, and brings that terminal forward. If no terminal is showing the tmux session, it tells you how to attach to it.
- **Otherwise:** it runs the opener for the session's app. Zed's opener brings forward the Zed window for the session's folder, by its title, through System Events, so whatever runs `aq` (SwiftBar, or your terminal) needs Accessibility permission in System Settings > Privacy & Security. Other apps get the `activate` opener: it brings the app forward and tells you which tab (TTY) the session is in, since most terminals can't be told to switch tabs.

## Configuration

`aq` reads `~/.config/aq/config.json` (or `$XDG_CONFIG_HOME/aq/config.json`), if there is one, and merges it over its built-in settings. For example:

```json
{
  "apps": {
    "com.mitchellh.ghostty": {"name": "Ghostty", "emoji": "👻"},
    "com.googlecode.iterm2": {"name": "iTerm", "emoji": "🖥️", "open": "iterm-tab"}
  },
  "agents": {
    "claude": {"emoji": "✳️"}
  },
  "repos": {
    "tc": "📰",
    "aq": "🛠️"
  }
}
```

`repos` gives an emoji to show at the start of each session in that repo. A repo's name is the last part of its `origin` URL, or if it has no `origin`, the folder name of its main checkout. So every worktree of a repo shows the same emoji.

`agents` gives each agent's name and emoji, by the name its adapter passes to `aq-record --agent`.

`apps` lists apps by bundle ID. `aq-record` finds the app an agent runs in from the agent's parent processes: the first one that is in tmux, or inside an app bundle. (It can't go by the environment: a Zed you started from a terminal passes that terminal's environment on to its agents.) aq knows Zed and Tabby; any other app gets 💻 and the `activate` opener. To find an app's bundle ID: `osascript -e 'id of app "Ghostty"'`.

### Openers

The iTerm entry above uses an opener called `iterm-tab`, which you'd write yourself. An opener is an executable, looked for in `~/.config/aq/openers/` and then in `lib/aq-openers/`. It gets the session's details in these environment variables:

| Variable | Example |
|---|---|
| `AQ_SESSION_ID` | `0bf255c9-…` |
| `AQ_CWD` | `/Users/you/Code/tc` |
| `AQ_PLACE` | `tc` |
| `AQ_APP` | `org.tabby` (empty if unknown) |
| `AQ_APP_NAME` | `Tabby` |
| `AQ_TTY` | `ttys008` (empty if unknown) |

Anything it prints is shown as a notification, and its exit status is `aq open`'s, so exit non-zero if it couldn't switch to the session. See `lib/aq-openers/activate` for the simplest example.

## Testing

```sh
make test
```

The tests run the scripts with `/bin/bash`, the bash 3.2 that SwiftBar runs plugins with. They mock external commands (`claude`, `open`, `osascript`, `ps -E`, `terminal-notifier`, `tmux`, `zed`) by putting a directory of fake programs first on `$PATH`.
