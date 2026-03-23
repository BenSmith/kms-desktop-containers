# KMS Desktop Container (Compose)

A containerized Wayland desktop (labwc) that drives your monitor directly via
KMS/DRM (kernel mode setting) — no host compositor or display manager needed. Uses rootless podman with
systemd as PID 1, configured through `compose.yaml`. 

Use this to bring up a wayland desktop (with X support) on a system that has a gpu, monitor, keyboard, mouse, without installing Wayland or Xorg on the host. 

## Quick start

```bash
# One-time host setup
sudo systemctl enable --now seatd
sudo usermod -aG seat,input,video,render $USER
# Log out and back in for groups to take effect

# Generate .env (detects UID/GID/group IDs)
./setup.sh

# Build and run
podman compose up -d
```

Switch to the desktop with **Ctrl+Alt+F2** (or another free VT).

## Files

| File | Purpose |
|---|---|
| `Containerfile` | Image: labwc, waybar, foot, PipeWire, systemd services, bootstrap script — all inlined |
| `compose.yaml` | Podman flags: devices, capabilities, volumes, user namespace |
| `setup.sh` | Generates `.env` with host UID/GID and device group IDs |

## Usage

```bash
podman compose up -d             # start (builds image on first run)
podman compose down              # stop and remove
podman compose up -d --build     # rebuild image and start
podman exec -it --user $(id -u) desktop /bin/bash   # shell
```

## How it works

### Boot sequence

1. **`container-bootstrap.service`** (oneshot, first boot only) — creates the
   container user matching your host UID/GID, sets up supplementary groups,
   sudo, and shell prompt. Skipped on subsequent boots via
   `ConditionPathExists=!/etc/container-bootstrapped`.

2. **`labwc.service`** — `ExecStartPre` fixes XDG_RUNTIME_DIR ownership (tmpfs
   is fresh each boot), then `setpriv` drops to your user and launches
   the compositor under a D-Bus session.

### User namespace and device access

`userns_mode: keep-id` maps your host UID to the same UID inside the container.
`group_add: keep-groups` preserves your host supplementary GIDs (video, render,
input, seat) on PID 1. The labwc service uses `setpriv --keep-groups` to drop
to your user without calling `setgroups()`, which would wipe those GIDs. This is
why the service doesn't use systemd's `User=` directive.

### Audio

No host PipeWire/PulseAudio sockets are needed — audio runs entirely inside the
container. The compositor's autostart script detects the ALSA analog output card,
writes a PipeWire sink config, and starts the PipeWire stack. This bypasses SPA's
udev enumeration which fails in containers (podman's `/dev` tmpfs doesn't match
the host udev database).

### Environment passing

The compose env vars (`CONTAINER_UID`, etc.) flow into the container, where
systemd services access them via `PassEnvironment=`. No intermediate env file
is written.

## .env

`setup.sh` generates this. You can also write it by hand:

```
DESKTOP_USER=ben
DESKTOP_UID=1000
DESKTOP_GID=1000
HOST_VIDEO_GID=39
HOST_RENDER_GID=105
HOST_INPUT_GID=104
```

Find your values with:
```bash
id -u                              # DESKTOP_UID
id -g                              # DESKTOP_GID
getent group video | cut -d: -f3   # HOST_VIDEO_GID
getent group render | cut -d: -f3  # HOST_RENDER_GID
getent group input | cut -d: -f3   # HOST_INPUT_GID
```

## Keybindings

| Key | Action |
|---|---|
| Super+Return | Terminal (foot) |
| Super+d | App launcher (fuzzel) |
| Super+q | Close window |
| Super+f | Fullscreen |
| Super+Escape | Exit compositor |
| Alt+Tab | Switch window |

## Persistent home

Container home is stored in a podman named volume (`desktop-home`). Removing and
recreating the container preserves your files. To inspect or remove:

```bash
podman volume inspect desktop-home
podman volume rm desktop-home
```

## Prerequisites

- Podman 5.0+ with compose support
- seatd running on the host
- User in groups: seat, video, render, input
- GPU with KMS support (`/dev/dri` present)
