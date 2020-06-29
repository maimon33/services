#!/bin/bash
#
# https://github.com/Nyr/openvpn-install
#
# Copyright (c) 2013 Nyr. Released under the MIT License.

export conf_dir="/home/ubuntu/openvpn/server"
export client_dir="/home/ubuntu/openvpn"
export protocol="udp"
export port="1194"
export client="client"

if [ -z "$SERVER_ADDRESS" ]; then
	export SERVER_ADDRESS=$SERVER_ADDRESS
else
	SERVER_ADDRESS=`curl ipinfo.io/ip`
fi

if [[ ! -e /home/ubuntu/openvpn ]]; then
	mkdir -p /home/ubuntu/openvpn
fi

# Discard stdin. Needed when running from an one-liner which includes a newline
read -N 999999 -t 0.001

os="ubuntu"
os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
group_name="nogroup"

# Detect environments where $PATH does not include the sbin directories
if ! grep -q sbin <<< "$PATH"; then
	echo '$PATH does not include sbin. Try using "su -" instead of "su".'
	exit
fi

if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
	echo "The system does not have the TUN device available.
TUN needs to be enabled before running this installer."
	exit
fi

if [ -z "$NETWORK" ]; then
	echo "Must speficy Local LAN Netwrok using 'NETWORK' env"
	exit
fi

new_client () {
	# Generates the custom client.ovpn
	{
	cat $conf_dir/client-common.txt
	echo "<ca>"
	cat $conf_dir/easy-rsa/pki/ca.crt
	echo "</ca>"
	echo "<cert>"
	sed -ne '/BEGIN CERTIFICATE/,$ p' $conf_dir/easy-rsa/pki/issued/"$client".crt
	echo "</cert>"
	echo "<key>"
	cat $conf_dir/easy-rsa/pki/private/"$client".key
	echo "</key>"
	echo "<tls-crypt>"
	sed -ne '/BEGIN OpenVPN Static key/,$ p' $conf_dir/tc.key
	echo "</tls-crypt>"
	} > $client_dir/$client.ovpn
}

define_iptables () {
	set -x
	# Allow inbound to OpenVPN
	iptables -A INPUT -p $protocol --dport $port -j ACCEPT
	
	# Masquerade outgoing traffic
	iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
	iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

	# Allow return traffic
	iptables -A INPUT -i eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
	iptables -A INPUT -i tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

	# Forward everything
	iptables -A FORWARD -j ACCEPT
	
	# Allow bidirectional traffic to internal network
	iptables -A INPUT -p all -s $NETWORK -j ACCEPT
	iptables -A INPUT -p all -s 10.8.0.0/24 -j ACCEPT

	# VPN
	## Allow traffic initiated from VPN to access LAN
	iptables -A FORWARD -i tun0 -s 10.8.0.0/24 -d $NETWORK -m conntrack --ctstate NEW -j ACCEPT
	## Allow established traffic to pass back and forth
	iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

	iptables -A User-Firewall -j REJECT --reject-with icmp-host-prohibited
	set +x
}

if [[ ! -e $conf_dir/server.conf ]]; then
	clear
	echo 'Welcome to this OpenVPN road warrior installer!'
	# If system has a single IPv4, it is selected automatically. Else, ask the user
	ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')

	# Get easy-rsa
	easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.7/EasyRSA-3.0.7.tgz'
	mkdir -p $conf_dir/easy-rsa/
	{ wget -qO- "$easy_rsa_url" 2>/dev/null || curl -sL "$easy_rsa_url" ; } | tar xz -C $conf_dir/easy-rsa/ --strip-components 1
	chown -R root:root $conf_dir/easy-rsa/
	cd $conf_dir/easy-rsa/
	# Create the PKI, set up the CA and the server and client certificates
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-server-full server nopass
	EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full "$client" nopass
	EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem $conf_dir
	# CRL is read with each client connection, while OpenVPN is dropped to nobody
	chown nobody:"$group_name" $conf_dir/crl.pem
	# Without +x in the directory, OpenVPN can't run a stat() on the CRL file
	chmod o+x $conf_dir/
	# Generate key for tls-crypt
	openvpn --genkey --secret $conf_dir/tc.key
	# Create the DH parameters file using the predefined ffdhe2048 group
	echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > $conf_dir/dh.pem
	# Generate server.conf
	echo "local $ip
port $port
proto $protocol
dev tun
ca $conf_dir/ca.crt
cert $conf_dir/server.crt
key $conf_dir/server.key
dh $conf_dir/dh.pem
auth SHA512
tls-crypt $conf_dir/tc.key
topology subnet
server 10.8.0.0 255.255.255.0" > $conf_dir/server.conf
	# IPv6
	if [[ -z "$ip6" ]]; then
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> $conf_dir/server.conf
	else
		echo 'server-ipv6 fddd:1194:1194:1194::/64' >> $conf_dir/server.conf
		echo 'push "redirect-gateway def1 ipv6 bypass-dhcp"' >> $conf_dir/server.conf
	fi
	echo 'ifconfig-pool-persist ipp.txt' >> $conf_dir/server.conf
	
	# DNS
	echo 'push "dhcp-option DNS 8.8.8.8"' >> $conf_dir/server.conf
	echo 'push "dhcp-option DNS 8.8.4.4"' >> $conf_dir/server.conf

	echo "keepalive 10 120
cipher AES-256-CBC
user nobody
group $group_name
persist-key
persist-tun
status $conf_dir/openvpn-status.log
verb 3
crl-verify $conf_dir/crl.pem" >> $conf_dir/server.conf
	if [[ "$protocol" = "udp" ]]; then
		echo "explicit-exit-notify" >> $conf_dir/server.conf
	fi
	# Enable net.ipv4.ip_forward for the system
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/30-openvpn-forward.conf

	define_iptables


	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
proto $protocol
remote $SERVER_ADDRESS $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
ignore-unknown-option block-outside-dns
block-outside-dns
verb 3" > $conf_dir/client-common.txt
	# Enable and start the OpenVPN service
	# systemctl enable --now openvpn-server@server.service
	# Generates the custom client.ovpn
	new_client
	echo
	echo "Finished!"
	echo
	echo "The client configuration is available in: $client_dir/$client.ovpn"
	echo "New clients can be added by running this script again."

	echo "Starting openvpn"
	openvpn --config $conf_dir/server.conf
else
	echo "Server is already configured..."
	echo "Starting openvpn"
	openvpn --config $conf_dir/server.conf
fi