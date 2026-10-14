#!/usr/bin/env bash
#
# ha-update.sh — List available Home Assistant Core images and safely upgrade.
#
# This HA install is the Core OCI image run under incus (no Supervisor), so the
# in-GUI update button does NOT update the core. Updating means re-basing the
# container onto a newer image with `incus rebuild`, which preserves the
# container config and devices (including the /config bind mount). Your data
# lives on the host at CONFIG_DIR, so a rebuild never touches it.
#
# Commands:
#   ha-update.sh list    [--all|--beta] [--limit N]
#   ha-update.sh upgrade <version|stable> [--allow-beta] [--yes] [--no-db] [--dry-run]
#   ha-update.sh rollback                 [--yes]
#   ha-update.sh current
#   ha-update.sh --help
#
# list     Query the registry and show available stable versions (newest first).
#          Default shows stable YYYY.MM.PATCH only. --all/--beta include betas.
# upgrade  Back up, then rebuild the container onto the chosen image, then health
#          check. Refuses beta targets unless --allow-beta. Prompts unless --yes.
# rollback Rebuild back to the version recorded before the last upgrade.
# current  Show the currently running version and image tag.
#
# Exit codes: 0 ok, 1 usage/precondition, 2 upgrade/health failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG_FILE="$LOG_DIR/ha-update.log"
STATE_FILE="${STATE_FILE:-/var/lib/ha-utils/state.env}"   # records last-good version
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"                    # seconds to wait for HA

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

# --------------------------- Registry tag query ------------------------------
# Prints all tags (one per line) by following pagination Link headers.
registry_tags() {
  need_cmd python3
  python3 - "$REGISTRY_HOST" "$OCI_IMAGE" <<'PY'
import json, sys, urllib.request, re
host, image = sys.argv[1], sys.argv[2]
def get(url, hdr=None):
    req = urllib.request.Request(url, headers=hdr or {})
    r = urllib.request.urlopen(req, timeout=25)
    return r, r.read().decode()
# anonymous pull token
_, body = get(f"https://{host}/token?scope=repository:{image}:pull")
tok = json.loads(body)["token"]
hdr = {"Authorization": "Bearer " + tok}
url = f"https://{host}/v2/{image}/tags/list?n=1000"
seen = []
while url:
    r, body = get(url, hdr)
    seen += json.loads(body).get("tags", [])
    link = r.headers.get("Link")
    if link and 'rel="next"' in link:
        m = re.search(r'<([^>]+)>', link)
        nxt = m.group(1) if m else None
        url = (f"https://{host}" + nxt) if nxt and nxt.startswith("/") else nxt
    else:
        url = None
for t in seen:
    print(t)
PY
}

# version sort helper (semver-ish YYYY.MM.PATCH)
_sort_versions() { sort -t. -k1,1n -k2,2n -k3,3n; }

cmd_list() {
  local include_beta=0 limit=15
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|--beta) include_beta=1 ;;
      --limit) shift; limit="${1:?--limit needs a number}" ;;
      *) die "list: unknown option $1" ;;
    esac; shift || true
  done

  local cur; cur="$(ha_version)"
  echo "Current running version: $cur"
  echo "Channel tags:"
  printf '  %s\n' "stable  (latest stable, recommended)" "beta    (pre-release)" "dev     (nightly)"
  echo

  local all stable betas
  all="$(registry_tags)" || die "Could not query registry $REGISTRY_HOST/$OCI_IMAGE"
  stable="$(printf '%s\n' "$all" | grep -E '^20[0-9]{2}\.[0-9]+\.[0-9]+$' | _sort_versions)"

  echo "Latest $limit stable versions (newest last):"
  printf '%s\n' "$stable" | tail -n "$limit" | while read -r v; do
    if [[ "$v" == "$cur" ]]; then echo "  $v   <-- current"; else echo "  $v"; fi
  done

  if [[ "$include_beta" -eq 1 ]]; then
    betas="$(printf '%s\n' "$all" | grep -E '^20[0-9]{2}\.[0-9]+\.[0-9]+b[0-9]+$' | sort | tail -n 10)"
    echo
    echo "Recent beta versions:"
    printf '%s\n' "$betas" | sed 's/^/  /'
  fi
  echo
  echo "To upgrade:  ha-update.sh upgrade <version>   (e.g. ha-update.sh upgrade ${stable##*$'\n'})"
}

cmd_current() {
  ensure_incus
  echo "Container      : $CT_NAME"
  echo "Image tag      : $(container_image_tag)"
  echo "Config source  : $(container_config_source)"
  echo "Running version: $(ha_version)"
}

