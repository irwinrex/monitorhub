# monitorhub
This repo contains monitoring tools

## To Install Minikube
``` 
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
```

## To start and more for minikube 
```
minikube start driver=docker
minikube stop
minikube delete
```

## To install Helm
```
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

## To Search helm hub

helm search hub prometheus
helm search hub grafana

## Deploy ELK
```
docker compose -f ELK.yml up
hit browser localhost(or)serverip:5601
docker exec -it es bash
bin/elasticsearch-create-enrollment-token --scope kibana
```
To Copy the code cntrl+shift+c

```
paste the token in browser
docker exec -it kib bash
bin/kibana-verification-code
paste the token in browser
```

## VPN
Setting Up Wireguard and Wireguard UI with Docker Compose¶
Introduction to Wireguard and Wireguard UI¶
Wireguard is a modern VPN (Virtual Private Network) software that provides fast and secure connections. The Wireguard UI is a web interface that makes it easier to manage your Wireguard setup.

Docker Compose Configuration for Wireguard and Wireguard UI¶
This Docker Compose setup deploys both Wireguard and Wireguard UI in Docker containers, ensuring a secure, isolated environment for your VPN needs.

Docker Compose File (docker-compose.yml)¶
Issue with latest image

There is an issue with the latest image it seems, please make sure you use the image in the example compose below. If you use latest, the steps in this guide will not work.

```
version: "3"

services:

  wireguard:
    image: linuxserver/wireguard:v1.0.20210914-ls7 #Use this image, latest seems to have issues
    container_name: wireguard
    cap_add:
      - NET_ADMIN
    volumes:
      - ./config:/config
    ports:
      - "5000:5000"
      - "51820:51820/udp"

  wireguard-ui:
    image: ngoduykhanh/wireguard-ui:latest
    container_name: wireguard-ui
    depends_on:
      - wireguard
    cap_add:
      - NET_ADMIN
    network_mode: service:wireguard
    environment:
      - SENDGRID_API_KEY
      - EMAIL_FROM_ADDRESS
      - EMAIL_FROM_NAME
      - SESSION_SECRET
      - WGUI_USERNAME=admin
      - WGUI_PASSWORD=password
      - WG_CONF_TEMPLATE
      - WGUI_MANAGE_START=true
      - WGUI_MANAGE_RESTART=true
    logging:
      driver: json-file
      options:
        max-size: 50m
    volumes:
      - ./db:/app/db
      - ./config:/etc/wireguard
```
Key Components of the Configuration¶
Wireguard Service¶
Image: linuxserver/wireguard:v1.0.20210914-ls7.
Capabilities: NET_ADMIN for network management.
Volumes: Maps ./config to /config in the container for configuration storage.
Ports: Exposes port 5000 for web interface and 51820 for UDP traffic.
Wireguard UI Service¶
Image: ngoduykhanh/wireguard-ui:latest.
Dependence: Depends on the wireguard service.
Capabilities: NET_ADMIN for network management.
Network Mode: Uses the network of the wireguard service.
Environment Variables: Configuration for email notifications, session management, and Wireguard UI settings.
Logging: Configures log file size and format.
Volumes: Maps ./db for database storage and ./config for Wireguard configuration.
Deploying Wireguard and Wireguard UI¶
Save the above Docker Compose configuration in a docker-compose.yml file.
Run docker-compose up -d to start the containers in detached mode.
Access Wireguard UI via http://<host-ip>:5000 and configure your VPN.
Configuring and Using Wireguard and Wireguard UI¶
After deployment, use the Wireguard UI to manage your Wireguard VPN settings, including adding and configuring VPN clients.

Post Up¶

iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
Post Down¶

iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
The "Post Up" command and the "Post Down" command are used in the configuration of WireGuard to set up and tear down network routing rules for the WireGuard interface.

The "Post Up" command performs the following actions:

It adds a rule to the FORWARD chain of the iptables firewall to accept incoming traffic on the WireGuard interface (wg0). This allows packets to be forwarded between the WireGuard network and other networks.
It adds a rule to the POSTROUTING chain of the iptables NAT (Network Address Translation) table to perform MASQUERADE on outgoing packets from the WireGuard interface (wg0) before they are sent out through the eth0 interface. MASQUERADE modifies the source IP address of the packets to match the IP address of the eth0 interface, allowing the response packets to be correctly routed back to the WireGuard network.
The "Post Down" command reverses the actions performed by the "Post Up" command:

It deletes the rule from the FORWARD chain of the iptables firewall that accepts incoming traffic on the WireGuard interface (wg0).
It deletes the rule from the POSTROUTING chain of the iptables NAT table that performs MASQUERADE on outgoing packets from the WireGuard interface (wg0).
These commands are typically used when configuring a WireGuard VPN server in scenarios where Network Address Translation (NAT) is involved, such as when the server is behind a router performing NAT.

