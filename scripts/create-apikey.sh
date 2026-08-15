#!/usr/bin/env bash
# Generate an API key for headscale-admin (or any other tool that talks to
# headscale's REST API). Paste the output into headscale-admin's Settings
# page. This is a root-equivalent credential for your tailnet (headscale
# has no read-only or scoped keys), so it defaults to a short 30-day
# expiration unless you override it.
# Usage: ./scripts/create-apikey.sh [--expiration 7d]
set -euo pipefail

args=("$@")
has_expiration=0
for arg in "${args[@]}"; do
	[[ "$arg" == --expiration* ]] && has_expiration=1
done
[[ "$has_expiration" -eq 0 ]] && args+=(--expiration 30d)

docker exec headscale headscale apikeys create "${args[@]}"

cat >&2 <<'EOF'

Rotate this key before it expires:
  1. ./scripts/create-apikey.sh              # generate a new one
  2. Update it in headscale-admin's Settings page
  3. docker exec headscale headscale apikeys list
  4. docker exec headscale headscale apikeys expire --prefix <old-key-prefix>
EOF
