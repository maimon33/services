#!/bin/bash
# Called by OpenVPN when a client connects (client-connect directive).
# $1 = path to per-client config file; push directives written here are sent to the client.
# Environment (set by OpenVPN):
#   $common_name      — client cert CN (= username)
#   $ifconfig_pool_remote_ip — IP assigned to the client
set -euo pipefail

CLIENT_CONFIG_FILE="${1:?missing client config file argument}"
ROUTES_FILE="/etc/openvpn/routes.conf"

log() {
    echo "[client-connect] [${common_name:-?}] $*" >> /data/logs/connect.log
}

log "Client connected from ${trusted_ip:-?}, assigned ${ifconfig_pool_remote_ip:-?}"

[[ ! -f "$ROUTES_FILE" ]] && { log "No routes.conf found, skipping dynamic routes."; exit 0; }

# ── cidr_to_mask: convert prefix length to dotted-decimal mask ───────────────
cidr_to_mask() {
    python3 -c "
import ipaddress
net = ipaddress.IPv4Network('${1}', strict=False)
print(str(net.network_address), str(net.netmask))
"
}

push_route() {
    local net="$1" mask="$2"
    echo "push \"route $net $mask\"" >> "$CLIENT_CONFIG_FILE"
    log "  push route $net $mask"
}

# ── Parse routes.conf ─────────────────────────────────────────────────────────
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]]  && continue

    entry="${line%%#*}"           # strip inline comments
    entry="${entry//[[:space:]]/}" # trim whitespace
    [[ -z "$entry" ]] && continue

    if [[ "$entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        # ── CIDR ──────────────────────────────────────────────────────────
        read -r net mask <<< "$(cidr_to_mask "$entry")"
        push_route "$net" "$mask"

    elif [[ "$entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # ── Single IP ─────────────────────────────────────────────────────
        push_route "$entry" "255.255.255.255"

    else
        # ── Hostname — resolve all A records ──────────────────────────────
        log "  Resolving $entry..."
        mapfile -t ips < <(dig +short +time=2 +tries=2 A "$entry" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        if [[ ${#ips[@]} -eq 0 ]]; then
            log "  WARNING: could not resolve '$entry', skipping"
        else
            for ip in "${ips[@]}"; do
                push_route "$ip" "255.255.255.255"
            done
        fi
    fi
done < "$ROUTES_FILE"

# ── Per-user CCD overrides ────────────────────────────────────────────────────
# Additional per-user push directives can be placed in /data/ccd/<username>
# OpenVPN reads that file automatically — nothing extra needed here.

log "Route injection complete."
exit 0
