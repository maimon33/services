#!/bin/bash
# List all VPN users and their cert status.
set -euo pipefail

EASYRSA=/usr/share/easy-rsa/easyrsa
export EASYRSA_PKI=/data/pki

ISSUED_DIR="${EASYRSA_PKI}/issued"

if [[ ! -d "$ISSUED_DIR" ]]; then
    echo "PKI not initialized."
    exit 1
fi

printf "%-30s %-10s %-26s %-26s\n" "USERNAME" "STATUS" "NOT BEFORE" "NOT AFTER"
printf "%-30s %-10s %-26s %-26s\n" "--------" "------" "----------" "---------"

for cert in "${ISSUED_DIR}"/*.crt; do
    [[ -e "$cert" ]] || continue
    cn=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/.*CN=//' | sed 's/,.*//')
    [[ "$cn" == "server" ]] && continue

    not_before=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d= -f2)
    not_after=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)

    # Check CRL for revocation
    serial=$(openssl x509 -in "$cert" -noout -serial 2>/dev/null | cut -d= -f2)
    status="VALID"
    if openssl crl -in "${EASYRSA_PKI}/crl.pem" -noout -text 2>/dev/null | grep -qi "$serial"; then
        status="REVOKED"
    fi

    # Check if TOTP is configured
    totp_status=""
    [[ -f "/data/users/${cn}/totp.secret" ]] && totp_status=" [MFA]"

    printf "%-30s %-10s %-26s %-26s%s\n" "$cn" "$status" "$not_before" "$not_after" "$totp_status"
done
