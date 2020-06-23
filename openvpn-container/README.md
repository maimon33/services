# Openvpn container

Simple container that runs Openvpn server.
Once a client connects. The user has access to resources in server's LAN and uses the connection as full tunnel proxy.

Run output generates two elements:
* Server configuration folder based on current working directory
* client configuration file. AKA client.ovpn

## Run
* Windows

`docker run -d -v %cd%:/etc/openvpn -e NETWORK="192.168.0.0/24" -p 1194:1194/udp --privileged --restart on-failure openvpn-container`
* Linux\OSX

`docker run -d -v ${pwd}:/etc/openvpn -e NETWORK="192.168.0.0/24" -p 1194:1194/udp --privileged --restart on-failure openvpn-container`