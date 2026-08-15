#!/usr/bin/env bash
# Interactive installer for the Headscale/Caddy/headscale-admin stack.
# Run with no arguments for the normal guided flow.
#
# Flags:
#   --reconfigure     re-run prompts even if .env already exists
#   --skip-deploy     generate config/render files, don't docker compose up
#   --skip-dns-check  skip the DNS verification gate (you're sure it's right)
#   -h, --help        this text
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1
# shellcheck source=lib/common.sh
source scripts/lib/common.sh
# shellcheck source=lib/detect.sh
source scripts/lib/detect.sh
# shellcheck source=lib/dnscheck.sh
source scripts/lib/dnscheck.sh
# shellcheck source=lib/logmap.sh
source scripts/lib/logmap.sh

RECONFIGURE=0
SKIP_DEPLOY=0
SKIP_DNS_CHECK=0
for arg in "$@"; do
	case "$arg" in
	--reconfigure) RECONFIGURE=1 ;;
	--skip-deploy) SKIP_DEPLOY=1 ;;
	--skip-dns-check) SKIP_DNS_CHECK=1 ;;
	-h | --help)
		sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) die_with_remedy "unknown flag: $arg" "./scripts/setup.sh --help" ;;
	esac
done

CADDY_IMAGE="caddy:2.10-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d"
COMPOSE="$(compose_cmd)"

printf '%s\n' "${C_BOLD}Local Tailscale on TrueNAS — guided setup${C_RESET}"
printf 'This asks a handful of questions, generates everything else, and\n'
printf 'brings the stack up. Nothing here is destructive to existing data.\n'

# ---------------------------------------------------------------- phase 0 --
step "Checking prerequisites"

require_cmd docker openssl curl python3
ok "docker, openssl, curl, python3 present"
info "compose command: $COMPOSE"

if [[ -f .env && "$RECONFIGURE" -eq 0 ]]; then
	warn ".env already exists — this looks like a repeat run."
	info "Re-run with --reconfigure to change settings, or just:"
	info "  $COMPOSE up -d && ./scripts/doctor.sh"
	exit 0
fi

PUB_IP="$(detect_public_ip || true)"
LAN_IP="$(detect_lan_ip || true)"
LAN_CIDR="$(detect_lan_cidr || true)"
TZ_DEFAULT="$(detect_tz || echo UTC)"
EMAIL_DEFAULT="$(detect_git_email || true)"

[[ -n "$PUB_IP" ]] && ok "public IP: $PUB_IP" || warn "couldn't auto-detect your public IP — you'll need it for DNS"
[[ -n "$LAN_IP" ]] && ok "LAN IP: $LAN_IP" || warn "couldn't auto-detect a LAN IP"

HOST_HTTP_PORT=80
HOST_HTTPS_PORT=443
for p in 80 443; do
	if ! port_free "$p"; then
		owner="$(port_owner "$p")"
		warn "port $p is already in use (by: $owner)"
	fi
done
if ! port_free 80 || ! port_free 443; then
	info "This is almost always either TrueNAS's own web UI, or a previous"
	info "run of this stack. If it's TrueNAS's UI: System Settings → General"
	info "→ GUI, move it off 80/443, then re-run this script."
	if ask_yesno "Run this stack on alternate ports instead (you'll forward the router to these)?" n; then
		ask HOST_HTTP_PORT "Host HTTP port" 8080
		ask HOST_HTTPS_PORT "Host HTTPS port" 8443
	else
		die_with_remedy "ports 80/443 are unavailable" "free them, or re-run and choose alternate ports"
	fi
fi

# ---------------------------------------------------------------- phase 1 --
step "Basic settings"

ask ZONE_APEX "Your domain (the zone itself, e.g. example.com)"
ask HEADSCALE_DOMAIN "Headscale hostname" "headscale.$ZONE_APEX"
while true; do
	ask HEADSCALE_ADMIN_DOMAIN "Admin UI hostname" "headscale-admin.$ZONE_APEX"
	if [[ "$HEADSCALE_ADMIN_DOMAIN" != "$HEADSCALE_DOMAIN" ]]; then
		break
	fi
	warn "admin hostname must differ from the headscale hostname"
