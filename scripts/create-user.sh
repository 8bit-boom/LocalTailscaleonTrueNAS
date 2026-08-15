#!/usr/bin/env bash
# Create a headscale user (namespace).
# Usage: ./scripts/create-user.sh <username>
set -euo pipefail

if [[ $# -ne 1 ]]; then
	echo "Usage: $0 <username>" >&2
	exit 1
fi

docker exec headscale headscale users create "$1"
