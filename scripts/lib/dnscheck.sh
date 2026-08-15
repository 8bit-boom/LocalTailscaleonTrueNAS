#!/usr/bin/env bash
# DNS-over-HTTPS lookups for scripts/setup.sh and scripts/doctor.sh. Sourced.
# Uses Cloudflare's DoH resolver directly (not the box's own resolver, which
# may be a LAN/split-horizon one that wouldn't catch what the public
# internet actually sees) and needs no `dig` binary.

# doh_lookup NAME TYPE — prints one answer per line, or nothing.
doh_lookup() {
	local name="$1" type="$2"
	curl -fsS --max-time 5 -H 'accept: application/dns-json' \
		"https://cloudflare-dns.com/dns-query?name=${name}&type=${type}" 2>/dev/null \
		| python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in d.get("Answer", []) or []:
    print(a.get("data", "").strip("\""))
' 2>/dev/null
}

# Follows CNAME chains and returns the final A record(s).
doh_resolve_a() {
	local name="$1" hops=0
	while (( hops < 5 )); do
		local answers
		answers="$(doh_lookup "$name" A)"
		if [[ -n "$answers" ]]; then
			echo "$answers"
			return 0
		fi
		local cname
		cname="$(doh_lookup "$name" CNAME | head -1)"
		[[ -z "$cname" ]] && return 1
		name="${cname%.}"
		hops=$(( hops + 1 ))
	done
	return 1
}

# Cloudflare's published edge IPv4 ranges (ips-v4.txt as of 2026). Used only
# to give a specific, correct diagnosis when a domain still resolves through
# Cloudflare's proxy instead of pointing directly at the box — Headscale's
# control protocol doesn't work through it (see README).
_CLOUDFLARE_RANGES=(
	104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 162.158.0.0/15
	188.114.96.0/20 190.93.240.0/20 197.234.240.0/22 198.41.128.0/17
	173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
	141.101.64.0/18 108.162.192.0/18 131.0.72.0/22
)

_ip_to_int() {
	local IFS=. a b c d
	read -r a b c d <<< "$1"
	echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

ip_in_cidr() {
	local ip="$1" cidr="$2" base bits ip_i base_i mask
	base="${cidr%/*}"; bits="${cidr#*/}"
	ip_i="$(_ip_to_int "$ip")"; base_i="$(_ip_to_int "$base")"
	mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
	(( (ip_i & mask) == (base_i & mask) ))
}

is_cloudflare_proxied_ip() {
	local ip="$1" cidr
	for cidr in "${_CLOUDFLARE_RANGES[@]}"; do
		ip_in_cidr "$ip" "$cidr" && return 0
	done
	return 1
}

# check_dns_record NAME EXPECTED_IP — prints a one-line verdict:
# "ok" / "mismatch:<ip>" / "cloudflare-proxied:<ip>" / "nxdomain"
check_dns_record() {
	local name="$1" expected="$2" answers first
	answers="$(doh_resolve_a "$name")" || { echo "nxdomain"; return 1; }
	first="$(echo "$answers" | head -1)"
	if is_cloudflare_proxied_ip "$first"; then
		echo "cloudflare-proxied:$first"; return 1
	fi
	if echo "$answers" | grep -qx "$expected"; then
		echo "ok"; return 0
	fi
	echo "mismatch:$first"; return 1
}
