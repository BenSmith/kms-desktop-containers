# KMS Desktop Containers

Run a full Wayland desktop inside a rootless podman container, driving your
monitor directly via KMS/DRM. No host compositor, display manager, or Wayland/X
installation needed.

The container runs labwc (a wlroots compositor) with systemd as PID 1, waybar,
foot terminal, PipeWire audio, and Xwayland for X11 app compatibility.

## Variants

### [labwc-compose](labwc-compose/)

Declarative setup using `podman compose`. A `compose.yaml` defines all container
flags and a `setup.sh` generates the `.env` with your UID/GID and device group
IDs. The desktop user is created at first boot from those values.

```bash
./setup.sh
podman compose up -d
```

### [labwc-script](labwc-script/)

Single shell script (`run.sh`) that builds the image, creates the container with
the right podman flags, bootstraps the user, and starts it. More explicit — you
can read exactly what it does.

```bash
./run.sh my-desktop
```

## Prerequisites

- Podman 5.0+
- seatd running on the host: `sudo systemctl enable --now seatd`
- User in groups: `sudo usermod -aG seat,input,video,render $USER` (log out/in after)
- GPU with KMS support (`/dev/dri` present)

## User namespace design

These containers use rootless podman with a dual UID mapping instead of
`--userns=keep-id`:

```
Default rootless:  container UID 0   → host UID 1000  (the calling user)
Added via +uidmap: container UID 1000 → host UID 1000  (same host UID)
```

This means systemd (PID 1) runs as **UID 0 inside the container** — normal init
behavior with full capability management. The desktop user runs as **UID 1000**,
which also maps to the same host UID, so bind-mounted home directory files have
correct ownership in both contexts.

On first boot a oneshot root service (`container-bootstrap.service`) creates the
desktop user account from `CONTAINER_USER/UID/GID` environment variables, sets
up passwordless sudo, and creates named supplementary groups for video/render/input.
The compositor service then uses `setpriv --reuid --regid --keep-groups` to drop
from root to the desktop user while preserving the host device GIDs inherited via
`--group-add=keep-groups`.

## GPU support

The images include the full Mesa driver stack (OpenGL + Vulkan):

| GPU | Status |
|---|---|
| AMD (GCN / RDNA) | Works out of the box |
| Intel (Haswell+, Arc) | Works out of the box |
| NVIDIA (Nouveau) | Basic 3D, no reclocking — limited performance |
| NVIDIA (proprietary) | Not supported — requires a separate image with the NVIDIA driver |

## Capabilities

All capabilities are dropped, then only the needed ones are added back:

| Capability | Why |
|---|---|
| `CHOWN` | Bootstrap: `chown` home directory and runtime dir to desktop user |
| `DAC_OVERRIDE` | Bootstrap: write to `/etc/sudoers.d`, `/etc/passwd` as root |
| `FOWNER` | Bootstrap: set ownership of files not owned by the process |
| `SETUID` | Bootstrap: `useradd`; compositor: `setpriv --reuid` |
| `SETGID` | Bootstrap: `groupadd`; compositor: `setpriv --regid` |
| `FSETID` | systemd: preserve setuid/setgid bits during file operations |
| `KILL` | systemd: send signals to managed services |
| `NET_BIND_SERVICE` | systemd: bind to privileged ports if needed |
| `SETFCAP` | systemd: set file capabilities |
| `SETPCAP` | systemd: modify process capabilities |
| `SYS_CHROOT` | systemd: `chroot()` for service isolation |
| `SYS_NICE` | Compositor: scheduling priority for smooth rendering |

## Embedded files in the Containerfile

The Containerfile inlines all configuration as heredocs so the image is
self-contained. Here's what each one does:

### `/etc/xdg/labwc/rc.xml` — Compositor config

Labwc window manager settings: Adwaita theme with rounded corners, keybindings
(Super+Return for terminal, Super+d for launcher, Super+q to close, Super+f
for fullscreen, Super+Escape to exit, Alt+Tab to switch), default mouse
behavior, and center placement policy so windows don't spawn under waybar.

### `/etc/xdg/foot/foot.ini` — Terminal config

Sets Fira Code as the terminal font at 14pt.

### `/etc/xdg/labwc/autostart` — Compositor autostart script

