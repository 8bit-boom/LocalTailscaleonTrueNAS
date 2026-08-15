#!/usr/bin/env bash
# Snapshot the headscale database and keys into a timestamped tarball.
# Usage: ./scripts/backup.sh [backup-dir]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_dir="${1:-$script_dir/backups}"
mkdir -p "$backup_dir"

stamp="$(date +%Y%m%d-%H%M%S)"
dest="$backup_dir/headscale-$stamp.tar.gz"

tar -czf "$dest" \
	-C "$script_dir" \
	config/headscale \
	data/headscale

echo "Backup written to $dest"
