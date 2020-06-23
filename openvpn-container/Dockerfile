FROM ubuntu:20.04

ENV NETWORK=""

RUN apt update \
	&& apt install iproute2 wget curl openvpn openssl ca-certificates iptables -y

COPY init-openvpn.sh init-openvpn.sh

ENTRYPOINT ["/bin/bash", "-c", "./init-openvpn.sh"]