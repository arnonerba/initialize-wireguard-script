#!/usr/bin/env bash

################################################################################
# This bash script is designed to initialize a fresh Ubuntu 19.10+ VPS as a    #
# WireGuard VPN server. It also replaces ufw with iptables.                    #
################################################################################
# Thanks to:                                                                   #
# https://www.ckn.io/blog/2017/11/14/wireguard-vpn-typical-setup/              #
# https://www.stavros.io/posts/how-to-configure-wireguard/                     #
# https://wiki.archlinux.org/index.php/WireGuard                               #
################################################################################

if [ "$(id -u)" -ne 0 ]; then
	echo "This script must be run as root."
	exit 1
fi

################################################################################
# Step 1: Install iptables and purge all existing rules                        #
################################################################################

apt -y purge ufw
apt -y install iptables iptables-persistent

iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

declare -a IPV4_TABLES=("filter" "nat" "mangle" "raw" "security")
for TABLE in "${IPV4_TABLES[@]}"; do
	iptables -t "$TABLE" -F
	iptables -t "$TABLE" -X
done

ip6tables -P INPUT ACCEPT
ip6tables -P FORWARD ACCEPT
ip6tables -P OUTPUT ACCEPT

declare -a IPV6_TABLES=("filter" "raw")
for TABLE in "${IPV6_TABLES[@]}"; do
	ip6tables -t "$TABLE" -F
	ip6tables -t "$TABLE" -X
done

netfilter-persistent save

################################################################################
# Step 2: Configure minimal, sane default firewall rules                       #
################################################################################

read -p "Enter the name of your server's SSH interface: " SSH_INT

iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p icmp -m icmp --icmp-type 8 -j ACCEPT
iptables -A INPUT -i "$SSH_INT" -p tcp -m multiport --dports 22 -m state --state NEW -j ACCEPT
iptables -P INPUT DROP
iptables -P FORWARD DROP

ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP

netfilter-persistent save

################################################################################
# Step 3: Install and configure WireGuard                                      #
################################################################################

apt -y install wireguard

umask 0077

wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey

read -p "Enter the name of your server's public interface: " PUBLIC_INT

{
	echo "[Interface]"
	echo "PrivateKey = $(</etc/wireguard/privatekey)"
	echo "Address = 10.1.1.1/24"
	echo "ListenPort = 51820"
	echo "PostUp = iptables -A INPUT -i $PUBLIC_INT -p udp -m multiport --dports 51820 -m state --state NEW -j ACCEPT; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.1.1.0/24 -j MASQUERADE; iptables -A INPUT -i wg0 -p udp -m multiport --dports 53 -m state --state NEW -j ACCEPT; iptables -A INPUT -i wg0 -p tcp -m multiport --dports 53 -m state --state NEW -j ACCEPT; systemctl start unbound"
	echo "PostDown = iptables -D INPUT -i $PUBLIC_INT -p udp -m multiport --dports 51820 -m state --state NEW -j ACCEPT; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.1.1.0/24 -j MASQUERADE; iptables -D INPUT -i wg0 -p udp -m multiport --dports 53 -m state --state NEW -j ACCEPT; iptables -D INPUT -i wg0 -p tcp -m multiport --dports 53 -m state --state NEW -j ACCEPT; systemctl stop unbound"
} > /etc/wireguard/wg0.conf

umask 0022

systemctl enable wg-quick@wg0

################################################################################
# Step 4: Enable kernel IP forwarding                                          #
################################################################################

sed --in-place --follow-symlinks 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.d/99-sysctl.conf

################################################################################
# Step 5: Install and configure Unbound                                        #
################################################################################

apt -y install unbound unbound-host

systemctl enable unbound

wget -O /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache

{
	echo "server:"
	echo "interface: 10.1.1.1"
	echo "access-control: 0.0.0.0/0 refuse"
	echo "access-control: ::0/0 refuse"
	echo "access-control: 10.1.1.0/24 allow"
	echo "private-address: 10.1.1.0/24"
	echo "hide-identity: yes"
	echo "hide-version: yes"
	echo "qname-minimisation: yes"
	echo "root-hints: \"/var/lib/unbound/root.hints\""
	echo "auto-trust-anchor-file: \"/var/lib/unbound/root.key\""
} > /etc/unbound/unbound.conf

################################################################################
# Step 6: Configure peers                                                      #
################################################################################

echo
echo "All done. Please reboot this server to bring up the VPN interface."
echo
echo "To authorize a client to connect to this VPN server, add the following lines to /etc/wireguard/wg0.conf:"
echo
echo "[Peer]"
echo "PublicKey = <client_public_key>"
echo "AllowedIPs = <client_IP_address>/32"
echo
echo "To configure the client, use these settings:"
echo
echo "[Interface]"
echo "PrivateKey = <client_private_key>"
echo "Address = <client_IP_address>/24"
echo "DNS = 10.1.1.1"
echo "[Peer]"
echo "PublicKey = $(</etc/wireguard/publickey)"
echo "Endpoint = <server_public_IP_address>:51820"
echo "AllowedIPs = 0.0.0.0/0, ::/0"
echo "PersistentKeepalive = 25"
