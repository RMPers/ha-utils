#!/usr/bin/env bash
set -euo pipefail

# setup-incus-homeassistant.sh
# Creates an Incus OCI container running Home Assistant Container (ghcr.io/home-assistant/home-assistant)
#
# Examples:
#   ./setup-incus-homeassistant.sh
#   ./setup-incus-homeassistant.sh --name ha --config-dir /srv/ha/config
#   ./setup-incus-homeassistant.sh --usb 10c4:ea60   # e.g. Sonoff CC2652P (example VID:PID)
#
# Notes:
# - This runs *Home Assistant Container* (not Supervised/OS).
# - HACS works fine in this setup.
# - If you need Zigbee/Z-Wave, pass the USB dongle through (or run Zigbee2MQTT separately).

CT_NAME="homeassistant"
CONFIG_DIR="/srv/homeassistant/config"
LISTEN_ADDR="0.0.0.0"
PORT="8123"
TAG="stable"                 # stable | beta | dev
TZ="Europe/Stockholm"
USB_VIDPID=""                # optional, format: vendor:product (hex), e.g. 10c4:ea60

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --name NAME            Container name (default: ${CT_NAME})
  --config-dir PATH      Host path mounted to /config (default: ${CONFIG_DIR})
  --listen-addr ADDR     Host listen address for port forward (default: ${LISTEN_ADDR})
  --port PORT            Host port to expose HA on (default: ${PORT})
  --tag TAG              Image tag: stable|beta|dev (default: ${TAG})
  --tz TZ                TZ env for HA (default: ${TZ})
  --usb VID:PID          Pass through a USB device (e.g. 10c4:ea60). Optional.
  -h, --help             Show help
EOF
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

ensure_incus_ready() {
  need_cmd incus
  # Ensure daemon is reachable
  incus info >/dev/null 2>&1 || die "Incus daemon not reachable. Run: incus admin init"
}

ensure_oci_remote() {
  # Incus typically has a 'docker:' remote for OCI images. If not, try to add it.
  if ! incus remote list -f csv 2>/dev/null | awk -F, '{print $1}' | grep -Fxq "ghcr"; then
    echo "No 'ghcr' remote found. Attempting to add ghcr.io OCI remote..."
    # Best-effort; different Incus versions may differ slightly here.
    incus remote add ghcr https://ghcr.io --protocol=oci --public >/dev/null 2>&1 \
      || die "Could not add OCI remote 'ghcr'. Add it manually, then rerun."
  fi
}

container_exists() {
  incus list -f csv -c n | grep -Fxq "$CT_NAME"
}

create_config_dir() {
  sudo mkdir -p "$CONFIG_DIR"
  # Home Assistant container can write to /config; ownership varies by tag/build.
  # Keep it permissive but not world-writable.
  sudo chmod 0755 "$CONFIG_DIR"
}

launch_ha() {
  local image="ghcr:home-assistant/home-assistant:${TAG}"

  echo "Launching ${CT_NAME} from ${image} ..."
  incus launch "$image" "$CT_NAME"

  # Persist HA config on host
  incus config device add "$CT_NAME" config disk source="$CONFIG_DIR" path=/config

  # use idmapping
  incus config device set "$CT_NAME" config shift true

  # Common runtime env
  incus config set "$CT_NAME" environment.TZ="$TZ"

  # Ensure it restarts on host reboot
  incus config set "$CT_NAME" boot.autostart=true

  # Expose the web UI to the host
  # Proxy device connects to the instance's localhost:8123.
  incus config device add "$CT_NAME" "ha-${PORT}" proxy \
    listen="tcp:${LISTEN_ADDR}:${PORT}" \
    connect="tcp:127.0.0.1:8123"

  # Optional: pass through a USB dongle (Zigbee/Z-Wave)
  if [[ -n "$USB_VIDPID" ]]; then
    local vid="${USB_VIDPID%%:*}"
    local pid="${USB_VIDPID##*:}"
    [[ "$vid" =~ ^[0-9a-fA-F]{4}$ ]] || die "--usb vendor id must be 4 hex chars (e.g. 10c4)"
    [[ "$pid" =~ ^[0-9a-fA-F]{4}$ ]] || die "--usb product id must be 4 hex chars (e.g. ea60)"
    incus config device add "$CT_NAME" zigbee usb vendorid="$vid" productid="$pid"
  fi

  echo "Done."
}

show_status() {
  echo
  incus list "$CT_NAME" -c ns4 || true
  echo
  echo "Home Assistant should be reachable at:"
  echo "  http://${LISTEN_ADDR}:${PORT}/"
  echo
  echo "Logs:"
  echo "  incus logs -f ${CT_NAME}"
}

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       CT_NAME="${2:-}"; shift 2;;
    --config-dir) CONFIG_DIR="${2:-}"; shift 2;;
    --listen-addr) LISTEN_ADDR="${2:-}"; shift 2;;
    --port)       PORT="${2:-}"; shift 2;;
    --tag)        TAG="${2:-}"; shift 2;;
    --tz)         TZ="${2:-}"; shift 2;;
    --usb)        USB_VIDPID="${2:-}"; shift 2;;
    -h|--help)    usage; exit 0;;
    *) die "Unknown argument: $1 (use --help)";;
  esac
done

[[ -n "$CT_NAME" ]] || die "--name cannot be empty"
[[ -n "$CONFIG_DIR" ]] || die "--config-dir cannot be empty"
[[ -n "$LISTEN_ADDR" ]] || die "--listen-addr cannot be empty"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
[[ "$TAG" =~ ^(stable|beta|dev)$ ]] || die "--tag must be stable|beta|dev"

ensure_incus_ready
ensure_oci_remote
create_config_dir

if container_exists; then
  echo "Container '${CT_NAME}' already exists. Not recreating."
  echo "If you want a fresh install:"
  echo "  incus delete -f ${CT_NAME}"
  echo "  sudo rm -rf ${CONFIG_DIR}"
  exit 0
fi

launch_ha
show_status
