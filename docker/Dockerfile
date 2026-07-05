# hermes-box-lite on Docker — everything baked into one image at build time.
#
# The whole provisioning story (node, uv, claude, codex, hermes, executor,
# guest assets, /data skeleton) is the existing provision/provision.sh, run
# once at BUILD time instead of streamed into a live VM on every `box new`.
# Creating a box becomes `docker run` + named volume: seconds, not minutes,
# and every box is bit-identical to the image it came from.
#
# /data is declared a VOLUME after the skeleton is seeded, so a fresh named
# volume is auto-populated from the image on first mount (Docker copies the
# image's mount-point contents into an empty named volume).
#
# Build from the repository root:
#   docker build -t hermes-box-lite -f docker/Dockerfile .

FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Two provisioning layers so day-to-day guest-script edits don't re-run the
# multi-minute tool installs: `tools` (node/uv/claude/codex/hermes/executor)
# caches until box.env or provision.sh changes; `assets` (hb, profiles, /data
# skeleton) rebuilds in seconds when guest/ changes.
COPY box.env /tmp/ctx/box.env
COPY provision/ /tmp/ctx/provision/
RUN bash /tmp/ctx/provision/provision.sh tools

COPY guest/ /tmp/ctx/guest/
RUN bash /tmp/ctx/provision/provision.sh assets && rm -rf /tmp/ctx

COPY docker/entrypoint.sh /opt/hermes-box/bin/entrypoint
COPY docker/executor-entrypoint.sh /opt/hermes-box/bin/executor-entrypoint
RUN chmod 0755 /opt/hermes-box/bin/entrypoint /opt/hermes-box/bin/executor-entrypoint

# Durable state. Everything else in the container is disposable image content.
VOLUME /data

# Fixed internal bridge ports (hb-workload's socat bridges bind 0.0.0.0 here
# and forward to the loopback-only services). Hosts publish these with -p and
# let Docker pick free host ports — no port registry, no collision logic.
EXPOSE 14788 18642

ENTRYPOINT ["/opt/hermes-box/bin/entrypoint"]
