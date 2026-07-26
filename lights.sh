#!/usr/bin/env bash
#
# lights.sh — drive the UGREEN DXP-series front-panel LEDs from ZFS / system state.
#
# This is the CLI-tool approach: we talk to the LEDs by shelling out to
# `ugreen_leds_cli`, which pokes the SMBus/I2C controller directly. It needs
# NO custom kernel module, which is what makes it work inside a container on
# TrueNAS. (The upstream `ugreen-diskiomon`/`ugreen-netdevmon` scripts are
# prettier but depend on the out-of-tree `led-ugreen` kernel module and
# /sys/class/leds — not container-friendly.)
#
# One invocation = one full refresh of every LED. Run it in a loop (see the
# Dockerfile CMD). It is stateless except for a tiny cache in $STATE_DIR used
# only to avoid re-issuing identical commands (keeps blink phase smooth and the
# logs quiet).
#
# Config: values below can be overridden by environment variables or by a
# config file at $CONF_FILE (default /etc/ugreen-leds.conf). Env wins is not
# the case — the config file is sourced last, so uncommented values there win.

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration (all overridable via env or $CONF_FILE)
# ----------------------------------------------------------------------------
UGREEN_CLI="${UGREEN_CLI:-/app/ugreen_leds_cli}"
CONF_FILE="${CONF_FILE:-/etc/ugreen-leds.conf}"
STATE_DIR="${STATE_DIR:-/run/ugreen-leds}"

# How many disk bays this model has (DXP4800 Plus = 4).
NUM_BAYS="${NUM_BAYS:-4}"

# How to map physical bays to disks:
#   hctl   - by SCSI host number (default). For DX4600/DXP4800/DXP8800 the host
#            number maps straight to the bay: HCTL "N:0:0:0" -> disk$((N+HCTL_OFFSET)).
#            Robust across reboots but controller-dependent — VERIFY it once
#            (see README: `lights.sh --map`).
#   serial - bulletproof: you list each disk's serial in physical bay order in
#            DISK_SERIAL below. The LED then follows the disk itself, regardless
#            of how the kernel names/enumerates it. Recommended once you've
#            confirmed which serial is in which bay.
MAPPING_METHOD="${MAPPING_METHOD:-hctl}"
HCTL_OFFSET="${HCTL_OFFSET:-1}"

# Only used when MAPPING_METHOD=serial. Space-separated serials, bay 1 first:
#   DISK_SERIAL="SERIAL_BAY1 SERIAL_BAY2 SERIAL_BAY3 SERIAL_BAY4"
# Find serials with:  lsblk -S -o NAME,HCTL,SERIAL,MODEL
DISK_SERIAL="${DISK_SERIAL:-}"

# Network interface to reflect. Empty = auto-detect from the default route.
NETDEV_NAME="${NETDEV_NAME:-}"

# Global brightness for every LED (0-255). The originals used 64; bump if dim.
BRIGHTNESS="${BRIGHTNESS:-64}"

# Blink timing in ms (on off) used for all blinking states.
BLINK_ON="${BLINK_ON:-400}"
BLINK_OFF="${BLINK_OFF:-600}"

# SMART health overlay on otherwise-healthy disks. Requires smartmontools in
# the image AND the raw disks passed into the container (or privileged).
CHECK_SMART="${CHECK_SMART:-true}"

# Ping the default gateway to distinguish "link up" from "actually reachable".
CHECK_GATEWAY="${CHECK_GATEWAY:-true}"

# ---- Colors (R G B). Tweak to taste. ----
COLOR_HEALTHY="${COLOR_HEALTHY:-0 255 0}"       # green  — online & healthy
COLOR_FAULT="${COLOR_FAULT:-255 0 0}"           # red    — faulted / degraded member
COLOR_WARN="${COLOR_WARN:-255 90 0}"            # amber  — offline / errors / SMART / resilver
COLOR_AVAIL="${COLOR_AVAIL:-0 0 255}"           # blue   — disk present but not in a pool
COLOR_POWER_OK="${COLOR_POWER_OK:-255 255 255}" # white  — all pools healthy
COLOR_NET_OK="${COLOR_NET_OK:-0 255 0}"         # green  — link up + reachable

