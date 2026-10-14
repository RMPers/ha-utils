#!/usr/bin/env bash
#
# install.sh — Deploy ha-utils scripts on the host.
#
# Symlinks the scripts into /usr/local/bin so they're on PATH, and (optionally)
# installs a weekly backup cron. Run this ON THE HOST after cloning the repo.
#
# Usage:
#   sudo ./install.sh [--cron] [--prefix DIR]
#
#   --cron        Also install a weekly backup cron (Sundays 03:30, keep 14).
#   --prefix DIR  Install symlinks into DIR (default: /usr/local/bin).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="/usr/local/bin"
WITH_CRON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cron)   WITH_CRON=1 ;;
    --prefix) shift; PREFIX="${1:?--prefix needs a dir}" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac; shift || true
done

mkdir -p "$PREFIX"
for s in ha-backup.sh ha-update.sh; do
  ln -sf "$SCRIPT_DIR/$s" "$PREFIX/${s%.sh}"
  echo "linked $PREFIX/${s%.sh} -> $SCRIPT_DIR/$s"
done

if [[ "$WITH_CRON" -eq 1 ]]; then
  line="30 3 * * 0 $PREFIX/ha-backup --keep 14 >> /var/log/ha-backup.log 2>&1"
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v 'ha-backup' > "$tmp" || true
  {
    echo "# Weekly Home Assistant config backup (installed by ha-utils)"
    echo "$line"
  } >> "$tmp"
  crontab "$tmp"; rm -f "$tmp"
  echo "installed weekly backup cron: $line"
fi

echo "Done. Try: ha-update list"
