#!/bin/bash

echo "Installing Graylog Sidecar..."

GRAYLOG_ADDRESS=""
GRAYLOG_PORT="9000"
GRAYLOG_TOKEN=""
GRAYLOG_TAG=""

if [ -z "$GRAYLOG_ADDRESS" ]; then
    read -p "Enter Graylog server address (IP or domain): " GRAYLOG_ADDRESS
fi

if [ -z "$GRAYLOG_PORT" ]; then
    read -p "Enter Graylog server address (IP or domain): " GRAYLOG_PORT
fi

if [ -z "$GRAYLOG_TOKEN" ]; then
    read -p "Enter Graylog server address (IP or domain): " GRAYLOG_TOKEN
fi

if [ -z "$GRAYLOG_TAG" ]; then
    read -p "Enter Graylog server address (IP or domain): " GRAYLOG_TAG
fi


echo "Installing Graylog Sidecar..."
wget https://packages.graylog2.org/repo/packages/graylog-sidecar-repository_1-5_all.deb > /dev/null 2>&1
sudo dpkg -i graylog-sidecar-repository_1-5_all.deb > /dev/null 2>&1
sudo apt-get update > /dev/null 2>&1
sudo apt-get install graylog-sidecar > /dev/null 2>&1
sudo graylog-sidecar -service install > /dev/null 2>&1
systemctl enable graylog-sidecar
systemctl start graylog-sidecar

cat <<EOF | sudo tee /etc/graylog/sidecar/sidecar.yml >/dev/null
server_url: http://${GRAYLOG_ADDRESS}:${GRAYLOG_PORT}/api/
server_api_token: "${GRAYLOG_TOKEN}"
node_id: "${HOSTNAME}"
tags:
  - linux
  - ${GRAYLOG_TAG}
EOF

systemctl restart graylog-sidecar


rm graylog-sidecar-repository_1-5_all.deb

echo "Installation and configuration complete."
