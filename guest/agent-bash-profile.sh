#!/usr/bin/env bash
# ~agent/.bash_profile — runs on `box enter`. Ensures services are up, then
# drops you into a persistent tmux session so work survives disconnects.
[ -f /etc/profile ] && . /etc/profile
cd "$HOME/workspace" 2>/dev/null || cd "$HOME" || exit

# Start Executor and repair MCP wiring when its configuration version changes.
hb up >/dev/null 2>&1 || true
hb wire-once >/dev/null 2>&1 || true
if [ -r "$XDG_CONFIG_HOME/hermes-box/executor-mcp.env" ]; then
  # shellcheck disable=SC1091
  . "$XDG_CONFIG_HOME/hermes-box/executor-mcp.env"
fi

# smolvm's exec channel does not forward the client's TERM, so login shells
# arrive with TERM=dumb (or unset) and tmux refuses to attach: "open terminal
# failed: terminal does not support clear". Any real client that reaches this
# profile can render xterm-256color, so substitute it for the degenerate case.
case "${TERM:-}" in "" | dumb) export TERM=xterm-256color ;; esac

# Attach (or create) the persistent 'main' session — skip if already inside tmux.
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  exec tmux -f /opt/hermes-box/tmux.conf new-session -A -s main
fi
