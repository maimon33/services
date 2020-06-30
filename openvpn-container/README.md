# Openvpn container

Simple container that runs Openvpn server.<br>Server must be exposed and have inbound allowed to container serving port (defaults to 1194/udp).<br>
Once a client connects, all traffic is routed via server and the user has access to resources in server's LAN and uses the connection as full tunnel proxy.

Run output generates two elements:
* Server configuration folder based on current working directory
* client configuration file. AKA client.ovpn

## Build
Clone repo and build.

```
$ git clone https://github.com/maimon33/services.git
$ cd services/openvpn-container/source
$ docker build . -t openvpn-container`
```

## Run

> You can add the server dns address by using `SERVER_ADDRESS` variable in the run command. if you don't use it the entrypoint will collect the public IP

* Windows

`docker run -d -v %cd%:/etc/openvpn -e NETWORK="192.168.0.0/24" -e SERVER_ADDRESS=my_host.dns.com -p 1194:1194/udp --privileged --restart on-failure openvpn-container`
* Linux\OSX

`docker run -d -v ${pwd}:/etc/openvpn -e NETWORK="192.168.0.0/24" -e SERVER_ADDRESS=my_host.dns.com -p 1194:1194/udp --privileged --restart on-failure openvpn-container`

## Terraform and AWS instance

Use Terraform for one command start server in AWS

### Prerequisite

Connection to AWS instances require SSH key. Use the following command in Windows, OSX and Linux
`ssh-keygen -N "" -f id_rsa`

### Run

```
$ terrafrom init
$ terraform apply
```

### post run

You now will need to collect your ovpn profile.

* Windows

```
$ terraform output openvpn_ip > openvpn_ip && set /p openvpn_ip=<openvpn_ip
$ scp -i id_rsa ubuntu@%openvpn_ip%:/home/ubuntu/openvpn/client.ovpn .
```

* Linux\OSX

```
$ scp -i id_rsa ubuntu@$(terraform output openvpn_ip):/home/ubuntu/openvpn/client.ovpn .
```