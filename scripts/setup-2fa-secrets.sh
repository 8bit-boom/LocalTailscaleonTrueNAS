#!/usr/bin/env bash
# Generate the random secrets Authelia needs (JWT, session, storage
# encryption key) into ./secrets/, gitignored. Run this once before
# starting the "2fa" compose profile for the first time.
# Usage: ./scripts/setup-2fa-secrets.sh [--force]
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secrets_dir="$repo_dir/secrets"
force=0
[[ "${1:-}" == "--force" ]] && force=1

mkdir -p "$secrets_dir"
chmod 700 "$secrets_dir"

for name in authelia_jwt_secret authelia_session_secret authelia_storage_encryption_key; do
	f="$secrets_dir/$name"
	if [[ -f "$f" && "$force" -eq 0 ]]; then
		echo "skip: $f already exists (use --force to regenerate — regenerating authelia_storage_encryption_key makes the existing database unreadable, losing everyone's enrolled TOTP; regenerating the others just forces re-login)" >&2
		continue
	fi
	umask 077
	openssl rand -hex 32 > "$f"
	echo "wrote $f"
done
