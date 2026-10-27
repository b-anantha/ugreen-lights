# -- Stage 1: Compile the CLI tool from source --
FROM debian:trixie-slim AS builder

RUN apt-get update && apt-get install -y build-essential

WORKDIR /build
COPY ugreen_leds_controller /build/ugreen_leds_controller

WORKDIR /build/ugreen_leds_controller/cli
RUN make


# -- Stage 2: Clean runtime image --
FROM debian:trixie-slim

# Runtime deps:
#   bash            - lights.sh
#   iproute2        - `ip route` for gateway / interface detection
#   iputils-ping    - gateway reachability check
#   util-linux      - lsblk for disk<->bay mapping
#   zfsutils-linux  - `zpool status` (ZFS health) — see version note below
#   smartmontools   - optional SMART health overlay (CHECK_SMART=true)
#
# NOTES:
#  * We intentionally do NOT modprobe anything here. The i2c-dev module must be
#    loaded on the TrueNAS HOST; the container only needs /dev/i2c-* + /sys.
#  * The container's `zpool` talks to the HOST kernel's OpenZFS via /dev/zfs, so
#    the userland version MUST match the host's ZFS major.minor — the ioctl
#    interface changes between releases (a 2.2 userland fails to init against a
#    2.3 kernel). This image is Debian 13 "trixie", which ships OpenZFS 2.3.x to
#    match TrueNAS SCALE (host reported 2.3.4). If you upgrade TrueNAS to a newer
#    ZFS major.minor, rebuild on a base image carrying that version.
#  * `zfsutils-linux` is in Debian's `contrib` component (not `main`). No kernel
#    modules are installed — the container uses the host's ZFS.
RUN echo "deb http://deb.debian.org/debian trixie main contrib" \
        > /etc/apt/sources.list.d/contrib.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        bash iproute2 iputils-ping util-linux smartmontools zfsutils-linux && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/ugreen_leds_controller/cli/ugreen_leds_cli /app/ugreen_leds_cli
COPY lights.sh /app/lights.sh
RUN chmod +x /app/ugreen_leds_cli /app/lights.sh

# Seconds between refreshes.
ENV UPDATE_INTERVAL=5

# Refresh the LEDs forever. One `lights.sh` call = one full refresh.
# A failing refresh (no /dev/i2c-*, or an LED write failed) ends the loop and
# the container, so `restart: unless-stopped` starts a fresh one — with a fresh
# /dev snapshot, which is what picks up an i2c-dev loaded after boot.
CMD ["/bin/bash", "-c", "while /app/lights.sh; do sleep \"${UPDATE_INTERVAL}\"; done; exit 1"]
