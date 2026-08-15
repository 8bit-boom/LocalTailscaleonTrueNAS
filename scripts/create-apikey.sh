#!/usr/bin/env bash
# Generate an API key for headscale-admin (or any other tool that talks to
# headscale's REST API). Paste the output into headscale-admin's Settings
# page. Keys don't expire by default unless you pass --expiration.
# Usage: ./scripts/create-apikey.sh [--expiration 90d]
set -euo pipefail

docker exec headscale headscale apikeys create "$@"
