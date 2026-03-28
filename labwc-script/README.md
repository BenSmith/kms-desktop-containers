# Standalone KMS Desktop Container

A containerized Wayland desktop (labwc) that drives your monitor directly via
KMS — no host compositor or display manager needed. Uses rootless podman with
systemd as PID 1.

This is a self-contained version of what [cosy](https://github.com/BenSmith/cosy)
does with `cosy create --kms --audio`, distilled to two files with no external
dependencies beyond podman and seatd.

## Quick start

```bash
# One-time host setup
sudo systemctl enable --now seatd
sudo usermod -aG seat,input,video,render $USER
# Log out and back in for groups to take effect

# Build and run
./run.sh my-desktop
```

Switch to the desktop with **Ctrl+Alt+F2** (or another free VT).

## What it does

`run.sh` builds the image, creates the container with the right podman flags,
and starts it. Everything else happens inside via systemd:

1. **Build** — `podman build` creates a Fedora 43 image with labwc, waybar,
   foot terminal, PipeWire audio, systemd services, and a first-boot bootstrap
   script — all baked into the Containerfile.

2. **Create** — `podman create` with the flags needed for KMS:
   - `--systemd=always` — systemd as PID 1
   - `--device /dev/dri`, `/dev/input`, `/dev/snd` — GPU, input, audio
   - `/run/seatd.sock` — DRM master and VT management
   - `/run/udev:ro` — device enumeration database
   - `--uidmap "+$UID:@$UID:1" --gidmap "+$GID:@$GID:1"` — adds a mapping so
     container UID/GID 1000 resolves to the host user; systemd (PID 1) still
     runs as container root (UID 0) via the default rootless mapping
   - `--group-add=keep-groups` — supplementary GIDs (video, render, input, seat)
     preserved on PID 1 for device access
   - Environment variables with host UID/GID and device group IDs

3. **Start** — systemd boots inside the container and runs:
   - `container-bootstrap.service` (first boot only) — creates the user account,
     supplementary groups, and sudo
   - `labwc.service` — creates `/run/user/$UID` as root, then drops to the
     desktop user via `setpriv --keep-groups` and launches the compositor

## Keybindings

| Key | Action |
|---|---|
| Super+Return | Terminal (foot) |
| Super+d | App launcher (fuzzel) |
| Super+q | Close window |
| Super+f | Fullscreen |
| Super+Escape | Exit compositor |
| Alt+Tab | Switch window |

## Audio

Audio is handled inside the container (no host PipeWire/PulseAudio needed).
The compositor's autostart script detects the ALSA analog output card, writes a
PipeWire sink config, and starts the PipeWire stack. This bypasses SPA's udev
enumeration which fails in containers.

## Persistent home

Container home is stored at `~/.local/share/desktop-kms/<name>/` on the host.
Removing and recreating the container preserves your files.

## Commands

```bash
./run.sh [name]          # Create and start (default: desktop)
./run.sh --shell [name]  # Open a shell inside
./run.sh --stop [name]   # Stop
./run.sh --rm [name]     # Remove
podman start [name]      # Restart a stopped container
```

## How setpriv + keep-groups works

The compositor must run as a regular user (not root), but it also needs access
to host device groups (video, render, input, seat). Podman's `--group-add
keep-groups` passes your host supplementary GIDs to PID 1. The labwc systemd
service uses `setpriv --reuid --regid --keep-groups` to drop to your user
without calling `setgroups()`, which would wipe those GIDs. This is why the
service doesn't use systemd's `User=` directive.

## Customization

All configs are inlined in the Containerfile. To customize, edit the heredocs
and rebuild:

- **Keybindings / theme** — the `rc.xml` block
- **Autostart programs** — the `autostart` block
- **Status bar** — the waybar `config` block
- **Packages** — the `dnf install` list
