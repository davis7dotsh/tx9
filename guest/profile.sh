#!/usr/bin/env bash
# /etc/profile.d/hermes-box.sh — environment for every shell in the box.
# shellcheck disable=SC1091
[ -r /etc/hermes-box.env ] && . /etc/hermes-box.env

HB=/opt/hermes-box
# Vite+ manages node/npm (LTS by default) and hosts vp-installed globals
# like executor; its shims resolve the managed runtime via VP_HOME.
export VP_HOME="$HB/tooling/vite-plus"
# /data/home/agent/.local/bin first: self-updates run in the box (claude
# update, re-running the codex installer) land launchers there on the durable
# volume, and must win over the image-baked copies in $HB/bin.
export PATH="/data/home/agent/.local/bin:$HB/bin:$VP_HOME/bin:$HB/tooling/uv:$PATH"

# neovim is the default editor; its config/state (~/.config/nvim, ~/.local/share/nvim)
# lands on /data via the XDG vars below.
export EDITOR=nvim
export VISUAL=nvim

# All durable state lives under /data so it travels with the box.
export HOME="${HOME:-/data/home/agent}"
export HERMES_BOX_DATA=/data
export CLAUDE_CONFIG_DIR=/data/home/agent/.claude
export CODEX_HOME=/data/home/agent/.codex
export HERMES_HOME=/data/home/agent/.hermes   # hermes auth/sessions/skills/memory
# executor stores under $HOME (XDG) — already on /data via HOME above.
export XDG_CONFIG_HOME=/data/home/agent/.config
export XDG_DATA_HOME=/data/home/agent/.local/share
export XDG_STATE_HOME=/data/home/agent/.local/state

# `codex update` detects a standalone install by looking for the running
# binary under $CODEX_HOME/packages/standalone — but at runtime CODEX_HOME
# points at /data (config/auth), while the release binaries live in the
# image's tooling dir. Point just the updater at the install home; every
# other invocation keeps the durable CODEX_HOME.
codex() {
  if [ "${1:-}" = "update" ]; then
    CODEX_HOME=/opt/hermes-box/tooling/codex command codex "$@"
  else
    command codex "$@"
  fi
}

# Codex reads Executor's local bearer token from this environment variable.
# The root-owned service mints the token; hb refreshes this mode-0600 file when
# it wires MCP clients.
EXECUTOR_MCP_ENV="$XDG_CONFIG_HOME/hermes-box/executor-mcp.env"
# shellcheck disable=SC1090
[ -r "$EXECUTOR_MCP_ENV" ] && . "$EXECUTOR_MCP_ENV"
