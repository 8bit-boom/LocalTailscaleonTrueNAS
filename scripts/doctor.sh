#!/usr/bin/env bash
# Standalone health check — safe to run any time, changes nothing.
# Usage: ./scripts/doctor.sh [--logs]
#
# Deliberately no `set -e`: the whole point is to run every check and
# report all of them, not stop at the first failure.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1
source scripts/lib/common.sh
source scripts/lib/detect.sh
source scripts/lib/dnscheck.sh
source scripts/lib/logmap.sh

SHOW_LOGS=0
[[ "${1:-}" == "--logs" ]] && SHOW_LOGS=1

COMPOSE="$(compose_cmd)"
PASS=0
TOTAL=0

check() {
	# check "description" -- command...
	local desc="$1" out
	shift
	TOTAL=$((TOTAL + 1))
	if out="$("$@" 2>&1)"; then
		ok "$desc"
		PASS=$((PASS + 1))
	else
		fail "$desc"
		[[ -n "$out" ]] && info "${out%%$'\n'*}"
	fi
}

step "Host"

check "docker present" command -v docker
check "compose present" bash -c "docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1"

HTTP_PORT="${HOST_HTTP_PORT:-80}"
HTTPS_PORT="${HOST_HTTPS_PORT:-443}"
[[ -f .env ]] && { HTTP_PORT="$(grep -m1 '^HOST_HTTP_PORT=' .env 2>/dev/null | cut -d= -f2)"; HTTP_PORT="${HTTP_PORT:-80}"; }
[[ -f .env ]] && { HTTPS_PORT="$(grep -m1 '^HOST_HTTPS_PORT=' .env 2>/dev/null | cut -d= -f2)"; HTTPS_PORT="${HTTPS_PORT:-443}"; }

for p in "$HTTP_PORT" "$HTTPS_PORT"; do
	TOTAL=$((TOTAL + 1))
	if port_free "$p"; then
		warn "port $p is free (expected caddy to own it — is the stack up?)"
	else
		ok "port $p is in use (expected — caddy, presumably)"
		PASS=$((PASS + 1))
	fi
done

df_line="$(df -Ph . 2>/dev/null | tail -1)"
avail_pct="$(awk '{print $5}' <<< "$df_line" | tr -d '%')"
TOTAL=$((TOTAL + 1))
if [[ -n "$avail_pct" && "$avail_pct" -lt 90 ]]; then
	ok "disk usage on this filesystem: ${avail_pct}%"
	PASS=$((PASS + 1))
else
	warn "disk usage high or unknown: ${df_line:-unknown}"
fi

