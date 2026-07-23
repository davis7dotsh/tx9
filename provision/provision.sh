#!/usr/bin/env bash
# Runs INSIDE the build VM. Installs the four tools under /opt/hermes-box,
# corrals all mutable state under /data, and wires up the 'agent' user.
# Safe to re-run. Pass `assets` to refresh only repository-owned guest files.
set -euo pipefail

CTX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # /tmp/ctx
source "$CTX/box.env"

OPT=/opt/hermes-box
# Vite+ manages the Node.js runtime (and hosts npm-global bins like executor);
# its shims live in $VP_HOME/bin. https://viteplus.dev/guide/env
export VP_HOME="$OPT/tooling/vite-plus"
UV_DIR="$OPT/tooling/uv"
# $OPT/bin holds repo-owned tools (hb, hb-workload, hermes-state) plus the
# claude/codex launchers installed below — must be on PATH here too, not
# just for the agent user (guest/profile.sh), so verify_required's
# `command -v` checks see what a real shell would see.
export PATH="$OPT/bin:$VP_HOME/bin:$UV_DIR:$PATH"
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
  # Vite+ owns the Node.js runtime: its node/npm/npx shims land in
  # $VP_HOME/bin and resolve to the managed install, defaulted to LTS below.
  # VP_NODE_MANAGER=yes answers the installer's interactive "manage Node?"
  # prompt (per its documented CI escape hatch).
  log "vite+ (managed node/npm) -> $VP_HOME"
  curl -fsSL https://vite.plus | env VP_NODE_MANAGER=yes bash >/dev/null 2>&1
  "$VP_HOME/bin/vp" env default lts >/dev/null
  # The agent user owns the tree so it can update the managed runtime and
  # vp-installed globals (e.g. `vp install -g executor@latest`) without sudo.
  chown -R agent:agent "$VP_HOME"
  log "uv -> $UV_DIR"
  curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR="$UV_DIR" UV_UNMANAGED_INSTALL="$UV_DIR" sh >/dev/null 2>&1
}

install_claude() {
  # Native installer (no Node dependency): a self-contained binary under
  # $HOME/.local/share/claude plus a $HOME/.local/bin/claude launcher. HOME
  # is pointed at our tooling dir so the whole install stays image content;
  # per-box state still lands on /data via CLAUDE_CONFIG_DIR (profile.sh).
  local channel="${CLAUDE_CODE_CHANNEL:-stable}"
  log "claude-code (native installer, $channel)"
  curl -fsSL https://claude.ai/install.sh \
    | env HOME="$OPT/tooling/claude" bash -s -- "$channel" >/dev/null 2>&1 \
    || { log "claude install FAILED"; return 1; }
  ln -sf "$OPT/tooling/claude/.local/bin/claude" "$OPT/bin/claude"
  # agent owns the tree so claude's self-updater can swap versions in place.
  chown -R agent:agent "$OPT/tooling/claude"
}

install_codex() {
  # Native installer: standalone binary releases under CODEX_HOME/packages
  # with a $CODEX_INSTALL_DIR/codex symlink. Installed into our tooling dir
  # directly on $OPT/bin; per-box state still lands on /data via CODEX_HOME
  # at runtime (profile.sh) — the install-time CODEX_HOME here only decides
  # where the release binaries live.
  log "codex (native installer${CODEX_VERSION:+, $CODEX_VERSION})"
  curl -fsSL https://chatgpt.com/codex/install.sh \
    | env CODEX_INSTALL_DIR="$OPT/bin" CODEX_HOME="$OPT/tooling/codex" \
        CODEX_NON_INTERACTIVE=1 CODEX_RELEASE="${CODEX_VERSION:-latest}" sh >/dev/null 2>&1 \
    || { log "codex install FAILED"; return 1; }
  # agent owns the standalone releases tree so re-running the installer (or a
  # future codex self-update) can swap versions in place.
  chown -R agent:agent "$OPT/tooling/codex"
}

