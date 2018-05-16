#!/bin/bash
if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit 1
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "TUN is not available"
	exit 2
fi

if [[ -e /etc/openvpn/server.conf ]]; then
	echo "OpenVPN is already installed, exiting"
	exit 3
fi

RSA_KEY_SIZE=4096
DH_KEY_SIZE=4096
CLIENT="shortcut"
SYSCTL='/etc/sysctl.conf'
IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)


echo "Installing OpenVPN and dependencies..."

apt-get install ca-certificates gnupg -y
apt-get install openvpn iptables openssl wget ca-certificates curl -y
# Install iptables service
if [[ ! -e /etc/systemd/system/iptables.service ]]; then
	mkdir /etc/iptables
	iptables-save > /etc/iptables/iptables.rules
	echo "#!/bin/sh
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT" > /etc/iptables/flush-iptables.sh
	chmod +x /etc/iptables/flush-iptables.sh
	echo "[Unit]
Description=Packet Filtering Framework
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/iptables.rules
ExecReload=/sbin/iptables-restore /etc/iptables/iptables.rules
ExecStop=/etc/iptables/flush-iptables.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" > /etc/systemd/system/iptables.service
	systemctl daemon-reload
	systemctl enable iptables.service
fi
if [[ -d /etc/openvpn/easy-rsa/ ]]; then
	rm -rf /etc/openvpn/easy-rsa/
fi

# Download Easy-RSA

wget -O ~/EasyRSA-3.0.4.tgz https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.4/EasyRSA-3.0.4.tgz
tar xzf ~/EasyRSA-3.0.4.tgz -C ~/
mv ~/EasyRSA-3.0.4/ /etc/openvpn/
mv /etc/openvpn/EasyRSA-3.0.4/ /etc/openvpn/easy-rsa/
chown -R root:root /etc/openvpn/easy-rsa/
rm -f ~/EasyRSA-3.0.4.tgz
cd /etc/openvpn/easy-rsa/
# Generate a random, alphanumeric identifier of 16 characters for CN and one for server name
SERVER_CN="cn_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
SERVER_NAME="server_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
echo "set_var EASYRSA_KEY_SIZE $RSA_KEY_SIZE" > vars
echo "set_var EASYRSA_REQ_CN $SERVER_CN" >> vars
# Create the PKI, set up the CA, the DH params and the server + client certificates
./easyrsa init-pki
./easyrsa --batch build-ca nopass
openssl dhparam -out dh.pem $DH_KEY_SIZE
./easyrsa build-server-full $SERVER_NAME nopass
# ./easyrsa build-client-full $CLIENT nopass
EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
# generate tls-auth key
openvpn --genkey --secret /etc/openvpn/tls-auth.key
# Move all the generated files
cp pki/ca.crt pki/private/ca.key dh.pem pki/issued/$SERVER_NAME.crt pki/private/$SERVER_NAME.key /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn
# Make cert revocation list readable for non-root
chmod 644 /etc/openvpn/crl.pem

# Generate server.conf

echo 'port 1194
proto tcp
dev tun
user nobody
group nogroup
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
push "redirect-gateway def1 bypass-dhcp"
crl-verify crl.pem
ca ca.crt
' >> /etc/openvpn/server.conf

echo "cert $SERVER_NAME.crt
key $SERVER_NAME.key
" >> /etc/openvpn/server.conf

echo 'dh dh.pem
auth SHA1
cipher AES-128-CBC
tls-server
tls-version-min 1.2
tls-cipher TLS-DHE-RSA-WITH-AES-128-GCM-SHA256
status openvpn.log
verb 3 
' >> /etc/openvpn/server.conf

sed -i '/\<net.ipv4.ip_forward\>/c\net.ipv4.ip_forward=1' $SYSCTL
if ! grep -q "\<net.ipv4.ip_forward\>" $SYSCTL; then
	echo 'net.ipv4.ip_forward=1' >> $SYSCTL
fi
# Avoid an unneeded reboot
echo 1 > /proc/sys/net/ipv4/ip_forward
# Set NAT for the VPN subnet
iptables -t nat -A POSTROUTING -o $NIC -s 10.8.0.0/24 -j MASQUERADE
# Save persitent iptables rules
iptables-save > $IPTABLES

if pgrep systemd-journal; then
		#Workaround to fix OpenVPN service on OpenVZ
		sed -i 's|LimitNPROC|#LimitNPROC|' /lib/systemd/system/openvpn\@.service
		sed -i 's|/etc/openvpn/server|/etc/openvpn|' /lib/systemd/system/openvpn\@.service
		sed -i 's|%i.conf|server.conf|' /lib/systemd/system/openvpn\@.service
		systemctl daemon-reload
		systemctl restart openvpn
		systemctl enable openvpn
else
	/etc/init.d/openvpn restart
fi

# Create client template

echo "client
proto tcp-client
remote $IP 1194
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $SERVER_NAME name
auth SHA256
auth-nocache
cipher AES-128-CBC
tls-client
tls-version-min 1.2
tls-cipher TLS-DHE-RSA-WITH-AES-128-GCM-SHA256
setenv opt block-outside-dns
verb 3
" >> /etc/openvpn/client-template.txt