# ----------------------------------------------------------------------------
# Load user config file last so it can override the defaults above.
# ----------------------------------------------------------------------------
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ----------------------------------------------------------------------------
# set_led <led> <mode> <R G B>
#   mode = solid | blink | off
# Skips the CLI call if the LED is already in exactly this state (cache).
# ----------------------------------------------------------------------------
set_led() {
    local led="$1" mode="$2" color="${3:-}"
    local spec="$mode|$color|$BRIGHTNESS|$BLINK_ON|$BLINK_OFF"
    local cache="$STATE_DIR/$led"

    if [[ -f "$cache" && "$(<"$cache")" == "$spec" ]]; then
        return 0    # unchanged — leave the LED alone
    fi

    case "$mode" in
        solid) "$UGREEN_CLI" "$led" -color $color -on -brightness "$BRIGHTNESS" >/dev/null 2>&1 ;;
        blink) "$UGREEN_CLI" "$led" -color $color -blink "$BLINK_ON" "$BLINK_OFF" -brightness "$BRIGHTNESS" >/dev/null 2>&1 ;;
        off)   "$UGREEN_CLI" "$led" -off >/dev/null 2>&1 ;;
    esac

    echo "$spec" > "$cache"
}

# ----------------------------------------------------------------------------
# Gather ZFS state once per refresh.
#   zdev_state[sdX]   = worst vdev state seen for that physical disk
#   zdev_flag[sdX]    = "warn" if errors or resilvering on that disk
#   POOL_MISSING      = 1 if any pool member is UNAVAIL/REMOVED (a pulled disk)
#   POOL_WORST        = ONLINE | DEGRADED | FAULTED  (aggregate, for power LED)
# ----------------------------------------------------------------------------
declare -A zdev_state zdev_flag
POOL_MISSING=0
POOL_WORST="ONLINE"

# rank a zfs state so we can keep the worst one
state_rank() {
    case "$1" in
        FAULTED|UNAVAIL|REMOVED) echo 3 ;;
        DEGRADED)                echo 2 ;;
        OFFLINE)                 echo 1 ;;
        *)                       echo 0 ;;   # ONLINE / unknown
    esac
}

gather_zfs() {
    command -v zpool >/dev/null 2>&1 || return 0
    local status
    status="$(zpool status -L 2>/dev/null)" || return 0

    # Per-disk vdev lines, e.g. "  sdb2  ONLINE  0 0 0  (resilvering)"
    local name st rd wr ck rest base cur old
    while read -r name st rd wr ck rest; do
        base="$(sed 's/[0-9]*$//' <<<"$name")"       # sdb2 -> sdb
        old="${zdev_state[$base]:-ONLINE}"
        if (( $(state_rank "$st") > $(state_rank "$old") )); then
            zdev_state[$base]="$st"
        else
            zdev_state[$base]="$old"
        fi
        if [[ "$rd" != "0" || "$wr" != "0" || "$ck" != "0" || "$rest" == *resilvering* ]]; then
            zdev_flag[$base]="warn"
        fi
    done < <(grep -E '^[[:space:]]+sd[a-z]+[0-9]+[[:space:]]+[A-Z]+' <<<"$status")

    # A member shown as UNAVAIL/REMOVED means a disk the pool expects is gone.
    if grep -qE '[[:space:]](UNAVAIL|REMOVED)[[:space:]]' <<<"$status"; then
        POOL_MISSING=1
    fi

    # Aggregate pool health for the power LED.
    local pst
    while read -r _ pst; do
        case "$pst" in
            FAULTED|UNAVAIL) POOL_WORST="FAULTED" ;;
            DEGRADED)        [[ "$POOL_WORST" == "ONLINE" ]] && POOL_WORST="DEGRADED" ;;
        esac
    done < <(grep -E '^[[:space:]]*state:' <<<"$status")
    (( POOL_MISSING )) && [[ "$POOL_WORST" == "ONLINE" ]] && POOL_WORST="DEGRADED"
}

