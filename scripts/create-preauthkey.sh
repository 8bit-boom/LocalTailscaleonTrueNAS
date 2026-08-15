#!/usr/bin/env bash
# Generate a pre-auth key so a device can join without an interactive login.
# Usage: ./scripts/create-preauthkey.sh <username> [--reusable] [--ephemeral] [--expiration 24h]
set -euo pipefail

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <username> [extra headscale flags...]" >&2
	exit 1
fi

user="$1"
shift

docker exec headscale headscale preauthkeys create --user "$user" "$@"
