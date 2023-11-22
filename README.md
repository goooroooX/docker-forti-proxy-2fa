# docker-forti-proxy-2fa
This docker image proxies specific tcp ports across a Fortinet VPN to remote host using
[openfortivpn](https://github.com/adrienverge/openfortivpn)
and [socat](http://www.dest-unreach.org/socat/). 
SOCKS5 proxy is also available in container and served by [glider](https://github.com/nadoo/glider) on port 8443 by default.

This work is based on following projects:
 * [openfortivpn-haproxy](https://github.com/jeffre/openfortivpn-haproxy) - base, with changes enabling easy 2FA authentication for Fortinet VPN
 * [docker-fortivpn-socks5](https://github.com/Tosainu/docker-fortivpn-socks5) - glider build
 * [docker-forticlient-with-proxy](https://github.com/henry42/docker-forticlient-with-proxy) - setup masquerade
 
This work is focused on 2FA-only authentication and expect a text file to be written with 2FA code prior to VPN executing:
 * VPN is not starting with container
 * 'inotifywait' is looking for any writes (close_write,moved_to,create) in specific folder
 * when new 2FA token is available in '2fa.txt' file, any existent VPN instance is terminated and new one connected using provided username+password+token
 * no automatic restart for VPN service

# Create docker image
1. Clone this repository

        git clone https://github.com/gooorooox/docker-forti-proxy-2fa

2. Build the image

        docker build ./docker-forti-proxy-2fa -t "gooorooox/docker-forti-proxy-2fa:latest"

# Deploy docker container

## Configure forwarded ports
To configure forwarded ports, use environment variables with names that start
with `PORT_FORWARD` and contain a special string (outlined below). More than
one port can be forwarded by using a unique variable name (`PORT_FORWARD1`,
`PORT_FORWARD2`, etc). The variable should contain a string that is formatted
like one of the following:
 * `REMOTE_HOST`:`REMOTE_PORT`
 * `LOCAL_PORT`:`REMOTE_HOST`:`REMOTE_PORT`
 * `PROTOCOL`:`LOCAL_PORT`:`REMOTE_HOST`:`REMOTE_PORT`

`REMOTE_HOST` is a public hostname or ip address (note that a current limitations prevents the hostname from being resolved within the VPN)  
`REMOTE_PORT` an integer between 1-65535  
`LOCAL_PORT` an integer between 1-65535. If omitted, port 1111 is used.  
`PROTOCOL` either tcp or udp. If omitted, tcp is used.

# Examples

### Sample compose for VPN and SOCKS5 proxy
```
version: "2.3"
services:
  vpn:
    image: gooorooox/docker-forti-proxy-2fa:latest
    container_name: forti_proxy_2fa
    network_mode: bridge
    devices:
      - /dev/net/tun:/dev/net/tun
      - /dev/ppp:/dev/ppp
    volumes:
      - <HOST-SHARED-FOLDER>:/tmp/2fa
    cap_add:
      - NET_ADMIN
    environment:
      - VPN_ADDR=1.1.1.1:443
      - VPN_USER=myusername
      - VPN_PASS=mysecretpassword
      - VPN_TIMEOUT=90
      - VPN_2FA_DIR=/tmp/2fa/
      - VPN_2FA_FILE=/tmp/2fa/2fa.txt
      - SOCKS_PROXY_PORT=8443
    ports:
      - 8443:8443/tcp
    expose:
      - 8443
    restart: "unless-stopped"
```
Once connected, SOCKS5 proxy will be running on port 8443.
At this point VPN is not started yet, you need to enter a token to '/tmp/2fa/2fa.txt' file.
Once token is provided, you can check your VPN connection with following command:
```
curl -x http://<HOST-IP>:8443 --insecure -I https://<VPN-ONLY-IP>
```
### Batch script to enter token/start VPN
```
@echo off
TITLE FortiVPN 2FA
set FILE_PATH=x:\shared_folder\vpn\2fa.txt
set /P sec_token="Enter token (6 digits):"
echo %sec_token% > %FILE_PATH%
echo OK
```