# ----------------------------------------------------------------------------
# Map disk bays -> block devices.
#   bay_dev[N] = sdX for bay N (1-based), unset if the bay is empty.
# ----------------------------------------------------------------------------
declare -A bay_dev
map_bays() {
    if [[ "$MAPPING_METHOD" == "serial" ]]; then
        # serial -> device, then walk DISK_SERIAL in bay order.
        local name serial bay=0 want
        declare -A serial_dev
        while read -r name serial; do
            [[ -n "$serial" ]] && serial_dev[$serial]="$name"
        done < <(lsblk -S -o NAME,SERIAL 2>/dev/null | tail -n +2)
        for want in $DISK_SERIAL; do
            bay=$(( bay + 1 ))
            [[ -n "${serial_dev[$want]:-}" ]] && bay_dev[$bay]="${serial_dev[$want]}"
        done
        return
    fi

    # Default: map by SCSI host number (HCTL).
    local name hctl host bay
    while read -r name hctl; do
        [[ -z "$hctl" ]] && continue
        host="${hctl%%:*}"                    # "2:0:0:0" -> "2"
        [[ "$host" =~ ^[0-9]+$ ]] || continue
        bay=$(( host + HCTL_OFFSET ))
        bay_dev[$bay]="$name"
    done < <(lsblk -S -o NAME,HCTL 2>/dev/null | tail -n +2)
}

# ----------------------------------------------------------------------------
# smart_bad <sdX> -> return 0 if SMART reports a critical problem.
# Ignores "on standby" so we don't spin idle disks up.
# ----------------------------------------------------------------------------
smart_bad() {
    [[ "$CHECK_SMART" == "true" ]] || return 1
    command -v smartctl >/dev/null 2>&1 || return 1
    smartctl -H "/dev/$1" -n standby,0 >/dev/null 2>&1
    local rc=$?
    # Bit 5 (=32) just means "on standby"; any other bit = real problem.
    (( rc & ~32 )) && return 0 || return 1
}

# ----------------------------------------------------------------------------
# Decide and set each disk LED.
# ----------------------------------------------------------------------------
update_disks() {
    local bay led dev st
    for (( bay=1; bay<=NUM_BAYS; bay++ )); do
        led="disk$bay"
        dev="${bay_dev[$bay]:-}"

        # --- Empty bay ---
        if [[ -z "$dev" ]]; then
            if (( POOL_MISSING )); then
                # A pool member is missing and this bay is empty -> likely the
                # disk that was pulled. (Can't always pinpoint which bay once
                # ZFS only knows the vdev by GUID, so any empty bay flags it.)
                set_led "$led" blink "$COLOR_FAULT"
            else
                set_led "$led" off
            fi
            continue
        fi

        st="${zdev_state[$dev]:-__NOTINPOOL__}"

        case "$st" in
            __NOTINPOOL__)
                # Disk is physically present but not part of any imported pool.
                set_led "$led" solid "$COLOR_AVAIL"
                ;;
            FAULTED|DEGRADED)
                set_led "$led" solid "$COLOR_FAULT"
                ;;
            UNAVAIL|REMOVED)
                set_led "$led" blink "$COLOR_FAULT"
                ;;
            OFFLINE)
                set_led "$led" solid "$COLOR_WARN"       # admin took it offline
                ;;
            ONLINE)
                if [[ "${zdev_flag[$dev]:-}" == "warn" ]]; then
                    # errors logged or actively resilvering -> amber
                    if zpool status -L 2>/dev/null | grep -qE "^[[:space:]]+${dev}[0-9]+[[:space:]].*resilvering"; then
                        set_led "$led" blink "$COLOR_WARN"
                    else
                        set_led "$led" solid "$COLOR_WARN"
                    fi
                elif smart_bad "$dev"; then
                    set_led "$led" solid "$COLOR_WARN"
                    log "SMART warning on /dev/$dev (bay $bay)"
                else
                    set_led "$led" solid "$COLOR_HEALTHY"
                fi
                ;;
            *)
                set_led "$led" solid "$COLOR_WARN"
                ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Network LED: green = up + gateway reachable, amber = up but unreachable,