# ------------------------------- Upgrade -------------------------------------
cmd_upgrade() {
  local target="" allow_beta=0 dry=0 no_db=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-beta) allow_beta=1 ;;
      --yes|-y)     ASSUME_YES=1 ;;
      --no-db)      no_db=1 ;;
      --dry-run)    dry=1 ;;
      -*)           die "upgrade: unknown option $1" ;;
      *)            target="$1" ;;
    esac; shift || true
  done
  [[ -n "$target" ]] || die "upgrade: specify a version or 'stable' (see: ha-update.sh list)"

  # Validate target FIRST (cheap, logically prior) — refuse betas unless opted in.
  if [[ "$target" =~ ^20[0-9]{2}\.[0-9]+\.[0-9]+b[0-9]+$ ]] && [[ "$allow_beta" -ne 1 ]]; then
    die "'$target' is a beta. Re-run with --allow-beta if you really want it."
  fi
  if [[ "$target" == "beta" || "$target" == "dev" ]] && [[ "$allow_beta" -ne 1 ]]; then
    die "channel '$target' includes pre-releases. Re-run with --allow-beta to proceed."
  fi

  ensure_incus
  container_exists || die "container $CT_NAME not found."

  # (target already validated above)

  local image="$OCI_REMOTE:$OCI_IMAGE:$target"
  local cur_ver cur_tag; cur_ver="$(ha_version)"; cur_tag="$(container_image_tag)"

  log "=== Upgrade requested: $cur_ver ($cur_tag) -> $target ==="
  echo "Container      : $CT_NAME"
  echo "Current version: $cur_ver   (image tag: $cur_tag)"
  echo "Target image   : $image"
  echo "Config (safe)  : $(container_config_source)  [bind mount, preserved by rebuild]"
  echo

  if [[ "$dry" -eq 1 ]]; then
    log "[dry-run] ha-backup.sh $([[ $no_db -eq 1 ]] && echo --no-db)"
    log "[dry-run] incus rebuild -f $image $CT_NAME"
    log "[dry-run] health check up to ${HEALTH_TIMEOUT}s"
    exit 0
  fi

  confirm "Proceed with backup + rebuild to '$target'?" || { log "Aborted by user."; exit 1; }

  # 1) Mandatory backup
  log "Running pre-upgrade backup ..."
  if [[ "$no_db" -eq 1 ]]; then
    "$SCRIPT_DIR/ha-backup.sh" --no-db >/dev/null || die "Backup failed — aborting upgrade."
  else
    "$SCRIPT_DIR/ha-backup.sh" >/dev/null || die "Backup failed — aborting upgrade."
  fi
  log "Backup complete."

  # 2) Record rollback target
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
  {
    echo "PREV_VERSION=$cur_ver"
    echo "PREV_IMAGE_TAG=$cur_tag"
    echo "UPGRADED_AT=$(date -Iseconds)"
    echo "TARGET=$target"
  } > "$STATE_FILE" 2>/dev/null || log "WARNING: could not write state file $STATE_FILE"

  # 3) Rebuild (pulls new image, wipes root disk, keeps config+devices)
  log "Rebuilding $CT_NAME onto $image ..."
  if ! incus rebuild -f "$image" "$CT_NAME"; then
    die "incus rebuild failed. Container config/devices are intact; your data is safe on the host. You may retry or run: ha-update.sh rollback"
  fi

  # 4) Ensure running
  incus start "$CT_NAME" 2>/dev/null || true

  # 5) Health check
  if health_check; then
    log "Upgrade OK. New version: $(ha_version)"
    echo
    echo "Upgrade succeeded: $cur_ver -> $(ha_version)"
  else
    log "Health check FAILED after ${HEALTH_TIMEOUT}s."
    echo
    echo "Health check failed. Options:"
    echo "  - Inspect logs:  incus exec $CT_NAME -- tail -n 100 /config/home-assistant.log"
    echo "  - Roll back:     ha-update.sh rollback"
    exit 2
  fi
}

# Poll until HA answers on 8123 inside the container, or timeout.
health_check() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  log "Health check: waiting up to ${HEALTH_TIMEOUT}s for HA to come up ..."
  while (( SECONDS < deadline )); do
    # Prefer an HTTP probe from inside the container; fall back to process check.
    if incus exec "$CT_NAME" -- sh -c \
        'wget -q -O /dev/null -T 5 http://127.0.0.1:8123/manifest.json 2>/dev/null \
         || python3 -c "import urllib.request;urllib.request.urlopen(\"http://127.0.0.1:8123/manifest.json\",timeout=5)" 2>/dev/null'; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# ------------------------------- Rollback ------------------------------------
cmd_rollback() {
  while [[ $# -gt 0 ]]; do
    case "$1" in --yes|-y) ASSUME_YES=1 ;; *) die "rollback: unknown option $1" ;; esac; shift || true
  done
  ensure_incus
  [[ -f "$STATE_FILE" ]] || die "no state file ($STATE_FILE); cannot determine rollback target."
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  local prev="${PREV_VERSION:-}"
  [[ -n "$prev" && "$prev" != "unknown" ]] || die "recorded previous version is unknown; roll back manually."
  local image="$OCI_REMOTE:$OCI_IMAGE:$prev"
  echo "Rollback target: $prev   (image: $image)"
  confirm "Rebuild $CT_NAME back to $prev?" || { log "Rollback aborted."; exit 1; }
  log "Rolling back to $prev ..."
  incus rebuild -f "$image" "$CT_NAME" || die "rollback rebuild failed."
  incus start "$CT_NAME" 2>/dev/null || true
  if health_check; then
    log "Rollback OK. Version: $(ha_version)"
    echo "Rolled back to $(ha_version)"
  else
    die "rollback health check failed — inspect: incus exec $CT_NAME -- tail -n 100 /config/home-assistant.log"
  fi
}

# ------------------------------- Dispatch ------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  list)     cmd_list "$@" ;;
  upgrade)  cmd_upgrade "$@" ;;
  rollback) cmd_rollback "$@" ;;
  current)  cmd_current "$@" ;;
  --help|-h|"") usage ;;
  *) echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
esac