Runs when labwc starts. Launches swaybg (solid background), waybar (status
bar), and the PipeWire audio stack. The audio section detects the first analog
ALSA card via `aplay -l`, writes a PipeWire sink config that bypasses SPA's
broken udev enumeration, starts pipewire/wireplumber/pipewire-pulse, and
unmutes the ALSA master channel.

### `/etc/xdg/waybar/config` — Status bar config

Top bar with an app launcher button (fuzzel), a taskbar showing open windows,
CPU usage, RAM usage, and a clock.

### `/etc/systemd/system/systemd-journald.service.d/10-container.conf` — journald drop-in

Clears all sandbox directives (`CapabilityBoundingSet`, `ProtectClock`,
`RestrictNamespaces`, `SystemCallFilter`, etc.) from journald's service. These
require capabilities that don't exist inside a user namespace — without this
drop-in, journald fails to start.

### `/usr/lib/systemd/system/labwc.service` — Compositor service

Started by systemd on boot. `ExecStartPre` fixes XDG_RUNTIME_DIR ownership
(the tmpfs is fresh each boot). `ExecStart` uses `setpriv --reuid --regid
--keep-groups` to drop from root to the container user without calling
`setgroups()`, which would wipe the inherited host device GIDs (video, render,
input, seat). Launches labwc under `dbus-run-session` so PipeWire and other
D-Bus consumers work. Uses `PassEnvironment` to read UID/GID/USER from the
compose environment rather than an intermediate file.

### `/usr/local/bin/container-bootstrap` — First-boot setup script

Run once by `container-bootstrap.service` (guarded by
`ConditionPathExists=!/etc/container-bootstrapped`). Creates the container user
and group matching the host UID/GID, creates named supplementary groups for
video/render/input so `id` shows names instead of numbers, sets up passwordless
sudo, and writes a colored shell prompt. Reads all values from environment
variables passed through systemd's `PassEnvironment`.

### `/usr/lib/systemd/system/container-bootstrap.service` — Bootstrap service unit

Oneshot service that runs the bootstrap script on first boot only, then touches
`/etc/container-bootstrapped` to prevent re-running. Ordered before
`labwc.service` so the user exists before the compositor tries to drop
privileges.

### Symlinks: udevd masking

`systemd-udevd.service`, `systemd-udevd-control.socket`, and
`systemd-udevd-kernel.socket` are symlinked to `/dev/null`. The host's udev
database is bind-mounted at `/run/udev:ro` — a running udevd inside the
container would conflict with it.

---

# Limitations

## Unknown limitations

There may be many, it's a new experiment.

## Known limitations

### Not designed for nested containers
The container is designed to run as a rootless podman container.

### NVIDIA proprietary drivers

Haven't tried it yet.

### SPA/udev audio enumeration

PipeWire's SPA ALSA plugin uses udev to enumerate sound cards, but podman's
`/dev` tmpfs doesn't match the host udev database. Sound cards appear as
"unavailable" to SPA even though direct ALSA access works fine. The workaround
is baked into the image: the autostart script detects the ALSA card via
`aplay -l` and writes an explicit PipeWire sink config, bypassing udev
enumeration entirely. This means only the first detected analog output is
configured — if you have multiple sound cards, you may need to adjust the
autostart script.

### Container recreate loses state

The first-boot bootstrap (user creation, sudo, groups) writes to the container
filesystem. If you `podman rm` and recreate the container, the bootstrap runs
again — this is fine for a fresh start but means any system-level customizations
(installed packages, modified configs outside the home volume) are lost. The home
directory is persistent (named volume in compose, host bind mount in standalone).

### No host PipeWire/PulseAudio forwarding

These containers run their own PipeWire stack internally, driving ALSA directly.
They do not connect to a host PipeWire or PulseAudio session. This is by design
for KMS containers (there's typically no host desktop session to forward from),
but it means audio from the container and audio from a host session (if one
exists on another VT) will conflict over the ALSA device.

### Input device hot-plug

Input devices (`/dev/input/*`) are passed through at container creation time.
Devices plugged in after the container starts won't be visible inside. Restart
the container to pick up new devices.

### Single monitor assumed

The labwc config uses `<output name="*">` which applies to all outputs, but the
setup has only been tested with a single monitor. Multi-monitor should work
(wlroots handles it) but may need config adjustments.
