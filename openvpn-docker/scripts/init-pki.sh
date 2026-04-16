#!/bin/bash
# First-time PKI and server configuration initializer.
# Runs automatically on first container start when /data/pki/ca.crt is absent.
set -euo pipefail

: "${SERVER_NAME:?SERVER_NAME env var is required}"
: "${OPENVPN_PROTO:=udp}"
: "${VPN_NETWORK:=10.8.0.0}"
: "${VPN_SUBNET:=255.255.255.0}"
: "${PUSH_DNS_1:=1.1.1.1}"
: "${PUSH_DNS_2:=8.8.8.8}"
: "${CA_NAME:=OpenVPN CA}"
: "${EASYRSA_CERT_EXPIRE:=825}"
: "${EASYRSA_CRL_DAYS:=3650}"

EASYRSA=/usr/share/easy-rsa/easyrsa
export EASYRSA_PKI=/data/pki
export EASYRSA_BATCH=1
export EASYRSA_CERT_EXPIRE
export EASYRSA_CRL_DAYS

log() { echo "[init-pki] $*"; }

log "Initializing PKI at ${EASYRSA_PKI}..."
"$EASYRSA" init-pki

log "Building CA (no passphrase)..."
"$EASYRSA" --req-cn="${CA_NAME}" build-ca nopass

log "Building server certificate..."
"$EASYRSA" build-server-full server nopass

log "Generating DH parameters (this may take a minute)..."
"$EASYRSA" gen-dh

log "Generating TLS-crypt key..."
openvpn --genkey secret "${EASYRSA_PKI}/tc.key"

log "Generating initial CRL..."
"$EASYRSA" gen-crl

# Set permissions so OpenVPN (runs as nobody) can read the CRL
chmod 644 "${EASYRSA_PKI}/crl.pem"

log "Writing server.conf from template..."
export EASYRSA_PKI OPENVPN_PROTO VPN_NETWORK VPN_SUBNET PUSH_DNS_1 PUSH_DNS_2

envsubst < /etc/openvpn/config-templates/server.conf.template > /data/server.conf
log "Server config written to /data/server.conf"

# Create empty CCD directory for per-client config overrides
mkdir -p /data/ccd

log "PKI initialization complete."
log ""
log "  CA cert  : ${EASYRSA_PKI}/ca.crt"
log "  Server   : ${EASYRSA_PKI}/issued/server.crt"
log "  TLS-crypt: ${EASYRSA_PKI}/tc.key"
log ""
log "Run 'vpn-add-user <username>' to create your first client."
