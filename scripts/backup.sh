#!/usr/bin/env bash
# Snapshot the headscale database and keys into a timestamped tarball.
# Keeps the 14 most recent backups in the destination directory.
# Usage: ./scripts/backup.sh [backup-dir]
set -euo pipefail
umask 077

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_dir="${1:-$repo_dir/backups}"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"

stamp="$(date +%Y%m%d-%H%M%S)"
dest="$backup_dir/headscale-$stamp.tar.gz"

# db.sqlite is written with write_ahead_log enabled, so tar-ing it live can
# capture an inconsistent snapshot (mid-write, with -wal/-shm not yet
# checkpointed). Ask headscale for a consistent copy first; if that
# subcommand isn't available in this version, fall back to a brief stop.
snapshot_ok=0
if docker exec headscale headscale db backup /var/lib/headscale/backup.sqlite >/dev/null 2>&1; then
	snapshot_ok=1
else
	echo "headscale has no 'db backup' subcommand; stopping it briefly for a consistent snapshot" >&2
	(cd "$repo_dir" && docker compose stop headscale)
	stopped=1
fi

tar -czf "$dest" \
	-C "$repo_dir" \
	config/headscale \
	data/headscale
chmod 600 "$dest"

if [[ "${stopped:-0}" == "1" ]]; then
	(cd "$repo_dir" && docker compose start headscale)
fi
if [[ "$snapshot_ok" == "1" ]]; then
	docker exec headscale rm -f /var/lib/headscale/backup.sqlite
fi

# Retention: keep the 14 most recent backups in this directory.
ls -1t "$backup_dir"/headscale-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm --

echo "Backup written to $dest"
echo "Contains the noise private key and full database — treat it like a root credential."
