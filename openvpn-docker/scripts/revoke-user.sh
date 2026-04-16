#!/bin/bash
# Revoke a VPN user's certificate and immediately reload OpenVPN's CRL.
# Usage: revoke-user.sh <username>
set -euo pipefail

USERNAME="${1:?Usage: revoke-user.sh <username>}"

EASYRSA=/usr/share/easy-rsa/easyrsa
export EASYRSA_PKI=/data/pki
export EASYRSA_BATCH=1

log() { echo "[revoke-user] $*"; }

if [[ ! -f "${EASYRSA_PKI}/issued/${USERNAME}.crt" ]]; then
    echo "ERROR: No certificate found for '${USERNAME}'." >&2
    exit 1
fi

log "Revoking certificate for '${USERNAME}'..."
"$EASYRSA" revoke "${USERNAME}"

log "Regenerating CRL..."
"$EASYRSA" gen-crl
chmod 644 "${EASYRSA_PKI}/crl.pem"

# Remove CCD entry if present
rm -f "/data/ccd/${USERNAME}"

# Remove all client profiles (full, split, and any legacy single profile)
rm -f "/data/clients/${USERNAME}-full.ovpn" \
      "/data/clients/${USERNAME}-split.ovpn" \
      "/data/clients/${USERNAME}.ovpn"

# Signal OpenVPN to reload (SIGUSR1 = soft-restart, reloads CRL and config)
if pgrep openvpn > /dev/null 2>&1; then
    log "Signaling OpenVPN to reload CRL..."
    pkill -SIGUSR1 openvpn
fi

log "User '${USERNAME}' revoked. All active sessions will be terminated on next keepalive timeout."
log ""
log "To also remove TOTP secret and user data: rm -rf /data/users/${USERNAME}"
