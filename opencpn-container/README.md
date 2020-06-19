# Openvpn container

## Run
* Windows
`docker run -d -v %cd%:/etc/openvpn --privileged -p 1194:1194/udp --restart always openvpn-container`
* Linux\OSX
`docker run -d -v ${pwd}:/etc/openvpn --privileged -p 1194:1194/udp --restart always openvpn-container`