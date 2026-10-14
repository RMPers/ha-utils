#!/usr/bin/env bash
#
# ha-backup.sh — Back up the Home Assistant config bind-mount into a dated structure.
#
# The HA config lives on the host (CONFIG_DIR, default /srv/homeassistant/config)
# and is bind-mounted into the incus container at /config. An incus container
# snapshot does NOT capture this directory, so this script copies it host-side.
#
# Backups are stored as:
#   <BACKUP_ROOT>/<YYYY>/<MM>/ha-config_<YYYY-MM-DD_HHMMSS>.tar.gz
# plus a matching .manifest.txt and a .sha256 checksum for each archive.
#
# Usage:
#   ha-backup.sh [--no-db] [--stop] [--keep N] [--dry-run] [--list] [--help]
#
#   --no-db     Exclude the recorder database (home-assistant_v2.db*). Smaller/faster.
#   --stop      Stop the container during backup for a guaranteed-consistent copy,
#               then start it again afterwards. Causes brief HA downtime.
#   --keep N    Keep the N most recent backups, prune older ones. Default: 14.
#   --dry-run   Show what would happen without creating or deleting anything.
#   --list      List existing backups and exit.
#   --help      Show this help.
#
# Restore (manual):
#   1) incus stop <CT_NAME>
#   2) mv <CONFIG_DIR> <CONFIG_DIR>.broken-$(date +%s)
#   3) mkdir -p <CONFIG_DIR>
#   4) tar -C "$(dirname <CONFIG_DIR>)" -xzf <chosen-archive>.tar.gz
#   5) incus start <CT_NAME>
#
# Exit codes: 0 ok, 1 usage/precondition error, 2 backup failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

KEEP=14
LOG_FILE="$LOG_DIR/ha-backup.log"

# Parent of CONFIG_DIR and the final path component (e.g. "/srv/homeassistant" + "config")
SOURCE_PARENT="$(dirname "$CONFIG_DIR")"
SOURCE_DIR="$(basename "$CONFIG_DIR")"

# Transient paths always excluded (relative to SOURCE_PARENT).
EXCLUDES_ALWAYS=(
  "$SOURCE_DIR/home-assistant.log"
  "$SOURCE_DIR/home-assistant.log.*"
  "$SOURCE_DIR/home-assistant.log.fault"
  "$SOURCE_DIR/.ha_run.lock"
  "$SOURCE_DIR/backups"          # HA's own automatic backups; captured directly already
  "$SOURCE_DIR/*.db-shm"         # recreated by SQLite; only meaningful while running
)
EXCLUDES_DB=(
  "$SOURCE_DIR/home-assistant_v2.db"
  "$SOURCE_DIR/home-assistant_v2.db-wal"
  "$SOURCE_DIR/home-assistant_v2.db-shm"
)

NO_DB=0; STOP=0; DRY_RUN=0; LIST=0

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-db)   NO_DB=1 ;;
    --stop)    STOP=1 ;;
    --keep)    shift; KEEP="${1:?--keep needs a number}" ;;
    --dry-run) DRY_RUN=1 ;;
    --list)    LIST=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift || true
done

[[ -d "$CONFIG_DIR" ]] || die "source $CONFIG_DIR does not exist."
mkdir -p "$BACKUP_ROOT"

if [[ "$LIST" -eq 1 ]]; then
  echo "Backups under $BACKUP_ROOT:"
  find "$BACKUP_ROOT" -type f -name 'ha-config_*.tar.gz' \
    -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' 2>/dev/null | sort || echo "  (none)"
  exit 0
fi

TAR_EXCLUDES=()
for e in "${EXCLUDES_ALWAYS[@]}"; do TAR_EXCLUDES+=( "--exclude=$e" ); done
if [[ "$NO_DB" -eq 1 ]]; then
  for e in "${EXCLUDES_DB[@]}"; do TAR_EXCLUDES+=( "--exclude=$e" ); done
