# shellcheck shell=bash
# common.sh — shared defaults and helpers for ha-utils.
# Sourced by the other scripts; not executable on its own.
#
# All values can be overridden via environment variables or an optional
# config file at /etc/ha-utils.conf (or ./ha-utils.conf next to the repo).

# ------------------------------- Defaults ------------------------------------
: "${CT_NAME:=homeassistant}"                       # incus container name
: "${CONFIG_DIR:=/srv/homeassistant/config}"        # host path bind-mounted to /config
: "${OCI_REMOTE:=ghcr}"                              # incus remote for the image
: "${OCI_IMAGE:=home-assistant/home-assistant}"     # image repository (no tag)
: "${REGISTRY_HOST:=ghcr.io}"                        # registry for tag queries
: "${BACKUP_ROOT:=/srv/homeassistant/backups-host}" # where ha-backup.sh writes
: "${LOG_DIR:=/var/log}"                             # log directory

# ------------------------------- Config file ---------------------------------
# Load overrides if present (later wins).
for _cfg in /etc/ha-utils.conf "$(dirname "${BASH_SOURCE[0]}")/../ha-utils.conf"; do
  if [[ -f "$_cfg" ]]; then
    # shellcheck disable=SC1090
    source "$_cfg"
  fi
done

# ------------------------------- Logging -------------------------------------
# Usage: log "message"  — timestamped to stderr and (if writable) to $LOG_FILE.
: "${LOG_FILE:=$LOG_DIR/ha-utils.log}"
log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  if [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]] 2>/dev/null; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
  else
    printf '%s\n' "$line" >&2
  fi
}
die() { log "ERROR: $*"; exit 1; }

# ------------------------------- Helpers -------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

ensure_incus() {
  need_cmd incus
  incus info >/dev/null 2>&1 || die "Incus daemon not reachable (try: incus admin init)."
}

container_exists() {
  incus list -f csv -c n 2>/dev/null | grep -Fxq "$CT_NAME"
}

# Echo the host path currently bound to the container's /config device, if any.
container_config_source() {
  incus config device show "$CT_NAME" 2>/dev/null \
    | awk '/^[a-zA-Z0-9_-]+:$/{dev=$1} dev=="config:" && /^[[:space:]]+source:/{print $2; exit}'
}

# Echo the image tag the container was created from (best effort).
container_image_tag() {
  incus config get "$CT_NAME" image.id 2>/dev/null \
    || incus config show "$CT_NAME" 2>/dev/null | awk -F'image.id: ' '/image.id:/{print $2; exit}'
}

# Echo the HA version recorded in the config dir, if readable.
ha_version() {
  cat "$CONFIG_DIR/.HA_VERSION" 2>/dev/null || echo "unknown"
}

# Confirm prompt. Returns 0 if confirmed. Honors ASSUME_YES=1.
confirm() {
  local prompt="${1:-Proceed?} [y/N] "
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  local ans
  read -r -p "$prompt" ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}
