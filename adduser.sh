#!/bin/bash
# Create ovpn file for a new connection
if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit 1
fi

read -p "Client name: " -e -i newclient CLIENT
cd /etc/openvpn/easy-rsa/
./easyrsa build-client-full $CLIENT nopass

cp /etc/openvpn/client-template.txt /root/$CLIENT.ovpn
echo "<ca>" >> $homeDir/$1.ovpn
cat /etc/openvpn/easy-rsa/pki/ca.crt >> /root/$CLIENT.ovpn
echo "</ca>" >> /root/$CLIENT.ovpn
echo "<cert>" >> /root/$CLIENT.ovpn
cat /etc/openvpn/easy-rsa/pki/issued/$CLIENT.crt >> /root/$CLIENT.ovpn
echo "</cert>" >> /root/$CLIENT.ovpn
echo "<key>" >> /root/$CLIENT.ovpn
cat /etc/openvpn/easy-rsa/pki/private/$CLIENT.key >> /root/$CLIENT.ovpn
echo "</key>" >> /root/$CLIENT.ovpn
echo "key-direction 1" >> /root/$CLIENT.ovpn