fi

TS="$(date '+%Y-%m-%d_%H%M%S')"
Y="$(date '+%Y')"; M="$(date '+%m')"
DEST_DIR="$BACKUP_ROOT/$Y/$M"
ARCHIVE="$DEST_DIR/ha-config_${TS}.tar.gz"
MANIFEST="$DEST_DIR/ha-config_${TS}.manifest.txt"
CHECKSUM="$DEST_DIR/ha-config_${TS}.sha256"

log "=== Backup start (no_db=$NO_DB stop=$STOP keep=$KEEP dry_run=$DRY_RUN) ==="
log "Source : $CONFIG_DIR"
log "Target : $ARCHIVE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[dry-run] tar ${TAR_EXCLUDES[*]} -C $SOURCE_PARENT -czf $ARCHIVE $SOURCE_DIR"
  log "[dry-run] Would keep newest $KEEP backups and prune older."
  exit 0
fi

mkdir -p "$DEST_DIR"

STOPPED=0
restart_if_needed() {
  if [[ "$STOPPED" -eq 1 ]]; then
    log "Starting container $CT_NAME ..."
    incus start "$CT_NAME" || log "WARNING: failed to start $CT_NAME — start it manually!"
  fi
}
trap restart_if_needed EXIT

if [[ "$STOP" -eq 1 ]]; then
  if container_exists; then
    log "Stopping container $CT_NAME for consistent copy ..."
    incus stop "$CT_NAME"; STOPPED=1
  else
    log "WARNING: container $CT_NAME not found; proceeding on live files."
  fi
fi

if tar "${TAR_EXCLUDES[@]}" --ignore-failed-read \
      -C "$SOURCE_PARENT" -czf "$ARCHIVE" "$SOURCE_DIR"; then
  log "Archive written: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
else
  rc=$?; log "ERROR: tar failed (rc=$rc). Removing partial archive."; rm -f "$ARCHIVE"; exit 2
fi

if ! gzip -t "$ARCHIVE" 2>/dev/null; then
  log "ERROR: gzip integrity check failed for $ARCHIVE"; rm -f "$ARCHIVE"; exit 2
fi
log "Integrity check (gzip -t) passed."

{
  echo "backup_timestamp : $TS"
  echo "host             : $(hostname)"
  echo "source           : $CONFIG_DIR"
  echo "container        : $CT_NAME"
  echo "included_db      : $([[ $NO_DB -eq 1 ]] && echo no || echo yes)"
  echo "container_stopped: $([[ $STOP -eq 1 ]] && echo yes || echo no)"
  echo "ha_version       : $(ha_version)"
  echo "archive_bytes    : $(stat -c '%s' "$ARCHIVE")"
  echo "file_count       : $(tar -tzf "$ARCHIVE" | wc -l)"
} > "$MANIFEST"
sha256sum "$ARCHIVE" | sed "s#$DEST_DIR/##" > "$CHECKSUM"
log "Manifest : $MANIFEST"
log "Checksum : $CHECKSUM"

restart_if_needed; STOPPED=0; trap - EXIT

mapfile -t ALL < <(find "$BACKUP_ROOT" -type f -name 'ha-config_*.tar.gz' | sort)
COUNT="${#ALL[@]}"
if (( COUNT > KEEP )); then
  PRUNE=$(( COUNT - KEEP ))
  log "Pruning $PRUNE old backup(s) (keeping newest $KEEP of $COUNT)."
  for (( i=0; i<PRUNE; i++ )); do
    f="${ALL[$i]}"; base="${f%.tar.gz}"
    log "  removing $f (+ manifest/checksum)"
    rm -f "$f" "${base}.manifest.txt" "${base}.sha256"
  done
  find "$BACKUP_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
else
  log "Retention OK ($COUNT backup(s), keep=$KEEP). Nothing to prune."
fi

log "=== Backup done ==="
echo "$ARCHIVE"
