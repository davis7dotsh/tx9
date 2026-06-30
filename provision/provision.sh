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
# $OPT/bin holds repo-owned tools (hb, hb-workload, hermes-state) plus the
# hermes launcher symlink installed below — must be on PATH here too, not
# just for the agent user (guest/profile.sh), so verify_required's
# `command -v` checks see what a real shell would see.
export PATH="$OPT/bin:$NODE_PREFIX/bin:$UV_DIR:$PATH"
export DEBIAN_FRONTEND=noninteractive

log() { printf '\033[35m[provision]\033[0m %s\n' "$*"; }

verify_self_contained_bundle() {
  local bundle_path="$1" verify_repo status=0
  verify_repo="$(mktemp -d)" || return 1
  git init --bare "$verify_repo" >/dev/null 2>&1 || status=$?
  if [[ "$status" == 0 ]]; then
    git -C "$verify_repo" bundle verify "$bundle_path" >/dev/null 2>&1 || status=$?
  fi
  rm -rf "$verify_repo"
  return "$status"
}

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
  local pkg="@anthropic-ai/claude-code${CLAUDE_CODE_VERSION:+@$CLAUDE_CODE_VERSION}"
  log "claude-code${CLAUDE_CODE_VERSION:+ ($CLAUDE_CODE_VERSION)}"
  "$NODE_PREFIX/bin/npm" install -g "$pkg" >/dev/null 2>&1 \
    || npm install -g "$pkg" >/dev/null
}

install_codex() {
  local pkg="@openai/codex${CODEX_VERSION:+@$CODEX_VERSION}"
  log "codex${CODEX_VERSION:+ ($CODEX_VERSION)}"
  "$NODE_PREFIX/bin/npm" install -g "$pkg" >/dev/null 2>&1 \
    || npm install -g "$pkg" >/dev/null
}

