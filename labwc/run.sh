#!/bin/bash
# Standalone KMS desktop container — build, create, start
#
# Usage:
#   ./run.sh [container-name]    Create and start (default name: desktop)
#   ./run.sh --stop [name]       Stop the container
#   ./run.sh --rm [name]         Remove the container
#   ./run.sh --shell [name]      Open a shell inside
#
# Prerequisites:
#   - Podman 5.0+
#   - seatd running: sudo systemctl enable --now seatd
#   - User in groups: sudo usermod -aG seat,input,video,render $USER
#     (log out and back in after)
#
# What this does:
#   1. Builds the container image (if not already built)
#   2. Creates a rootless podman container with systemd, GPU, input, audio
#   3. Starts the container — systemd runs the first-boot bootstrap oneshot,
#      then launches the labwc compositor
set -euo pipefail

IMAGE="localhost/desktop-kms:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Helpers ---

die() { echo "Error: $*" >&2; exit 1; }

get_host_gid() {
    getent group "$1" 2>/dev/null | cut -d: -f3
}

# --- Subcommands ---

cmd_stop() {
    local name="${1:-desktop}"
    podman stop "$name" 2>/dev/null && echo "Stopped $name" || echo "$name is not running"
}

cmd_rm() {
    local name="${1:-desktop}"
    podman rm -f "$name" 2>/dev/null && echo "Removed $name" || echo "$name does not exist"
}

cmd_shell() {
    local name="${1:-desktop}"
    exec podman exec -it --user "$(id -u)" "$name" /bin/bash
}

# --- Preflight checks ---

preflight() {
    if [ ! -S /run/seatd.sock ]; then
        die "seatd is not running. Start it with: sudo systemctl enable --now seatd"
    fi

    local missing=()
    for grp in seat video render input; do
        if ! id -nG | grep -qw "$grp"; then
            missing+=("$grp")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "User $(whoami) not in groups: ${missing[*]}
  Fix: sudo usermod -aG $(IFS=,; echo "${missing[*]}") $(whoami)
  Then log out and back in."
    fi

    if [ ! -d /dev/dri ]; then
        die "/dev/dri not found — no GPU available"
    fi
}

# --- Build image ---

build_image() {
    if podman image exists "$IMAGE" 2>/dev/null; then
        echo "Image $IMAGE already exists (use 'podman rmi $IMAGE' to rebuild)"
        return
    fi
    echo "Building $IMAGE..."
    podman build -t "$IMAGE" "$SCRIPT_DIR"
}

# --- Create container ---

create_container() {
    local name="$1"

    if podman container exists "$name" 2>/dev/null; then
        echo "Container $name already exists"
        echo "  Start:  podman start $name"
        echo "  Remove: $0 --rm $name"
        exit 1
    fi

    local host_uid host_gid host_user
    host_uid=$(id -u)
    host_gid=$(id -g)
    host_user=$(whoami)

    local video_gid render_gid input_gid seat_gid
    video_gid=$(get_host_gid video)
    render_gid=$(get_host_gid render)
    input_gid=$(get_host_gid input)
    seat_gid=$(get_host_gid seat)

    # Home directory for the container (persistent across recreates)
    local home_dir="$HOME/.local/share/desktop-kms/$name"
    mkdir -p "$home_dir"

    echo "Creating container $name..."
    echo "  User: $host_user ($host_uid:$host_gid)"
    echo "  Home: $home_dir"

    # KVM/virtio-gpu tuning: pixman avoids virgl fence round-trips (~27x faster
    # than gles2); virtio-gpu lacks hardware cursor planes and has limited
    # modifier support. Remove these on bare metal.
    local kvm_env=(
        -e "WLR_RENDERER=pixman"
        -e "WLR_NO_HARDWARE_CURSORS=1"
        -e "WLR_DRM_NO_MODIFIERS=1"
    )

    # Collect --device flags for input (keyboards, mice, tablets)
    local input_devices=()
    input_devices+=(--device /dev/input)
    [ -e /dev/uinput ] && input_devices+=(--device /dev/uinput)
    for dev in /dev/hidraw*; do
        [ -e "$dev" ] && input_devices+=(--device "$dev")
    done

    podman create \
        --name "$name" \
        --hostname "$name" \
        --systemd=always \
        --network=host \
        --uidmap "+$host_uid:@$host_uid:1" \
        --gidmap "+$host_gid:@$host_gid:1" \
        --group-add=keep-groups \
        \
        --shm-size=2g \
        --security-opt=label=disable \
        \
        --cap-drop=ALL \
        --cap-add=CHOWN \
        --cap-add=DAC_OVERRIDE \
        --cap-add=FOWNER \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=FSETID \
        --cap-add=KILL \
        --cap-add=NET_BIND_SERVICE \
        --cap-add=SETFCAP \
        --cap-add=SETPCAP \
        --cap-add=SYS_CHROOT \
        --cap-add=SYS_NICE \
        \
        --device=/dev/dri \
        "${input_devices[@]}" \
        --device=/dev/snd \
        $([ -e /dev/udmabuf ] && echo --device=/dev/udmabuf) \
        \
        -v /run/seatd.sock:/run/seatd.sock \
        -v /run/udev:/run/udev:ro \
        -v "$home_dir:/home/$host_user" \
        \
        -e "CONTAINER_USER=$host_user" \
        -e "CONTAINER_UID=$host_uid" \
        -e "CONTAINER_GID=$host_gid" \
        -e "HOST_VIDEO_GID=${video_gid}" \
        -e "HOST_RENDER_GID=${render_gid}" \
        -e "HOST_INPUT_GID=${input_gid}" \
        -e "HOST_SEAT_GID=${seat_gid}" \
        \
        "${kvm_env[@]}" \
        \
        "$IMAGE"
}

# --- Main ---

case "${1:-}" in
    --stop)  cmd_stop "${2:-desktop}"; exit ;;
    --rm)    cmd_rm "${2:-desktop}"; exit ;;
    --shell) cmd_shell "${2:-desktop}"; exit ;;
    --help|-h)
        sed -n '2,/^set /{ /^#/s/^# \?//p }' "$0"
        exit ;;
esac

NAME="${1:-desktop}"

preflight
build_image
create_container "$NAME"

echo ""
echo "Starting $NAME..."
podman start "$NAME"

echo ""
echo "Desktop is running. Switch to it with Ctrl+Alt+F2 (or another free VT)."
echo ""
echo "  Shell:   $0 --shell $NAME"
echo "  Stop:    $0 --stop $NAME"
echo "  Remove:  $0 --rm $NAME"
echo "  Restart: podman start $NAME"
