# ha-utils

Small toolkit for managing a **Home Assistant Core** instance running as an
**incus OCI container** (image `ghcr.io/home-assistant/home-assistant`), with the
HA config bind-mounted from the host.

Because this is the *Core* image (no Supervisor), the HA GUI's update button does
**not** update the core, and an `incus snapshot` does **not** back up the config
(it lives on a host bind mount). These scripts fill both gaps.

## Scripts

| Script | Purpose |
|--------|---------|
| `setup.sh`     | Create the incus container (one-time, from the stable image). |
| `ha-backup.sh` | Back up the host config dir into a dated `.tar.gz` structure, with checksum + manifest and retention. |
| `ha-update.sh` | List available HA images and safely upgrade/rollback via `incus rebuild`. |
| `install.sh`   | Symlink the scripts into `/usr/local/bin` and optionally install a weekly backup cron. |

All scripts run **on the host** and share defaults from `lib/common.sh`
(override via env vars or `/etc/ha-utils.conf`).

## Install (on the host)

```bash
git clone <this-repo> ha-utils && cd ha-utils
sudo ./install.sh --cron      # symlinks + weekly backup cron (Sun 03:30)
```

## Backups

```bash
ha-backup                 # full config incl. recorder DB
ha-backup --no-db         # skip the DB (smaller/faster)
ha-backup --stop          # stop container during copy (consistent DB)
ha-backup --list          # list existing backups
ha-backup --keep 30       # change retention
```

Output: `BACKUP_ROOT/YYYY/MM/ha-config_<timestamp>.tar.gz` (+ `.sha256`, `.manifest.txt`).
HA's own internal `config/backups` folder and transient logs/locks are excluded.

### Restore
```bash
incus stop homeassistant
mv /srv/homeassistant/config /srv/homeassistant/config.broken-$(date +%s)
mkdir -p /srv/homeassistant/config
tar -C /srv/homeassistant -xzf <archive>.tar.gz    # recreates config/
incus start homeassistant
```

## Updates

Staying current **without** taking betas: the container tracks the `stable`
image tag, so it never pulls a beta on its own. You update deliberately when you
choose, ideally after a monthly release has a patch or two (`.2`/`.3`).

```bash
ha-update current                 # show running version + image tag
ha-update list                    # newest stable versions (betas hidden)
ha-update list --beta             # include recent betas
ha-update upgrade 2026.9.4        # backup -> rebuild -> health check (prompts)
ha-update upgrade stable --yes    # move to latest stable, no prompt
ha-update rollback                # rebuild back to pre-upgrade version
```

`upgrade` always runs a backup first, records the previous version for rollback,
then uses `incus rebuild` (which preserves the container config and the `/config`
bind mount — your data is never on the disposable root disk). Beta targets are
refused unless `--allow-beta` is given.

## Configuration

Defaults live in `lib/common.sh`. Override via environment or `/etc/ha-utils.conf`:

```sh
# /etc/ha-utils.conf
CT_NAME=homeassistant
CONFIG_DIR=/srv/homeassistant/config
BACKUP_ROOT=/srv/homeassistant/backups-host
OCI_REMOTE=ghcr
OCI_IMAGE=home-assistant/home-assistant
```

## Notes / caveats

- Custom integrations (HACS) can require a newer HA than the stable core; check an
  integration's HA minimum before updating it. Conversely, update the core to the
  needed stable release before taking such integration updates.
- `ha-update` requires `incus` >= a version with the `rebuild` subcommand (6.x).
- Registry tag listing uses the ghcr.io anonymous pull API via `python3`.
