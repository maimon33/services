FROM fnndsc/ubuntu-python3

ENV NETWORK=""
ENV SERVER_ADDRESS=""

RUN apt update \
	&& apt install iproute2 wget curl openvpn openssl ca-certificates iptables nginx supervisor -y

RUN mkdir -p /var/lock/apache2 /var/run/apache2 /var/log/supervisor
RUN echo 'root:password' | chpasswd

COPY init-openvpn.sh init-openvpn.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

ADD nginx.conf /etc/nginx/nginx.conf
# ADD ./www /www

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
