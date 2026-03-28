#!/bin/bash
# Generate .env for compose.yaml and check prerequisites
#
# Run once before first 'podman compose up':
#   ./setup.sh
set -euo pipefail

# --- Preflight ---

if [ ! -S /run/seatd.sock ]; then
    echo "Error: seatd is not running. Start it with: sudo systemctl enable --now seatd" >&2
    exit 1
fi

missing=()
for grp in seat video render input; do
    id -nG | grep -qw "$grp" || missing+=("$grp")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: user $(whoami) not in groups: ${missing[*]}" >&2
    echo "  Fix: sudo usermod -aG $(IFS=,; echo "${missing[*]}") $(whoami)" >&2
    echo "  Then log out and back in." >&2
    exit 1
fi

if [ ! -d /dev/dri ]; then
    echo "Error: /dev/dri not found — no GPU available" >&2
    exit 1
fi

# --- Generate .env ---

get_gid() { getent group "$1" 2>/dev/null | cut -d: -f3; }

cat > .env <<EOF
DESKTOP_USER=$(whoami)
DESKTOP_UID=$(id -u)
DESKTOP_GID=$(id -g)
HOST_VIDEO_GID=$(get_gid video)
HOST_RENDER_GID=$(get_gid render)
HOST_INPUT_GID=$(get_gid input)
HOST_SEAT_GID=$(get_gid seat)
EOF

echo "Generated .env:"
cat .env
echo ""
echo "Ready. Run: podman compose up -d"