done
ask ACME_EMAIL "Email for Let's Encrypt notices" "${EMAIL_DEFAULT:-you@$ZONE_APEX}"
while true; do
	ask MAGICDNS_BASE_DOMAIN "MagicDNS device-name suffix (not publicly resolvable, just used between your own devices)" "ts.$ZONE_APEX"
	if [[ "$MAGICDNS_BASE_DOMAIN" != "$HEADSCALE_DOMAIN" ]]; then
		break
	fi
	warn "this must differ from the headscale hostname, or MagicDNS breaks"
done
ask TZ "Timezone" "$TZ_DEFAULT"
ask ADMIN_BASIC_AUTH_USER "Admin UI username" "admin"

step "Admin UI password"
info "This protects https://$HEADSCALE_ADMIN_DOMAIN — a UI that can fully"
info "administer your tailnet. Press enter to generate a strong random one."
ask_secret ADMIN_PASSWORD_PLAIN "Admin UI password"
ADMIN_BASIC_AUTH_HASH="$(printf '%s' "$ADMIN_PASSWORD_PLAIN" | docker run --rm -i "$CADDY_IMAGE" caddy hash-password)"
ok "hashed (the plaintext isn't stored anywhere — write it down now)"

ask FIRST_USERNAME "Your headscale username (for your own devices)" "$(whoami)"

ADMIN_ALLOWED_CIDRS="100.64.0.0/10 fd7a:115c:a1e0::/48 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12"
if [[ -n "$LAN_CIDR" ]] && [[ "$ADMIN_ALLOWED_CIDRS" != *"$LAN_CIDR"* ]]; then
	ADMIN_ALLOWED_CIDRS="$ADMIN_ALLOWED_CIDRS $LAN_CIDR"
fi

DEPLOY_NOW=1
if ! ask_yesno "Deploy with docker compose over SSH right now (choose no if you're using TrueNAS's Custom App YAML installer instead)?" y; then
	DEPLOY_NOW=0
fi

# ---------------------------------------------------------------- phase 2 --
step "Generating configuration"

umask 077
{
	echo "# Generated by scripts/setup.sh on $(date -u +%FT%TZ). Re-run with --reconfigure to change."
	echo "# Values are single-quoted so this file parses correctly both for"
	echo "# docker compose's own .env reader and for doctor.sh, which sources"
	echo "# it as a shell script — some values below contain spaces or a"
	echo "# literal dollar sign that would otherwise be misread by one or the other."
	echo "HEADSCALE_DOMAIN='$HEADSCALE_DOMAIN'"
	echo "HEADSCALE_ADMIN_DOMAIN='$HEADSCALE_ADMIN_DOMAIN'"
	echo "AUTHELIA_DOMAIN=''"
	echo "ACME_EMAIL='$ACME_EMAIL'"
	echo "TZ='$TZ'"
	echo "ADMIN_ALLOWED_CIDRS='$ADMIN_ALLOWED_CIDRS'"
	echo "ADMIN_BASIC_AUTH_USER='$ADMIN_BASIC_AUTH_USER'"
	echo "ADMIN_BASIC_AUTH_HASH='$ADMIN_BASIC_AUTH_HASH'"
	echo "ADMIN_AUTH_SNIPPET='basic_auth_gate'"
	if [[ "$HOST_HTTP_PORT" != 80 ]]; then echo "HOST_HTTP_PORT='$HOST_HTTP_PORT'"; fi
	if [[ "$HOST_HTTPS_PORT" != 443 ]]; then echo "HOST_HTTPS_PORT='$HOST_HTTPS_PORT'"; fi
} > .env
chmod 600 .env
ok "wrote .env"

mkdir -p data/headscale data/caddy/data data/caddy/config config/caddy/conf.d/global config/caddy/conf.d/sites
chmod 700 data/headscale
ok "created data directories"

if grep -q '"myself"' config/headscale/acl.hujson 2>/dev/null; then
	sed -i.bak "s/\"myself\"/\"$FIRST_USERNAME\"/" config/headscale/acl.hujson && rm -f config/headscale/acl.hujson.bak
	ok "set your username in config/headscale/acl.hujson"
else
	info "config/headscale/acl.hujson already customized — left it alone"
fi

if grep -q 'base_domain: headscale.example.internal' config/headscale/config.yaml 2>/dev/null; then
	sed -i.bak "s/base_domain: headscale.example.internal/base_domain: $MAGICDNS_BASE_DOMAIN/" config/headscale/config.yaml && rm -f config/headscale/config.yaml.bak
	ok "set MagicDNS suffix in config/headscale/config.yaml"