# red blink = link down.
# ----------------------------------------------------------------------------
update_netdev() {
    local iface="$NETDEV_NAME"
    [[ -z "$iface" ]] && iface="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"

    if [[ -z "$iface" || "$(cat /sys/class/net/$iface/operstate 2>/dev/null)" != "up" ]]; then
        set_led netdev blink "$COLOR_FAULT"
        return
    fi

    if [[ "$CHECK_GATEWAY" == "true" ]]; then
        local gw
        gw="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
        if [[ -n "$gw" ]] && ! ping -q -c 1 -W 1 "$gw" >/dev/null 2>&1; then
            set_led netdev solid "$COLOR_WARN"          # link up but no gateway
            return
        fi
    fi

    set_led netdev solid "$COLOR_NET_OK"
}

# ----------------------------------------------------------------------------
# Power LED: aggregate pool health at a glance.
# ----------------------------------------------------------------------------
update_power() {
    case "$POOL_WORST" in
        FAULTED)  set_led power solid "$COLOR_FAULT" ;;
        DEGRADED) set_led power solid "$COLOR_WARN" ;;
        *)        set_led power solid "$COLOR_POWER_OK" ;;
    esac
}

# ----------------------------------------------------------------------------
# `lights.sh --map`: verify bay<->LED mapping. Prints the table and lights each
# occupied bay white, one at a time, so you can watch which physical slot the
# disk1..N LEDs actually correspond to.
# ----------------------------------------------------------------------------
verify_map() {
    map_bays
    echo "Mapping method: $MAPPING_METHOD"
    printf '%-6s %-6s %-24s %s\n' "BAY" "DEV" "SERIAL" "MODEL"
    local bay dev info
    for (( bay=1; bay<=NUM_BAYS; bay++ )); do
        dev="${bay_dev[$bay]:-}"
        if [[ -z "$dev" ]]; then
            printf '%-6s %-6s %-24s %s\n' "disk$bay" "-" "(empty)" ""
            continue
        fi
        info="$(lsblk -S -o NAME,SERIAL,MODEL 2>/dev/null | awk -v d="$dev" '$1==d {$1="";print}')"
        printf '%-6s %-6s %s\n' "disk$bay" "$dev" "$info"
    done

    [[ -x "$UGREEN_CLI" ]] || { echo "(no CLI / hardware — table only)"; return; }
    echo "Lighting each occupied bay white for 2s so you can confirm the slot..."
    for (( bay=1; bay<=NUM_BAYS; bay++ )); do
        [[ -z "${bay_dev[$bay]:-}" ]] && continue
        echo "  -> disk$bay (${bay_dev[$bay]})"
        "$UGREEN_CLI" "disk$bay" -color 255 255 255 -on -brightness 255 >/dev/null 2>&1
        sleep 2
        "$UGREEN_CLI" "disk$bay" -off >/dev/null 2>&1
    done
    rm -rf "${STATE_DIR:?}/"*   # force a full refresh on the next normal run
}

# ----------------------------------------------------------------------------
main() {
    if [[ "${1:-}" == "--map" ]]; then
        verify_map
        exit 0
    fi

    if [[ ! -x "$UGREEN_CLI" ]]; then
        log "ERROR: ugreen_leds_cli not found at $UGREEN_CLI"
        exit 1
    fi

    gather_zfs
    map_bays
    update_power
    update_netdev
    update_disks
}

main "$@"
