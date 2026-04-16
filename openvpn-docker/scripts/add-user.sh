#!/bin/bash
# Create a new VPN user: generates certificate, TOTP secret, and .ovpn profile.
# Usage: add-user.sh <username>
set -euo pipefail

USERNAME="${1:?Usage: add-user.sh <username>}"

# Sanitize username: alphanumeric + hyphens only
if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_.@-]{2,64}$ ]]; then
    echo "ERROR: Username must be 2-64 characters (letters, digits, . _ @ -)." >&2
    exit 1
fi

EASYRSA=/usr/share/easy-rsa/easyrsa
export EASYRSA_PKI=/data/pki
export EASYRSA_BATCH=1
: "${EASYRSA_CERT_EXPIRE:=825}"
export EASYRSA_CERT_EXPIRE

log() { echo "[add-user] $*"; }

# Check if user cert already exists and isn't revoked
if [[ -f "${EASYRSA_PKI}/issued/${USERNAME}.crt" ]]; then
    echo "ERROR: Certificate for '${USERNAME}' already exists. Revoke it first with revoke-user.sh." >&2
    exit 1
fi

log "Generating certificate for '${USERNAME}'..."
"$EASYRSA" build-client-full "${USERNAME}" nopass

log "Setting up TOTP for '${USERNAME}'..."
/etc/openvpn/scripts/setup-totp.sh "${USERNAME}"

log "Generating profiles..."
/etc/openvpn/scripts/gen-client-config.sh "${USERNAME}" full
/etc/openvpn/scripts/gen-client-config.sh "${USERNAME}" split

# Clean up any legacy single-profile file from older versions
rm -f "/data/clients/${USERNAME}.ovpn"

log ""
log "User '${USERNAME}' created successfully."
log "  Full tunnel : /data/clients/${USERNAME}-full.ovpn  (all traffic via VPN)"
log "  Split tunnel: /data/clients/${USERNAME}-split.ovpn (only VPN routes)"
log "  TOTP        : /data/users/${USERNAME}/totp.secret"
log ""
log "Send the appropriate .ovpn profile to the user."
log "They must scan the QR code shown above before first connection."
