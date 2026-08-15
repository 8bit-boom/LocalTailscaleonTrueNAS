#!/usr/bin/env bash
# Auto-detection helpers for scripts/setup.sh and scripts/doctor.sh. Sourced.
# Every function prints its result to stdout and returns non-zero if it
# couldn't figure anything out — callers should always have a manual
# fallback prompt ready.

detect_public_ip() {
	local ip
	for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
		ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
		[[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
	done
	return 1
}

detect_lan_ip() {
	ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )[\d.]+' | head -1
}

# Best-effort /24 for the LAN IP, for the admin allowlist default.
detect_lan_cidr() {
	local ip
	ip="$(detect_lan_ip)" || return 1
	[[ -z "$ip" ]] && return 1
	echo "${ip%.*}.0/24"
}

detect_tz() {
	if command -v timedatectl >/dev/null 2>&1; then
		timedatectl show -p Timezone --value 2>/dev/null && return 0
	fi
	[[ -r /etc/timezone ]] && { cat /etc/timezone; return 0; }
	echo "UTC"
}

detect_git_email() {
	git config --get user.email 2>/dev/null || true
}

# port_owner PORT — best-effort name of whatever's listening, for a
# friendlier conflict message than a bare "address already in use".
# Degrades gracefully if `ss` isn't installed (not on every minimal image).
port_owner() {
	local port="$1" pid
	command -v ss >/dev/null 2>&1 || { echo "another process"; return 0; }
	pid="$(ss -Htlnp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$"' | grep -oP 'pid=\K[0-9]+' | head -1)"
	if [[ -n "$pid" ]]; then
		tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "pid $pid"
	else
		echo "another process"
	fi
}

docker_network_exists() {
	docker network inspect "$1" >/dev/null 2>&1
}

clock_skew_seconds() {
	local remote local_ts
	remote="$(curl -fsSI --max-time 5 https://cloudflare-dns.com 2>/dev/null | grep -i '^date:' | cut -d' ' -f2-)"
	[[ -z "$remote" ]] && return 1
	remote="$(date -d "$remote" +%s 2>/dev/null)" || return 1
	local_ts="$(date +%s)"
	echo $(( local_ts - remote ))
}