skew="$(clock_skew_seconds || true)"
TOTAL=$((TOTAL + 1))
if [[ -n "$skew" ]] && (( ${skew#-} < 30 )); then
	ok "clock is within 30s of real time (matters for TOTP if you use 2FA)"
	PASS=$((PASS + 1))
else
	warn "couldn't confirm clock accuracy (skew: ${skew:-not measurable}) — check \`date\` if you use 2FA"
fi

step "Configuration"

if [[ ! -f .env ]]; then
	fail "no .env — run ./scripts/setup.sh"
	TOTAL=$((TOTAL + 1))
else
	# shellcheck disable=SC1091
	set -a; source .env; set +a
	TOTAL=$((TOTAL + 1))
	if grep -qE 'CHANGE-ME|YOUR_POOL' .env 2>/dev/null; then
		fail "leftover CHANGE-ME/YOUR_POOL placeholder found in .env"
	else
		ok "no leftover placeholder values in .env"
		PASS=$((PASS + 1))
	fi

	# Authelia's config only matters once 2FA is actually in use — it ships
	# with placeholders by design otherwise (see README "Optional:
	# two-factor authentication").
	if [[ -n "${AUTHELIA_DOMAIN:-}" ]]; then
		TOTAL=$((TOTAL + 1))
		if grep -qE 'CHANGE-ME' config/authelia/configuration.yml 2>/dev/null; then
			fail "AUTHELIA_DOMAIN is set but config/authelia/configuration.yml still has CHANGE-ME placeholders"
		else
			ok "config/authelia/configuration.yml looks customized"
			PASS=$((PASS + 1))
		fi
	fi

	TOTAL=$((TOTAL + 1))
	if [[ -n "${ADMIN_BASIC_AUTH_HASH:-}" && "$ADMIN_BASIC_AUTH_HASH" == \$2* ]]; then
		ok "ADMIN_BASIC_AUTH_HASH is set and bcrypt-shaped"
		PASS=$((PASS + 1))
	else
		fail "ADMIN_BASIC_AUTH_HASH is empty or doesn't look like a bcrypt hash"
	fi

	TOTAL=$((TOTAL + 1))
	if [[ -n "${HEADSCALE_DOMAIN:-}" && "${HEADSCALE_DOMAIN:-}" != "${HEADSCALE_ADMIN_DOMAIN:-}" ]]; then
		ok "HEADSCALE_DOMAIN and HEADSCALE_ADMIN_DOMAIN differ"
		PASS=$((PASS + 1))
	else
		fail "HEADSCALE_DOMAIN and HEADSCALE_ADMIN_DOMAIN are the same or unset"
	fi

	TOTAL=$((TOTAL + 1))
	if grep -q '"myself"' config/headscale/acl.hujson 2>/dev/null; then
		fail "config/headscale/acl.hujson still has the placeholder user \"myself\""
	else
		ok "acl.hujson looks customized"
		PASS=$((PASS + 1))
	fi

	TOTAL=$((TOTAL + 1))
	if grep -q 'base_domain: headscale.example.internal' config/headscale/config.yaml 2>/dev/null; then
		fail "config/headscale/config.yaml still has the placeholder MagicDNS base_domain"
	else
		ok "config.yaml base_domain looks customized"
		PASS=$((PASS + 1))
	fi
fi

step "DNS"

if [[ -n "${HEADSCALE_DOMAIN:-}" ]]; then
	pub_ip="$(detect_public_ip || true)"
	if [[ -n "$pub_ip" ]]; then
		for d in "$HEADSCALE_DOMAIN" "${HEADSCALE_ADMIN_DOMAIN:-}"; do
			[[ -z "$d" ]] && continue
			TOTAL=$((TOTAL + 1))
			r="$(check_dns_record "$d" "$pub_ip" || true)"
			if [[ "$r" == "ok" ]]; then
				ok "$d resolves to this box"
				PASS=$((PASS + 1))
			else
				fail "$d: $r"
			fi
		done
	else
		warn "couldn't detect public IP to verify DNS against"
	fi
else
	info "skipped — no .env"
fi

step "Runtime"

if $COMPOSE ps --status running --services 2>/dev/null | grep -qx headscale; then
	ok "headscale container is running"
	PASS=$((PASS + 1))
else
	fail "headscale container isn't running"
fi
TOTAL=$((TOTAL + 1))

if $COMPOSE ps --status running --services 2>/dev/null | grep -qx headscale-caddy 2>/dev/null || \
   $COMPOSE ps --status running --services 2>/dev/null | grep -qx caddy; then
	ok "caddy container is running"
	PASS=$((PASS + 1))
else
	fail "caddy container isn't running"
fi
TOTAL=$((TOTAL + 1))

TOTAL=$((TOTAL + 1))
if docker exec headscale headscale policy get >/dev/null 2>&1; then
	ok "headscale ACL policy loaded without error"
	PASS=$((PASS + 1))
else
	fail "headscale ACL policy check failed (docker exec headscale headscale policy get)"
fi

if [[ -n "${HEADSCALE_DOMAIN:-}" ]]; then
	TOTAL=$((TOTAL + 1))
	if echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -servername "$HEADSCALE_DOMAIN" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
		ok "TLS certificate present for $HEADSCALE_DOMAIN"
		PASS=$((PASS + 1))
	else
		fail "no TLS certificate found for $HEADSCALE_DOMAIN on port $HTTPS_PORT"
	fi
fi

printf '\n%s%d/%d checks passed%s\n' "$C_BOLD" "$PASS" "$TOTAL" "$C_RESET"

if [[ "$SHOW_LOGS" -eq 1 ]]; then
	step "Recent logs (translated where recognized)"
	logs="$($COMPOSE logs --no-log-prefix --tail 300 2>&1)"
	if ! translate_logs <<< "$logs"; then
		info "no known-signature errors matched — raw logs follow"
		printf '%s\n' "$logs"
	fi
fi

[[ "$PASS" -eq "$TOTAL" ]]
