#!/usr/bin/env bash
# Shared helpers for scripts/setup.sh and scripts/doctor.sh. Sourced, not run.
# Assumes `set -euo pipefail` in the caller.

if [[ -t 1 ]]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
	C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

step()  { printf '\n%s%s==>%s %s%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" ; printf '%s\n' "$C_RESET"; }
ok()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; }
info()  { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# die_with_remedy "what went wrong" "exact command or action to fix it"
die_with_remedy() {
	fail "$1"
	[[ -n "${2:-}" ]] && printf '\n  Try:\n    %s\n' "$2" >&2
	exit 1
}

require_cmd() {
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || die_with_remedy "missing required command: $c" "install $c and re-run"
	done
}

# ask VAR "Prompt text" "default"
ask() {
	local __var="$1" __prompt="$2" __default="${3:-}" __reply
	if [[ -n "$__default" ]]; then
		read -r -p "  $__prompt [$__default]: " __reply || true
		__reply="${__reply:-$__default}"
	else
		while true; do
			read -r -p "  $__prompt: " __reply || true
			[[ -n "$__reply" ]] && break
			warn "this can't be blank"
		done
	fi
	printf -v "$__var" '%s' "$__reply"
}

ask_yesno() {
	local __prompt="$1" __default="${2:-n}" __reply
	local __hint="y/N"
	[[ "$__default" == "y" ]] && __hint="Y/n"
	read -r -p "  $__prompt [$__hint]: " __reply || true
	__reply="${__reply:-$__default}"
	[[ "$__reply" =~ ^[Yy] ]]
}

# ask_secret VAR "Prompt text" — hidden input, typed twice, must match.
# Offers to generate a random value if the user just presses enter.
ask_secret() {
	local __var="$1" __prompt="$2" __gen_len="${3:-24}" __p1 __p2
	while true; do
		read -r -s -p "  $__prompt (blank = generate one): " __p1 || true
		printf '\n'
		if [[ -z "$__p1" ]]; then
			__p1="$(openssl rand -base64 "$__gen_len" | tr -d '/+=' | head -c "$__gen_len")"
			ok "generated a random value"
			printf -v "$__var" '%s' "$__p1"
			return 0
		fi
		read -r -s -p "  confirm: " __p2 || true
		printf '\n'
		if [[ "$__p1" == "$__p2" ]]; then
			printf -v "$__var" '%s' "$__p1"
			return 0
		fi
		warn "didn't match, try again"
	done
}

# render_template SRC DEST  — replaces __TOKEN__ with $TOKEN for every
# __UPPER_SNAKE__ pattern found, pulling values from the current shell
# environment. Errors out if a token has no value set (catches typos and
# forgotten tokens instead of silently writing a literal __TOKEN__).
render_template() {
	local src="$1" dest="$2" line out token value
	: > "$dest"
	while IFS= read -r line || [[ -n "$line" ]]; do
		out="$line"
		while [[ "$out" =~ __([A-Z0-9_]+)__ ]]; do
			token="${BASH_REMATCH[1]}"
			value="${!token-__UNSET__}"
			if [[ "$value" == "__UNSET__" ]]; then
				die_with_remedy "template $src references \$$token, which isn't set" "this is a bug in the wizard, not something to fix by hand"
			fi
			out="${out//__${token}__/$value}"
		done
		printf '%s\n' "$out" >> "$dest"
	done < "$src"
}

# Tries an actual bind instead of parsing `ss` output — works the same
# regardless of which tools happen to be installed, since python3 is
# already a hard requirement.
port_free() {
	local port="$1"
	python3 - "$port" <<-'PYEOF' 2>/dev/null
	import socket, sys
	s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
	s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	try:
	    s.bind(("0.0.0.0", int(sys.argv[1])))
	    s.close()
	    sys.exit(0)
	except OSError:
	    sys.exit(1)
	PYEOF
}

compose_cmd() {
	if docker compose version >/dev/null 2>&1; then
		echo "docker compose"
	elif command -v docker-compose >/dev/null 2>&1; then
		echo "docker-compose"
	else
		die_with_remedy "no docker compose plugin or docker-compose binary found" "install Docker Compose v2 (TrueNAS SCALE ships it by default)"
	fi
}
