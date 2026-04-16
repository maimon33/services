#!/bin/bash
# Generate a self-contained .ovpn profile for a user.
# Usage: gen-client-config.sh <username> <full|split>
#
# full  — all traffic routed through VPN (redirect-gateway def1)
# split — only routes from routes.conf; ignores redirect-gateway push
set -euo pipefail

USERNAME="${1:?Usage: gen-client-config.sh <username> <full|split>}"
TUNNEL_TYPE="${2:?Usage: gen-client-config.sh <username> <full|split>}"

if [[ "$TUNNEL_TYPE" != "full" && "$TUNNEL_TYPE" != "split" ]]; then
    echo "ERROR: tunnel type must be 'full' or 'split'" >&2
    exit 1
fi

: "${SERVER_NAME:?SERVER_NAME env var is required}"
: "${OPENVPN_PORT:=1194}"
: "${OPENVPN_PROTO:=udp}"
: "${VPN_PROFILE_NAME:=${TOTP_ISSUER:-VPN}}"
: "${VPN_EMBED_USERNAME:=true}"

PKI=/data/pki
CLIENTS_DIR=/data/clients
mkdir -p "$CLIENTS_DIR"

PROFILE="${CLIENTS_DIR}/${USERNAME}-${TUNNEL_TYPE}.ovpn"

if [[ ! -f "${PKI}/issued/${USERNAME}.crt" ]]; then
    echo "ERROR: No certificate found for '${USERNAME}'. Run add-user.sh first." >&2
    exit 1
fi

DISPLAY_NAME="${VPN_PROFILE_NAME} - $([ "$TUNNEL_TYPE" = "full" ] && echo "Full" || echo "Split")"

# Split tunnel: accept server-pushed routes but ignore the redirect-gateway directive
SPLIT_TUNNEL_OPTION=""
if [[ "$TUNNEL_TYPE" == "split" ]]; then
    SPLIT_TUNNEL_OPTION="# Split tunnel — only routes.conf entries go through VPN
pull-filter ignore \"redirect-gateway\""
fi

# Optionally embed username so clients pre-fill it (password/TOTP still prompted)
# NOTE: Only put the username on line 1 — no empty line 2, or OpenVPN skips the password prompt.
EMBEDDED_USERNAME_BLOCK=""
if [[ "$VPN_EMBED_USERNAME" == "true" ]]; then
    EMBEDDED_USERNAME_BLOCK="# Pre-filled username — password (TOTP code) is still prompted on connect
<auth-user-pass>
${USERNAME}
</auth-user-pass>"
fi

cat > "$PROFILE" << EOF
# ${DISPLAY_NAME}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Profile display name (overrides "server [filename]" label in OpenVPN Connect)
setenv FRIENDLY_NAME "${DISPLAY_NAME}"

client
dev tun
proto ${OPENVPN_PROTO}
remote ${SERVER_NAME} ${OPENVPN_PORT}
resolv-retry infinite
nobind

persist-key
persist-tun

# Certificate verification
remote-cert-tls server
verify-x509-name server name

# Crypto — must match server.conf
cipher AES-256-GCM
auth   SHA256
tls-version-min 1.2

${SPLIT_TUNNEL_OPTION}

# MFA: password = 6-digit TOTP code from your authenticator app
${EMBEDDED_USERNAME_BLOCK:-auth-user-pass}

key-direction 1
verb 3

<ca>
$(cat "${PKI}/ca.crt")
</ca>

<cert>
$(openssl x509 -in "${PKI}/issued/${USERNAME}.crt")
</cert>

<key>
$(cat "${PKI}/private/${USERNAME}.key")
</key>

<tls-crypt>
$(cat "${PKI}/tc.key")
</tls-crypt>
EOF

chmod 600 "$PROFILE"
echo "[gen-client-config] ${DISPLAY_NAME} → ${PROFILE}"