install_hermes() {
  if [[ "${INSTALL_HERMES:-0}" != "1" ]]; then
    log "hermes: INSTALL_HERMES != 1 — skipping"; return
  fi
  local install_dir=/usr/local/lib/hermes-agent
  # Idempotent: skip the multi-minute reinstall if hermes is already on PATH.
  # Lets `assets` repair mode call this safely on every run.
  if command -v hermes >/dev/null 2>&1 && [[ -x "$install_dir/venv/bin/python" ]]; then
    log "hermes already installed — skipping reinstall"
    install_hermes_messaging_deps "$install_dir" || return 1
    chown -R agent:agent "$install_dir"
    return 0
  fi
  log "hermes (official installer)"
  # The normal curl setup. Running as root with no --dir lets the installer's
  # own FHS auto-detection place code at /usr/local/lib/hermes-agent and link
  # the `hermes` command into /usr/local/bin. HERMES_HOME pins the durable
  # state (auth, sessions, skills, memory) onto /data.
  export HERMES_HOME=/data/home/agent/.hermes
  mkdir -p "$HERMES_HOME"
  local arg args=()
  read -r -a args <<<"${HERMES_INSTALL_ARGS:-}"
  for arg in "${args[@]}"; do
    case "$arg" in
      --dir | --dir=* | --hermes-home | --hermes-home=* | --skip-setup | --skip-setup=* | \
      --non-interactive | --non-interactive=*)
        log "HERMES_INSTALL_ARGS cannot override protected installer option: $arg"
        return 1
        ;;
    esac
  done
  if curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
      | bash -s -- "${args[@]}" --hermes-home "$HERMES_HOME" --skip-setup --non-interactive; then
    # Put the launcher on $OPT/bin too so verify_required and the agent user
    # (guest/profile.sh puts $OPT/bin first) see it regardless of where the
    # installer linked it (/usr/local/bin under root/FHS today).
    if [[ -x /usr/local/bin/hermes ]]; then
      ln -sf /usr/local/bin/hermes "$OPT/bin/hermes"
    elif [[ -x "$HOME/.local/bin/hermes" ]]; then
      ln -sf "$HOME/.local/bin/hermes" "$OPT/bin/hermes"
      chmod o+x "$HOME" "$HOME/.local" "$HOME/.local/bin"
    else
      log "hermes install FAILED: launcher not found in /usr/local/bin or \$HOME/.local/bin"
      return 1
    fi
    install_hermes_messaging_deps "$install_dir" || return 1
    own_hermes_home
    # agent owns the code checkout + venv so `hermes update` (which runs
    # `uv pip install --upgrade hermes-agent` into the venv) works without
    # sudo. Verified: update fails with EACCES on venv/bin otherwise.
    chown -R agent:agent "$install_dir"
    log "hermes installed -> $(command -v hermes || echo "$OPT/bin/hermes")"
  else
    log "hermes install FAILED"
    return 1
  fi
}