else
	info "config/headscale/config.yaml base_domain already customized — left it alone"
fi

export REPO_DIR HEADSCALE_DOMAIN HEADSCALE_ADMIN_DOMAIN TZ ACME_EMAIL \
	ADMIN_ALLOWED_CIDRS ADMIN_BASIC_AUTH_USER ADMIN_BASIC_AUTH_HASH HOST_HTTP_PORT HOST_HTTPS_PORT
render_template truenas-custom-app.yaml.tmpl truenas-custom-app.rendered.yaml
ok "rendered truenas-custom-app.rendered.yaml (for the Custom App YAML installer, if you want it)"

if [[ "$SKIP_DEPLOY" -eq 1 || "$DEPLOY_NOW" -eq 0 ]]; then
	step "Done generating — deploy skipped"
	info "Paste truenas-custom-app.rendered.yaml into Apps → Discover Apps →"
	info "Custom App → Install via YAML on TrueNAS, or run:"
	info "  $COMPOSE up -d"
	info "when you're ready. First though — see the DNS records below."
	SKIP_DEPLOY=1
fi

# ---------------------------------------------------------------- phase 3 --
if [[ "$SKIP_DNS_CHECK" -eq 0 ]]; then
	step "DNS records"
	target_ip="${PUB_IP:-<your public IP>}"
	printf '\n  %-6s %-24s %-30s %s\n' "Type" "Name" "Value" "Proxy"
	printf '  %-6s %-24s %-30s %s\n' "A" "$HEADSCALE_DOMAIN" "$target_ip" "DNS only (grey cloud)"
	printf '  %-6s %-24s %-30s %s\n\n' "CNAME" "$HEADSCALE_ADMIN_DOMAIN" "$HEADSCALE_DOMAIN" "DNS only (grey cloud)"
	info "If you use Cloudflare: proxy MUST be off (grey, not orange) — Headscale's"
	info "control protocol uses a WebSocket-over-POST that Cloudflare's edge rejects."

	if [[ -n "$PUB_IP" ]]; then
		while true; do
			r1="$(check_dns_record "$HEADSCALE_DOMAIN" "$PUB_IP" || true)"
			r2="$(check_dns_record "$HEADSCALE_ADMIN_DOMAIN" "$PUB_IP" || true)"
			[[ "$r1" == "ok" ]] && ok "$HEADSCALE_DOMAIN resolves correctly" || warn "$HEADSCALE_DOMAIN: $r1"
			[[ "$r2" == "ok" ]] && ok "$HEADSCALE_ADMIN_DOMAIN resolves correctly" || warn "$HEADSCALE_ADMIN_DOMAIN: $r2"
			if [[ "$r1" == "ok" && "$r2" == "ok" ]]; then
				break
			fi
			read -r -p "  [r]echeck / [s]kip / [q]uit: " choice || choice="q"
			case "$choice" in
			s | S) break ;;
			q | Q) exit 1 ;;
			*) ;;
			esac
		done
	else
		warn "couldn't detect your public IP to verify against — check the records manually"
	fi
fi

if [[ "$SKIP_DEPLOY" -eq 1 ]]; then
	exit 0
fi

# ---------------------------------------------------------------- phase 4 --
step "Bringing the stack up (staging certificate first, to avoid rate limits)"

mkdir -p config/caddy/conf.d/global
echo 'acme_ca https://acme-staging-v02.api.letsencrypt.org/directory' > config/caddy/conf.d/global/01-acme-staging.caddy

$COMPOSE up -d

# Tests via a raw TLS handshake straight to the container's published port
# (bypassing DNS/NAT-hairpin, and Caddy's HTTP-layer IP allowlist/basic
# auth entirely — this only asks "did Caddy get a certificate for this
# name", not "can I load the app").
poll_certs() {
	local deadline=$((SECONDS + 90)) d all_ok
	while (( SECONDS < deadline )); do
		all_ok=1
		for d in "$HEADSCALE_DOMAIN" "$HEADSCALE_ADMIN_DOMAIN"; do
			echo | openssl s_client -connect "127.0.0.1:${HOST_HTTPS_PORT}" -servername "$d" 2>/dev/null \
				| grep -q 'BEGIN CERTIFICATE' || all_ok=0
		done
		if [[ "$all_ok" -eq 1 ]]; then
			return 0
		fi
		sleep 3
	done
	$COMPOSE logs --no-log-prefix caddy 2>&1 | tail -n 200
	return 1
}

