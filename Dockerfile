# -- Stage 1: Compile the CLI tool from source --
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y build-essential

WORKDIR /build
COPY ugreen_leds_controller /build/ugreen_leds_controller

WORKDIR /build/ugreen_leds_controller/cli
RUN make


# -- Stage 2: Clean runtime image --
FROM debian:bookworm-slim

# Runtime deps:
#   bash            - lights.sh
#   iproute2        - `ip route` for gateway / interface detection
#   iputils-ping    - gateway reachability check
#   util-linux      - lsblk for disk<->bay mapping
#   zfsutils-linux  - `zpool status` (ZFS health)
#   smartmontools   - optional SMART health overlay (CHECK_SMART=true)
# NOTE: we intentionally do NOT modprobe anything here. The i2c-dev module must
#       be loaded on the TrueNAS HOST; the container only needs /dev/i2c-* + /sys.
RUN apt-get update && apt-get install -y \
    bash \
    iproute2 \
    iputils-ping \
    util-linux \
    zfsutils-linux \
    smartmontools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/ugreen_leds_controller/cli/ugreen_leds_cli /app/ugreen_leds_cli
COPY lights.sh /app/lights.sh
RUN chmod +x /app/ugreen_leds_cli /app/lights.sh

# Seconds between refreshes.
ENV UPDATE_INTERVAL=5

# Refresh the LEDs forever. One `lights.sh` call = one full refresh.
CMD ["/bin/bash", "-c", "while true; do /app/lights.sh; sleep \"${UPDATE_INTERVAL}\"; done"]