# The official installer's curated dependency set does not include the
# [messaging] extra, so a freshly provisioned gateway starts but every chat
# platform adapter fails with "Platform 'Discord' requirements not met
# (pip install 'hermes-agent[messaging]')" — the box's whole purpose.
# Verified live during the Eventide migration. Idempotent: uv resolves
# already-satisfied pins in seconds.
install_hermes_messaging_deps() {
  local install_dir="$1"
  [[ -x "$install_dir/venv/bin/python" ]] || {
    log "hermes messaging deps: venv missing at $install_dir/venv"
    return 1
  }
  log "hermes messaging platform deps ([messaging] extra)"
  (cd "$install_dir" && "$UV_DIR/uv" pip install --python venv/bin/python ".[messaging]") || {
    log "hermes messaging deps install FAILED"
    return 1
  }
  "$install_dir/venv/bin/python" -c 'import discord' || {
    log "hermes messaging deps verification FAILED (import discord)"
    return 1
  }
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
  # Idempotent: skip reinstall if already on PATH at the pinned version (any
  # version, if EXECUTOR_VERSION is unset) — the same bar verify_required
  # holds it to. Lets `assets` repair mode call this safely on every run
  # instead of only on a full reinstall, without masking a version bump.
  if command -v executor >/dev/null 2>&1; then
    if [[ -z "${EXECUTOR_VERSION:-}" ]]; then
      log "executor already installed — skipping reinstall"
      return 0
    fi
    local installed_version
    installed_version="$(executor --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ "$installed_version" == "$EXECUTOR_VERSION" ]]; then
      log "executor already installed at pinned $EXECUTOR_VERSION — skipping reinstall"
      return 0
    fi
  fi
  local pkg="executor${EXECUTOR_VERSION:+@$EXECUTOR_VERSION}"
  # Global install through Vite+ so the bin lands in $VP_HOME/bin next to the
  # node/npm shims and `vp install -g executor@latest` updates it in place.
  log "executor (vp global)${EXECUTOR_VERSION:+ ($EXECUTOR_VERSION)}"
  if "$VP_HOME/bin/vp" install -g "$pkg" >/dev/null 2>&1; then
    chown -R agent:agent "$VP_HOME"
    log "executor installed -> $VP_HOME/bin/executor"
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
  log "profile, tmux config, hb, service, and log helpers"
  install -m 0644 "$CTX/guest/profile.sh"  /etc/profile.d/hermes-box.sh
  install -m 0644 "$CTX/guest/tmux.conf"    "$OPT/tmux.conf"
  install -m 0644 "$CTX/guest/lib-mcp.sh"   "$OPT/bin/lib-mcp.sh"
  install -m 0755 "$CTX/guest/hb"           "$OPT/bin/hb"
  install -m 0755 "$CTX/guest/hb-workload"  "$OPT/bin/hb-workload"
  install -m 0755 "$CTX/guest/tx9-services" "$OPT/bin/tx9-services"
  install -m 0755 "$CTX/guest/hermes-state" "$OPT/bin/hermes-state"
  install -m 0755 "$CTX/guest/tx9-logs"      "$OPT/bin/tx9-logs"
  # agent login shell auto-attaches tmux; see guest/agent-bash-profile.sh
  mkdir -p /data/home/agent
  install -m 0644 "$CTX/guest/agent-bash-profile.sh" /data/home/agent/.bash_profile
  chown agent:agent /data/home/agent/.bash_profile
}

seed_data() {
  log "seeding /data skeleton"
  "$OPT/bin/hb" init
}

# Drop build caches so the image stays lean.
slim() {
  log "slimming image (apt/npm/uv caches)"
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/tmp/* /tmp/ctx.tgz 2>/dev/null || true
  "$VP_HOME/bin/npm" cache clean --force >/dev/null 2>&1 || true
  command -v uv >/dev/null 2>&1 && uv cache clean >/dev/null 2>&1 || true
  rm -rf /root/.npm /root/.cache /data/home/agent/.cache 2>/dev/null || true
}

verify_required() {
  log "verifying required tools"
  local cmd
  for cmd in node vp uv nvim claude codex; do
    command -v "$cmd" >/dev/null 2>&1 || { log "missing required tool: $cmd"; return 1; }
  done
  if [[ "${INSTALL_HERMES:-0}" == 1 ]]; then
    command -v hermes >/dev/null 2>&1 || { log "missing required tool: hermes"; return 1; }
  fi
  if [[ "${INSTALL_EXECUTOR:-0}" == 1 ]]; then
    command -v executor >/dev/null 2>&1 || { log "missing required tool: executor"; return 1; }
  fi
}

assets_only() {
  make_agent
  install_hermes
  install_executor
  install_config
  place_assets
  seed_data
  verify_required
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
  PATH="$VP_HOME/bin:$UV_DIR:$PATH" "$OPT/bin/hb" versions || true
}

# Heavy tool installs only — no repo-owned guest assets. Lets the Docker
# image build cache the multi-minute layer independently of guest/ edits;
# a follow-up `assets` run places hb/profiles and seeds /data.
tools_only() {
  base_os
  make_agent
  install_node_uv
  install_claude
  install_codex
  install_hermes
  install_executor
  slim
  log "tool provisioning complete"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-full}" in
    full) main ;;
    tools) tools_only ;;
    assets) assets_only ;;
    *) log "unknown provisioning mode: $1"; exit 2 ;;
  esac
fi
