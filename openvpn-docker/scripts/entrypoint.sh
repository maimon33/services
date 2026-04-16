#!/bin/bash
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
: "${SERVER_NAME:?SERVER_NAME env var is required}"
: "${OPENVPN_PROTO:=udp}"
: "${VPN_NETWORK:=10.8.0.0}"
: "${VPN_SUBNET:=255.255.255.0}"
: "${PUSH_DNS_1:=1.1.1.1}"
: "${PUSH_DNS_2:=8.8.8.8}"
: "${INTERNAL_NETWORKS:=}"
: "${ROUTE_APPS:=}"

# ── Logging ───────────────────────────────────────────────────────────────────
log() { echo "[entrypoint] $*"; }

# ── Directories ───────────────────────────────────────────────────────────────
mkdir -p /data/pki /data/ccd /data/logs /data/users /data/clients
# OpenVPN drops to nobody — these dirs must be traversable/writable by nobody
chmod 711 /data/pki
chmod 777 /data/logs

# ── TUN device ────────────────────────────────────────────────────────────────
if [[ ! -e /dev/net/tun ]]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# ── IP forwarding (set by docker-compose sysctls, verified here) ──────────────
sysctl -w net.ipv4.ip_forward=1 > /dev/null || true

# ── iptables NAT ─────────────────────────────────────────────────────────────
log "Setting up iptables rules..."

DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')

# Use dedicated chains so we never flush Docker's FORWARD/POSTROUTING entries.
# On restart we just flush our own chain — Docker's rules stay intact.

# nat POSTROUTING — masquerade VPN traffic
iptables -t nat -N OPENVPN-POSTROUTING 2>/dev/null || true
iptables -t nat -F OPENVPN-POSTROUTING
iptables -t nat -C POSTROUTING -j OPENVPN-POSTROUTING 2>/dev/null || \
    iptables -t nat -A POSTROUTING -j OPENVPN-POSTROUTING
iptables -t nat -A OPENVPN-POSTROUTING \
    -s "${VPN_NETWORK}/${VPN_SUBNET}" -o "${DEFAULT_IFACE}" -j MASQUERADE

# FORWARD — allow tun0 traffic (VPN clients ↔ LAN/internet)
iptables -N OPENVPN-FORWARD 2>/dev/null || true
iptables -F OPENVPN-FORWARD
iptables -C FORWARD -j OPENVPN-FORWARD 2>/dev/null || \
    iptables -I FORWARD 1 -j OPENVPN-FORWARD
iptables -A OPENVPN-FORWARD -i tun0 -j ACCEPT
iptables -A OPENVPN-FORWARD -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow forwarding to configured internal networks
for net in ${INTERNAL_NETWORKS}; do
    iptables -A OPENVPN-FORWARD -i tun0 -d "$net" -j ACCEPT
    iptables -A OPENVPN-FORWARD -s "$net" -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
done

# ── Sync ROUTE_APPS into routes.conf ─────────────────────────────────────────
# Entries from ROUTE_APPS are written to a managed block inside routes.conf.
# Manual entries outside the block are preserved.
ROUTES_FILE=/etc/openvpn/routes.conf
BLOCK_START="# <<< ROUTE_APPS (managed) >>>"
BLOCK_END="# <<< END ROUTE_APPS >>>"

# Strip any previous managed block (idempotent on restart).
# sed -i does an atomic rename which fails on bind-mounted files; use tmp + redirect instead.
if [[ -f "$ROUTES_FILE" ]]; then
    _tmp=$(mktemp)
    sed "/${BLOCK_START}/,/${BLOCK_END}/d" "$ROUTES_FILE" > "$_tmp"
    cat "$_tmp" > "$ROUTES_FILE"
    rm -f "$_tmp"
fi

if [[ -n "$ROUTE_APPS" ]]; then
    log "Writing ROUTE_APPS to routes.conf..."
    {
        echo ""
        echo "$BLOCK_START"
        for app in $ROUTE_APPS; do
            echo "$app"
        done
        echo "$BLOCK_END"
    } >> "$ROUTES_FILE"
fi

# ── First-time PKI init ───────────────────────────────────────────────────────
if [[ ! -f /data/pki/ca.crt ]]; then
    log "No PKI found — running first-time initialization..."
    /etc/openvpn/scripts/init-pki.sh
else
    log "PKI already initialized, skipping init."
fi

# ── Refresh CRL on startup (extends expiry) ───────────────────────────────────
log "Refreshing CRL..."
cd /data/pki && EASYRSA_PKI=/data/pki EASYRSA_BATCH=1 \
    /usr/share/easy-rsa/easyrsa gen-crl 2>/dev/null || true
# Must be world-readable — OpenVPN reads it as nobody after dropping privileges
chmod 644 /data/pki/crl.pem

# ── Start OpenVPN ─────────────────────────────────────────────────────────────
log "Starting OpenVPN (proto=${OPENVPN_PROTO})..."
exec openvpn --config /data/server.conf
