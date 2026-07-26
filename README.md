# ugreen-lights

Drive the front-panel LEDs on a UGREEN DXP-series NAS (tested target: **DXP4800
Plus**) from real system state — ZFS pool health, disk presence, and network
connectivity — while running **inside a Docker container** on TrueNAS.

It wraps the [`ugreen_leds_controller`](https://github.com/miskcoo/ugreen_leds_controller)
CLI (vendored as a submodule) with a status script, [`lights.sh`](lights.sh).

## Why the CLI approach (and why it works in Docker)

The upstream project offers two ways to control the LEDs:

- **A kernel module** (`led-ugreen`) + `/sys/class/leds` + kernel LED triggers.
  Prettier (can flicker on real disk I/O), but needs an out-of-tree module
  built and loaded against the host kernel — painful and non-persistent on
  TrueNAS, and it can't be driven from inside a container.
- **The `ugreen_leds_cli` tool**, which pokes the SMBus/I2C controller
  directly. **No kernel module required.** This is what we use, and it's why
  this runs cleanly in a container.

The one thing the container can't do is *load* the `i2c-dev` kernel module —
that has to happen on the **TrueNAS host** (modules are global to the host
kernel). Once it's loaded, the container just needs the `/dev/i2c-*` node and
the host `/sys` (already mounted). See setup below.

Trade-off: because we don't use the kernel module, the disk LEDs show **health
status**, not live read/write flicker.

## What the LEDs show

**Disk LEDs (disk1..N)** — ZFS-aware, worst state wins:

| State | LED |
|-------|-----|
| Online & healthy | 🟢 green, solid |
| Faulted / degraded member | 🔴 red, solid |
| Drive pulled / `UNAVAIL` / `REMOVED` | 🔴 red, **blinking** |
| Admin-offline / read-write-cksum errors / SMART warning | 🟠 amber, solid |
| Resilvering (rebuilding onto this disk) | 🟠 amber, **blinking** |
| Disk present but not in any pool | 🔵 blue, solid |
| Empty bay | ⚫ off |

(When a pool member is missing and a bay is empty — i.e. you pulled a drive —
empty bays blink red. ZFS often only knows the missing vdev by GUID, so if you
have more than one empty bay any of them may carry the alert.)

**Network LED (netdev):** 🟢 link up + gateway reachable · 🟠 link up but
gateway unreachable · 🔴 blinking, link down.

**Power LED:** aggregate pool health — ⚪ white all healthy · 🟠 amber any
pool degraded/warning · 🔴 red any pool faulted.

Colors, brightness, blink timing and checks are all configurable — see
[`ugreen-leds.conf`](ugreen-leds.conf) or the equivalent environment variables
(the config file and env vars share names).

## Setup on TrueNAS SCALE

### 1. Load `i2c-dev` on the host

Confirm the controller is visible and note the bus number:

```bash
sudo modprobe i2c-dev
i2cdetect -l                 # find the "SMBus I801 adapter" -> i2c-0 on DXP4800 Plus
i2cdetect -y 0               # you should see a device at address 0x3a
```

> The SMBus I801 adapter is **`i2c-0`** on the DXP4800 Plus (other buses are the
> Synopsys DesignWare and i915 GPU buses — ignore them). The CLI auto-selects
> the I801 bus by name, but the container must be given that exact device node.

Make it persistent across reboots via a TrueNAS **Init/Shutdown Script**
(System Settings → Advanced → Init/Shutdown Scripts), command
`modprobe i2c-dev`, type *Command*, when *Post Init*.

### 2. Run the container

The i2c bus is already set to `/dev/i2c-0` in [`compose.yaml`](compose.yaml)
(correct for the DXP4800 Plus). Then:

```bash
docker compose up -d --build
docker compose logs -f
```

The compose file passes in `/dev/i2c-1`, `/dev/zfs` (so `zpool status` reads
host pools), the data disks (for SMART), and `pid: host`. If device passthrough
is awkward on your TrueNAS version, set `privileged: true` and drop the
`devices:` list.

## Verify the disk mapping (important!)

Which physical bay is `disk1`? By default we map by **SCSI host number**
(`HCTL "N:0:0:0" -> disk(N+1)`), which upstream reports is correct for the
DXP4800 Plus — but you should confirm it once. Run:

```bash
docker compose exec ugreen-lights /app/lights.sh --map
```

This prints a `bay -> device -> serial` table and then lights each bay white,
one at a time, so you can watch which physical slot each LED belongs to.

If the order is wrong, switch to **serial mapping** — bulletproof, because the
LED follows the disk itself. List your serials with
`lsblk -S -o NAME,HCTL,SERIAL,MODEL`, then set in `ugreen-leds.conf` (or env):

```ini
MAPPING_METHOD=serial
DISK_SERIAL="SN_BAY1 SN_BAY2 SN_BAY3 SN_BAY4"   # left-to-right physical order
```

## Files

| File | Purpose |
|------|---------|
| [`lights.sh`](lights.sh) | The status script. One run = one full LED refresh; `--map` verifies mapping. |
| [`ugreen-leds.conf`](ugreen-leds.conf) | Optional overrides (mount at `/etc/ugreen-leds.conf`). |
| [`Dockerfile`](Dockerfile) | Builds the CLI from the submodule + runtime image. |
| [`compose.yaml`](compose.yaml) | TrueNAS deployment (device passthrough, refresh loop). |
| `ugreen_leds_controller/` | Upstream CLI/kernel-module source (git submodule). |