install_hermes() {
  if [[ "${INSTALL_HERMES:-0}" != "1" ]]; then
    log "hermes: INSTALL_HERMES != 1 — skipping"; return
  fi
  local sha="${HERMES_GIT_SHA:-}" bundle="${HERMES_GIT_BUNDLE:-}" install_dir=/usr/local/lib/hermes-agent
  local installer_sha="${HERMES_INSTALLER_SHA256:-}" installer
  [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || { log "invalid HERMES_GIT_SHA: $sha"; return 1; }
  [[ "$installer_sha" =~ ^[0-9a-fA-F]{64}$ ]] || { log "invalid HERMES_INSTALLER_SHA256"; return 1; }
  log "hermes (official installer pinned to $sha)"
  # We run as root and pass an explicit --dir below, which makes the installer
  # skip its own root/FHS auto-detection (resolve_install_layout() returns
  # early whenever --dir is explicit) and link the `hermes` command into
  # $HOME/.local/bin instead of /usr/local/bin. $HOME is root's home here
  # since this whole script runs as root. Code still lands at $install_dir
  # (/usr/local/lib/hermes-agent) since that part of --dir is honored either
  # way. HERMES_HOME pins the durable state (auth, sessions, skills, memory)
  # onto /data. See the symlink step below that puts `hermes` on agent's PATH.
  export HERMES_HOME=/data/home/agent/.hermes
  mkdir -p "$HERMES_HOME"
  if [[ -n "$bundle" ]]; then
    [[ "$bundle" != /* && "$bundle" != *..* && "$bundle" == artifacts/* ]] || {
      log "HERMES_GIT_BUNDLE must be a safe path beneath artifacts/"; return 1;
    }
    [[ -f "$CTX/$bundle" ]] || { log "Hermes Git bundle is missing: $CTX/$bundle"; return 1; }
    verify_self_contained_bundle "$CTX/$bundle" || {
      log "Hermes Git bundle is incomplete or invalid"; return 1;
    }
  fi
  local arg args=()
  read -r -a args <<<"${HERMES_INSTALL_ARGS:-}"
  for arg in "${args[@]}"; do
    case "$arg" in
      --dir | --dir=* | --hermes-home | --hermes-home=* | --commit | --commit=* | \
      --skip-setup | --skip-setup=* | --non-interactive | --non-interactive=*)
        log "HERMES_INSTALL_ARGS cannot override protected installer option: $arg"
        return 1
        ;;
    esac
  done
  installer="$(mktemp)"
  if ! curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$installer"; then
    rm -f "$installer"
    log "Hermes installer download failed"
    return 1
  fi
  if ! printf '%s  %s\n' "$installer_sha" "$installer" | sha256sum --check --status; then
    rm -f "$installer"
    log "Hermes installer checksum verification failed"
    return 1
  fi
  if [[ -n "$bundle" ]]; then
    if ! rm -rf "$install_dir" \
      || ! git clone --no-checkout "$CTX/$bundle" "$install_dir" >/dev/null \
      || ! git -C "$install_dir" cat-file -e "$sha^{commit}" \
      || ! git -C "$install_dir" checkout --detach "$sha"; then
      rm -f "$installer"
      log "Hermes bundle checkout failed"
      return 1
    fi
  fi
  if bash "$installer" "${args[@]}" --dir "$install_dir" --hermes-home "$HERMES_HOME" \
       --commit "$sha" --skip-setup --non-interactive; then
    rm -f "$installer"
    [[ "$(git -C "$install_dir" rev-parse HEAD)" == "$sha" ]] || {
      log "Hermes checkout verification failed"; return 1;
    }
    if [[ -n "$bundle" ]]; then
      git -C "$install_dir" remote set-url origin \
        "${HERMES_REPO_URL:-https://github.com/NousResearch/hermes-agent.git}"
    fi
    # Put the launcher on PATH for both this script (root) and the agent user
    # (guest/profile.sh puts $OPT/bin first). $HOME is root's home since this
    # whole script runs as root; that's where an explicit --dir install links
    # the command (see the comment above this function). Fall back to the
    # FHS location in case a future installer version goes back to it.
    if [[ -x "$HOME/.local/bin/hermes" ]]; then
      ln -sf "$HOME/.local/bin/hermes" "$OPT/bin/hermes"
    elif [[ -x /usr/local/bin/hermes ]]; then
      ln -sf /usr/local/bin/hermes "$OPT/bin/hermes"
    else
      log "hermes install FAILED: launcher not found in \$HOME/.local/bin or /usr/local/bin"
      return 1
    fi
    own_hermes_home
    log "hermes installed -> $(command -v hermes || echo "$OPT/bin/hermes")"
  else
    rm -f "$installer"
    log "hermes install FAILED"
    return 1
  fi
}

own_hermes_home() {
  # The verified installer runs as root and may create mutable state several
  # levels deep. Repair ownership only inside Hermes's durable state root.
  chown -R agent:agent "$HERMES_HOME"
  chmod -R u+rwX "$HERMES_HOME"
}

install_executor() {
  if [[ "${INSTALL_EXECUTOR:-0}" != "1" ]]; then
    log "executor: INSTALL_EXECUTOR != 1 — skipping"; return
  fi
  local pkg="executor${EXECUTOR_VERSION:+@$EXECUTOR_VERSION}"
  log "executor (npm global)${EXECUTOR_VERSION:+ ($EXECUTOR_VERSION)}"
  if "$NODE_PREFIX/bin/npm" install -g "$pkg" >/dev/null 2>&1 \
       || npm install -g "$pkg" >/dev/null 2>&1; then
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
  install -m 0755 "$CTX/guest/hermes-state" "$OPT/bin/hermes-state"
  # agent login shell auto-attaches tmux; see guest/agent-bash-profile.sh
  mkdir -p /data/home/agent
  install -m 0644 "$CTX/guest/agent-bash-profile.sh" /data/home/agent/.bash_profile
  chown agent:agent /data/home/agent/.bash_profile
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
  if [[ "${INSTALL_HERMES:-0}" == 1 ]]; then
    command -v hermes >/dev/null 2>&1 || { log "missing required tool: hermes"; return 1; }
  fi
  if [[ "${INSTALL_EXECUTOR:-0}" == 1 ]]; then
    command -v executor >/dev/null 2>&1 || { log "missing required tool: executor"; return 1; }
  fi
  if [[ "${INSTALL_HERMES:-0}" == 1 ]]; then
    [[ "$(git -C /usr/local/lib/hermes-agent rev-parse HEAD)" == "${HERMES_GIT_SHA}" ]] || {
      log "Hermes checkout HEAD does not match pinned HERMES_GIT_SHA"; return 1;
    }
  fi
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-full}" in
    full) main ;;
    assets) assets_only ;;
    *) log "unknown provisioning mode: $1"; exit 2 ;;
  esac
fi
