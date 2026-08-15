#!/usr/bin/env bash
# Generate a pre-auth key so a device can join without an interactive login.
# Plain keys are single-use and expire on their own — prefer those. Only
# add --reusable for scripted bulk enrollment of many devices, and expire
# it immediately after (`headscale preauthkeys expire`): a leaked reusable
# key admits unlimited devices as that user for as long as it's valid.
# Usage: ./scripts/create-preauthkey.sh <username> [--expiration 1h] [--ephemeral]
set -euo pipefail

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <username> [extra headscale flags...]" >&2
	exit 1
fi

user="$1"
shift

docker exec headscale headscale preauthkeys create --user "$user" "$@"
