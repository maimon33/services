FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openvpn \
    easy-rsa \
    iptables \
    iproute2 \
    dnsutils \
    python3 \
    python3-pyotp \
    qrencode \
    gettext-base \
    curl \
    jq \
    procps \
    && rm -rf /var/lib/apt/lists/*

# EasyRSA lives here on Ubuntu 24.04
ENV EASYRSA=/usr/share/easy-rsa/easyrsa
ENV EASYRSA_PKI=/data/pki
ENV EASYRSA_BATCH=1

COPY scripts/ /etc/openvpn/scripts/
COPY config/  /etc/openvpn/config-templates/

RUN chmod +x /etc/openvpn/scripts/*.sh \
 && ln -s /etc/openvpn/scripts/add-user.sh    /usr/local/bin/vpn-add-user    \
 && ln -s /etc/openvpn/scripts/revoke-user.sh /usr/local/bin/vpn-revoke-user \
 && ln -s /etc/openvpn/scripts/list-users.sh  /usr/local/bin/vpn-list-users  \
 && ln -s /etc/openvpn/scripts/setup-totp.sh  /usr/local/bin/vpn-setup-totp

# Persistent volume: PKI, server config, ccd, user TOTP secrets, logs
VOLUME ["/data"]

EXPOSE 1194/udp

ENTRYPOINT ["/etc/openvpn/scripts/entrypoint.sh"]
