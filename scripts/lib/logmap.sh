#!/usr/bin/env bash
# Known log-signature -> plain-English cause/remedy, shared by setup.sh's
# bring-up poller and doctor.sh --logs. Sourced.

# translate_logs < log-text — prints any matches found, one block each.
# Prints nothing if no known signature matched (caller should fall back to
# "here are the raw logs" in that case, not pretend everything's fine).
translate_logs() {
	local text found=0
	text="$(cat)"

	_hit() { found=1; printf '  %s✗%s %s\n      %s\n' "$C_RED" "$C_RESET" "$1" "$2"; }

	if grep -qiE 'no such host|nxdomain' <<< "$text"; then
		_hit "DNS record doesn't exist yet (or hasn't propagated)" \
			"Re-check with: ./scripts/doctor.sh"
	fi
	if grep -qiE 'connection refused' <<< "$text" && grep -qi ':80' <<< "$text"; then
		_hit "Nothing reachable on port 80 from the outside" \
			"Confirm the router forwards 80/tcp to this box, and that nothing else (e.g. the TrueNAS UI) already owns port 80 here."
	fi
	if grep -qiE 'i/o timeout' <<< "$text" && grep -qiE 'acme|challenge' <<< "$text"; then
		_hit "ACME challenge timed out reaching this box from the internet" \
			"Almost always a router port-forward that isn't actually working — test from outside your network (e.g. phone on cellular)."
	fi
	if grep -qiE 'urn:ietf:params:acme:error:unauthorized' <<< "$text" && grep -qi 'cloudflare' <<< "$text"; then
		_hit "Let's Encrypt hit a Cloudflare error page instead of this box" \
			"The DNS record is still proxied (orange cloud) — switch it to 'DNS only' (grey cloud) in Cloudflare."
	fi
	if grep -qiE 'rateLimited|too many (certificates|failed)' <<< "$text"; then
		_hit "Let's Encrypt rate limit hit" \
			"Wait it out (an hour for failed-validation limits, a week for certs-per-domain), or make sure setup.sh's staging phase actually passed first next time."
	fi
	if grep -qiE 'adapting config using caddyfile.*basic_auth|bcrypt' <<< "$text"; then
		_hit "Caddy's basic_auth directive got an empty or malformed password hash" \
			"Re-run ./scripts/setup.sh --reconfigure, or check ADMIN_BASIC_AUTH_HASH in .env."
	fi
	if grep -qiE 'no such file or directory.*run/secrets' <<< "$text"; then
		_hit "A Compose secret file is missing" \
			"./scripts/setup-2fa-secrets.sh"
	fi
	if grep -qiE 'forward_auth|dial tcp.*authelia' <<< "$text" && grep -qiE 'connection refused|no such host' <<< "$text"; then
		_hit "Caddy is set to use Authelia (forward_auth_gate) but Authelia isn't running" \
			"docker compose --profile 2fa up -d   (or set ADMIN_AUTH_SNIPPET=basic_auth_gate in .env to fall back)"
	fi
	if grep -qiE 'failed to load.*polic|error loading ACL|invalid config' <<< "$text" && grep -qi 'acl' <<< "$text"; then
		_hit "headscale's ACL policy file failed to parse — treat this as an outage, not a warning" \
			"Check config/headscale/acl.hujson for a syntax error, then: docker compose restart headscale"
	fi

	(( found == 0 )) && return 1
	return 0
}
