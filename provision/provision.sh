#!/usr/bin/env bash
# Runs INSIDE the build VM. Installs the four tools under /opt/hermes-box,
# corrals all mutable state under /data, and wires up the 'agent' user.
# Safe to re-run. Pass `assets` to refresh only repository-owned guest files.
set -euo pipefail

CTX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # /tmp/ctx
source "$CTX/box.env"

OPT=/opt/hermes-box
NODE_PREFIX="$OPT/tooling/node-global"
UV_DIR="$OPT/tooling/uv"
export PATH="$NODE_PREFIX/bin:$UV_DIR:$PATH"
export DEBIAN_FRONTEND=noninteractive

log() { printf '\033[35m[provision]\033[0m %s\n' "$*"; }

base_os() {
  log "base packages"
  apt-get update -qq
  # curl+git+xz-utils are the prereqs the hermes installer needs on Linux.
  apt-get install -y -qq \
    ca-certificates curl git jq tmux xz-utils gnupg sudo \
    iproute2 less neovim util-linux ripgrep socat >/dev/null
  # Pre-install a minimal ffmpeg so the hermes installer's `command -v ffmpeg`
  # check passes and it skips pulling ffmpeg's 667MB desktop recommends tree
  # (GTK/mesa/X11) — which otherwise pushes the overlay past smolvm's 4 GiB
  # pack-export cap. TTS still works; we just skip the GUI deps.
  apt-get install -y -qq --no-install-recommends ffmpeg >/dev/null || \
    log "ffmpeg pre-install skipped (installer will handle it)"
  mkdir -p "$OPT/tooling" "$OPT/releases" "$OPT/bin"
}

make_agent() {
  log "agent user (home on /data)"
  id agent >/dev/null 2>&1 || useradd -m -s /bin/bash agent
  # Home lives on the durable /data volume so it travels with the box.
  usermod -d /data/home/agent agent
  echo 'agent ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/agent
  chmod 0440 /etc/sudoers.d/agent
}

install_node_uv() {
  log "node ${NODE_MAJOR}.x (NodeSource) + uv"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
  # Global npm installs go to our /opt prefix, not /usr — keeps tools self-contained.
  mkdir -p "$NODE_PREFIX"
  npm config set prefix "$NODE_PREFIX" --global
  log "uv -> $UV_DIR"
  curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR="$UV_DIR" UV_UNMANAGED_INSTALL="$UV_DIR" sh >/dev/null 2>&1
}

install_claude() {
  log "claude-code"
  "$NODE_PREFIX/bin/npm" install -g @anthropic-ai/claude-code >/dev/null 2>&1 \
    || npm install -g @anthropic-ai/claude-code >/dev/null
}

install_codex() {
  log "codex"
  "$NODE_PREFIX/bin/npm" install -g @openai/codex >/dev/null 2>&1 \
    || npm install -g @openai/codex >/dev/null
}

install_hermes() {
  if [[ "${INSTALL_HERMES:-0}" != "1" ]]; then
    log "hermes: INSTALL_HERMES != 1 — skipping"; return
  fi
  log "hermes (official installer, ${HERMES_INSTALL_ARGS:-})"
  # We run as root, so the installer uses the FHS layout: code -> /usr/local/lib,
  # binary -> /usr/local/bin/hermes (both baked into the golden). HERMES_HOME pins
  # the durable state (auth, sessions, skills, memory) onto /data.
  export HERMES_HOME=/data/home/agent/.hermes
  mkdir -p "$HERMES_HOME"
  # `bash -s` reads the script from stdin (the curl pipe) — do NOT redirect stdin,
  # or bash gets an empty script. Prompts in the script hit EOF on the pipe, so
  # it stays non-interactive without a redirect.
  local args=()
  read -r -a args <<<"${HERMES_INSTALL_ARGS:-}"
  if curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
       | bash -s -- "${args[@]}"; then
    log "hermes installed -> $(command -v hermes || echo '/usr/local/bin/hermes')"
  else
    log "hermes install FAILED"
    return 1
  fi
}

install_executor() {
  if [[ "${INSTALL_EXECUTOR:-0}" != "1" ]]; then
    log "executor: INSTALL_EXECUTOR != 1 — skipping"; return
  fi
  log "executor (npm global)"
  if "$NODE_PREFIX/bin/npm" install -g executor >/dev/null 2>&1 \
       || npm install -g executor >/dev/null 2>&1; then
    log "executor installed -> $("$NODE_PREFIX/bin/npm" prefix -g 2>/dev/null)/bin/executor"
  else
    log "executor install FAILED"
    return 1
  fi
}

install_config() {
  log "guest configuration"
  install -m 0644 "$CTX/box.env" /etc/hermes-box.env
}

place_assets() {
  log "profile, tmux config, hb helper"
  install -m 0644 "$CTX/guest/profile.sh"  /etc/profile.d/hermes-box.sh
  install -m 0644 "$CTX/guest/tmux.conf"    "$OPT/tmux.conf"
  install -m 0755 "$CTX/guest/hb"           "$OPT/bin/hb"
  install -m 0755 "$CTX/guest/hb-workload"  "$OPT/bin/hb-workload"
  # agent login shell auto-attaches tmux; see guest/agent-bash-profile.sh
  mkdir -p /data/home/agent
  install -m 0644 "$CTX/guest/agent-bash-profile.sh" /data/home/agent/.bash_profile
}

seed_data() {
  log "seeding /data skeleton"
  "$OPT/bin/hb" init
}

# Drop build caches so the overlay stays under smolvm's 4 GiB pack-export cap.
slim() {
  log "slimming overlay (apt/npm/uv caches)"
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/tmp/* /tmp/ctx.tgz 2>/dev/null || true
  "$NODE_PREFIX/bin/npm" cache clean --force >/dev/null 2>&1 || true
  npm cache clean --force >/dev/null 2>&1 || true
  command -v uv >/dev/null 2>&1 && uv cache clean >/dev/null 2>&1 || true
  rm -rf /root/.npm /root/.cache /data/home/agent/.cache 2>/dev/null || true
}

verify_required() {
  log "verifying required tools"
  local cmd
  for cmd in node uv nvim claude codex; do
    command -v "$cmd" >/dev/null 2>&1 || { log "missing required tool: $cmd"; return 1; }
  done
  if [[ "${INSTALL_HERMES:-0}" == 1 ]]; then command -v hermes >/dev/null 2>&1; fi
  if [[ "${INSTALL_EXECUTOR:-0}" == 1 ]]; then command -v executor >/dev/null 2>&1; fi
}

assets_only() {
  make_agent
  install_config
  place_assets
  seed_data
  runuser -u agent -- env HOME=/data/home/agent "$OPT/bin/hb" write-manifest
  log "managed assets refreshed"
}

main() {
  base_os
  make_agent
  install_node_uv
  install_claude
  install_codex
  install_hermes
  install_executor
  install_config
  place_assets
  seed_data
  verify_required
  slim
  log "provision complete"
  PATH="$NODE_PREFIX/bin:$UV_DIR:$PATH" "$OPT/bin/hb" versions || true
}

case "${1:-full}" in
  full) main ;;
  assets) assets_only ;;
  *) log "unknown provisioning mode: $1"; exit 2 ;;
esac
