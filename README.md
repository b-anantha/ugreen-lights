# ugreen-lights

Drive the front-panel LEDs on a UGREEN DXP-series NAS from real system state —
ZFS pool health, disk presence, and network connectivity — from **inside a Docker
container** on TrueNAS SCALE.

Developed and running on a **DXP4800 Plus** (4-bay) and a **DXP2800** (2-bay).
Both use the same LED controller (chip at `0x3a` on the `i2c-0` SMBus I801 bus),
so the only per-model change is the bay count — set `NUM_BAYS` to match your unit
(`4` for the 4800 Plus, `2` for the 2800). Other DXP models very likely work the
same way; adjust `NUM_BAYS` accordingly.

It wraps the [`ugreen_leds_controller`](https://github.com/miskcoo/ugreen_leds_controller)
CLI (vendored as a git submodule) with a status script, [`lights.sh`](lights.sh).

## What the LEDs show

**Disk LEDs (disk1..N)** — ZFS-aware, worst state wins:

| State | LED |
|-------|-----|
| Online & healthy | 🟢 green, solid |
| Online & healthy, this disk's pool is **scrubbing** | 🟢 green, **blinking** |
| Faulted / degraded member | 🔴 red, solid |
| Drive pulled / `UNAVAIL` / `REMOVED` | 🔴 red, **blinking** |
| Admin-offline / read-write-cksum errors / SMART warning | 🟠 amber, solid |
| Resilvering (rebuilding onto this disk) | 🟠 amber, **blinking** |
| Disk present but not in any pool | 🔵 blue, solid |
| Empty bay | ⚫ off |

When a pool member is missing *and* a bay is empty (you pulled a drive), empty
bays blink red. ZFS often only knows a missing vdev by its GUID, so if you have
more than one empty bay any of them may carry the alert.

**Network LED (netdev):** 🟢 link up + gateway reachable · 🟠 link up but
gateway unreachable · 🔴 blinking, link down.

**Power LED:** aggregate pool health — ⚪ white all healthy · 🟠 amber any
pool degraded/warning · 🔴 red any pool faulted. (So an amber power light with
everything else green means a pool needs attention — check `zpool status`.)

Colors, brightness, blink timing and checks are all configurable — see
[`ugreen-leds.conf`](ugreen-leds.conf) or the equivalent environment variables
(the config file and env vars share names).

## Why the CLI approach (and why it works in Docker)

Upstream offers two ways to control the LEDs:

- **A kernel module** (`led-ugreen`) + `/sys/class/leds` + kernel LED triggers.
  Prettier (can flicker on real disk I/O), but needs an out-of-tree module built
  and loaded against the host kernel — painful and non-persistent on TrueNAS, and
  it can't be driven from a container.
- **The `ugreen_leds_cli` tool**, which pokes the SMBus/I2C controller directly.
  **No kernel module required.** This is what we use, and it's why it runs
  cleanly in a container.

Trade-off: without the kernel module the disk LEDs show **health status**, not
live read/write flicker — which is exactly what we want here.

## Setup on TrueNAS SCALE

### 1. Load `i2c-dev` on the host

The one thing the container *can't* do is load a kernel module (modules are
global to the host kernel). Load it on the host and confirm the LED chip answers:

```bash
sudo modprobe i2c-dev
sudo i2cdetect -l     # find the "SMBus I801 adapter"  ->  i2c-0 on DXP4800 Plus / DXP2800
sudo i2cdetect -y 0   # you should see a device at address 0x3a
```

> On both the DXP4800 Plus and the DXP2800 the SMBus I801 adapter is **`i2c-0`**
> (the other buses are the Synopsys DesignWare and i915 GPU buses — ignore them,
> along with any other addresses on `i2c-0`; the LED chip is `0x3a`). The CLI
> auto-selects the I801 bus by name, but the container must be given that device
> node.

Make it persist across reboots via a TrueNAS **Init/Shutdown Script**
(System Settings → Advanced → Init/Shutdown Scripts): command `modprobe i2c-dev`,
type *Command*, when *Pre Init* (so it runs before apps start; see
"Reboot ordering" below).

### 2. Match the container's ZFS to the host's

The container runs `zpool` against the **host kernel's** OpenZFS via `/dev/zfs`,
so the userland version must match the host's `major.minor` — the ioctl interface
changes between releases (a 2.2 userland fails with *"Failed to initialize the
libzfs library"* against a 2.3 kernel). Check the host:

```bash
cat /sys/module/zfs/version     # e.g. 2.3.4-1
```

The [`Dockerfile`](Dockerfile) builds on Debian 13 "trixie" (OpenZFS **2.3.x**)
to match TrueNAS SCALE. If you upgrade TrueNAS to a newer ZFS `major.minor`,
rebuild on a base image that carries that version.

### 3. Run the container

```bash
git clone --recurse-submodules <this repo>
cd ugreen-lights
sudo docker compose up -d --build
```

[`compose.yaml`](compose.yaml) already targets `/dev/i2c-0` and runs
`privileged: true`. Privileged is the pragmatic choice on a NAS: it exposes the
host's `/dev` (so `/dev/zfs`, the data disks **and their partitions**,
`/dev/disk/by-partuuid`, and `/dev/i2c-0` are all present with cgroup access).
A locked-down alternative with an explicit device list is included, commented, in
the compose file.