if failure_log="$(poll_certs)"; then
	ok "staging certificate issued — DNS and port-forwarding are confirmed working"
else
	fail "staging certificate never issued within 90s"
	if ! translate_logs <<< "$failure_log"; then
		printf '\n  Recent caddy logs:\n%s\n' "$failure_log"
	fi
	info "Fix the above, then re-run: ./scripts/setup.sh --reconfigure --skip-dns-check"
	info "(the staging CA stays selected until a staging cert succeeds, so retries are free)"
	exit 1
fi

rm -f config/caddy/conf.d/global/01-acme-staging.caddy
$COMPOSE up -d caddy
step "Requesting the real certificate"
if failure_log="$(poll_certs)"; then
	ok "production certificate issued"
else
	fail "production certificate failed after staging succeeded — unusual"
	translate_logs <<< "$failure_log" || printf '%s\n' "$failure_log"
	info "This is sometimes a Let's Encrypt rate limit if you've retried many times today."
	exit 1
fi

# ---------------------------------------------------------------- phase 5 --
step "Post-deploy: user, ACL, API key"

create_out="$(docker exec headscale headscale users create "$FIRST_USERNAME" 2>&1)" && ok "created headscale user: $FIRST_USERNAME" || {
	if grep -qi "exist" <<< "$create_out"; then
		info "headscale user $FIRST_USERNAME already exists"
	else
		warn "couldn't create headscale user $FIRST_USERNAME: $create_out"
	fi
}

if docker exec headscale headscale policy get >/dev/null 2>&1; then
	ok "ACL policy loaded"
else
	warn "couldn't confirm the ACL policy loaded — check: docker exec headscale headscale policy get"
fi

API_KEY="$(docker exec headscale headscale apikeys create --expiration 30d 2>/dev/null | tail -1)" || {
	warn "couldn't mint an API key — the stack is up, just run this yourself:"
	info "  ./scripts/create-apikey.sh"
	API_KEY="(failed — see above)"
}
PREAUTH_KEY="$(docker exec headscale headscale preauthkeys create --user "$FIRST_USERNAME" --expiration 1h 2>/dev/null | tail -1)" || {
	warn "couldn't mint a pre-auth key — the stack is up, just run this yourself:"
	info "  ./scripts/create-preauthkey.sh $FIRST_USERNAME --expiration 1h"
	PREAUTH_KEY="(failed — see above)"
}

# ---------------------------------------------------------------------------
step "Done"

printf '\n'
printf '  %sAdmin UI:%s        https://%s\n' "$C_BOLD" "$C_RESET" "$HEADSCALE_ADMIN_DOMAIN"
printf '  %sAdmin username:%s  %s\n' "$C_BOLD" "$C_RESET" "$ADMIN_BASIC_AUTH_USER"
printf '  %sAdmin password:%s  %s\n' "$C_BOLD" "$C_RESET" "$ADMIN_PASSWORD_PLAIN"
printf '  %sAPI key:%s         %s\n' "$C_BOLD" "$C_RESET" "$API_KEY"
printf '\n  %sheadscale-admin Settings page → Headscale URL:%s https://%s\n' "$C_DIM" "$C_RESET" "$HEADSCALE_ADMIN_DOMAIN"
printf '\n  %sJoin your first device:%s\n' "$C_BOLD" "$C_RESET"
printf '    tailscale up --login-server=https://%s --authkey=%s\n' "$HEADSCALE_DOMAIN" "$PREAUTH_KEY"
printf '    (this key is single-use and expires in 1h — ./scripts/create-preauthkey.sh for more)\n'

if command -v qrencode >/dev/null 2>&1; then
	printf '\n'
	qrencode -t ANSIUTF8 "https://$HEADSCALE_DOMAIN" || true
fi

printf '\n  None of the above (except the API key, which headscale never shows\n'
printf '  again) is saved anywhere but .env and your terminal scrollback —\n'
printf '  write down the password and API key now.\n'
printf '\n  Next: ./scripts/doctor.sh any time something looks wrong.\n'
printf '        ./scripts/backup.sh on a schedule.\n'
printf '        README "Optional: two-factor authentication" if you want TOTP too.\n\n'