> **Note on ZFS vdev names.** TrueNAS creates pools on partitions referenced by
> partition UUID, so `zpool status` shows vdevs as bare partuuids, not `sdX`.
> `libblkid` can't read PARTUUIDs inside a container, so the script resolves them
> to disks by reading the host's `/dev/disk/by-partuuid/*` symlinks — which is
> why `compose.yaml` mounts `/dev/disk:ro`.

## Verify the disk mapping

Which physical bay is `disk1`? By default we map by **SCSI host number**
(`HCTL "N:0:0:0" -> disk(N+1)`) — confirmed correct (left-to-right) on the
DXP4800 Plus. Confirm on yours:

```bash
sudo docker compose exec ugreen-lights /app/lights.sh --map
```

It prints a `bay -> device -> serial -> model` table, then lights each bay white
one at a time so you can watch which physical slot each LED belongs to.

If the order is wrong, switch to **serial mapping** — bulletproof, because the
LED follows the disk itself regardless of how the kernel names it. Grab the
serials from the `--map` table (they're read via `smartctl`, since `lsblk`
serials are blank in a container), then set in `ugreen-leds.conf` or as env vars:

```ini
MAPPING_METHOD=serial
DISK_SERIAL="SN_BAY1 SN_BAY2 SN_BAY3 SN_BAY4"   # left-to-right physical order
```

## Operating notes

- **Logs are quiet by design.** `lights.sh` prints a line only when an LED
  actually changes state — so `docker compose logs` shows each LED once at
  startup, then stays silent until something really changes (e.g. a disk faults).
- **Live edits:** uncomment the `./lights.sh:/app/lights.sh:ro` mount in
  `compose.yaml`, then `docker compose restart` picks up script changes without a
  rebuild.
- **Cosmetic hostid warning:** if `zpool status` in the container nags about a
  hostid mismatch, uncomment the `/etc/hostid` mount in `compose.yaml`. It
  doesn't affect the LED logic either way.
- **Reboot ordering is handled for you.** On boot the container can come up
  *before* `i2c-dev` is loaded on the host. A privileged container only sees a
  snapshot of the host's `/dev` taken when it starts, so a `/dev/i2c-*` created
  later never appears inside it — restarting the container is the only way to
  pick it up. So `lights.sh` exits non-zero when there is no `/dev/i2c-*` or an
  LED write fails, the container stops, and `restart: unless-stopped` brings up
  a fresh one, retrying until the module is loaded. A failed write is never
  cached, and the cache itself lives on a tmpfs (`/run/ugreen-leds`), so every
  new container re-applies all LEDs. To make the first start succeed, run the
  `modprobe` from step 1 as **Pre Init** rather than Post Init, so the module is
  loaded before apps start.

## Files

| File | Purpose |
|------|---------|
| [`lights.sh`](lights.sh) | The status script. One run = one full LED refresh; `--map` verifies mapping. |
| [`ugreen-leds.conf`](ugreen-leds.conf) | Optional overrides (mount at `/etc/ugreen-leds.conf`). |
| [`Dockerfile`](Dockerfile) | Builds the CLI from the submodule (Debian trixie / ZFS 2.3.x). |
| [`compose.yaml`](compose.yaml) | TrueNAS deployment (privileged, `/dev/disk` + `pid: host`, refresh loop). |
| `ugreen_leds_controller/` | Upstream CLI/kernel-module source (git submodule). |

## Configuration reference

All keys below work as environment variables (in `compose.yaml`) or in
`ugreen-leds.conf`. Defaults shown.

| Key | Default | Meaning |
|-----|---------|---------|
| `UPDATE_INTERVAL` | `5` | Seconds between refreshes. |
| `NUM_BAYS` | `4` | Number of disk bays / LEDs (`4` = DXP4800 Plus, `2` = DXP2800). |
| `MAPPING_METHOD` | `hctl` | `hctl` or `serial`. |
| `HCTL_OFFSET` | `1` | `hctl`: diskLED = SCSI host number + offset. |
| `DISK_SERIAL` | — | `serial`: serials in physical bay order. |
| `BRIGHTNESS` | `64` | LED brightness, 0–255. |
| `BLINK_ON` / `BLINK_OFF` | `400` / `600` | Blink on/off time (ms). |
| `CHECK_SMART` | `true` | SMART health overlay (needs smartmontools + disks). |
| `CHECK_GATEWAY` | `true` | Ping the default gateway for the network LED. |
| `NETDEV_NAME` | auto | Interface to reflect; empty = default-route device. |
| `COLOR_*` | see conf | Per-state RGB colors. |

## Credits

LED protocol, CLI tool, and kernel module by
[miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller).
This repo adds the containerized, ZFS-aware status layer on top.
