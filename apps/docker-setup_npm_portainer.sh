#!/bin/bash

############################
#
# Check interface name, line 101
#
############################
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

# Define directories and Docker Compose files
NPM_DIR="/data/stacks/npm"
PORTAINER_DIR="/data/stacks/portainer"

# Stop services
echo "Stopping and removing existing containers..."
sudo -u debian docker compose -f ${NPM_DIR}/docker-compose.yml down
sudo -u debian docker compose -f ${PORTAINER_DIR}/docker-compose.yml down


# Define variables
BACKUP_DIR="/data/_backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR" && echo "$BACKUP_DIR created" || echo "$BACKUP_DIR already existed"

# Create the compressed backup, including all files and hidden files
tar -czvf "$BACKUP_DIR/backup_portainer_$TIMESTAMP.tar.gz" -C ${PORTAINER_DIR} . >/dev/null
tar -czvf "$BACKUP_DIR/backup_npm_$TIMESTAMP.tar.gz" -C ${NPM_DIR} . >/dev/null

echo "Backup completed: $BACKUP_FILE"



# Create necessary directories
mkdir -p ${NPM_DIR} ${PORTAINER_DIR} && echo "Dirs created" || echo "Dirs already existed"

# Create Docker Compose files
cat > ${NPM_DIR}/docker-compose.yml <<EOL
services:
  npm:
    image: jc21/nginx-proxy-manager:2.12.1
    container_name: npm
    restart: unless-stopped
    networks:
      - proxy-10-net
      - proxy-20-net
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      - TZ=Europe/Warsaw
    ports:
      - 81:81
      - 80:80
      - 443:443

networks:
  proxy-10-net:
    external: true
    name: proxy-10-net

  proxy-20-net:
    external: true
    name: proxy-20-net
EOL


cat > ${PORTAINER_DIR}/docker-compose.yml <<EOL
services:
  portainer:
    image: portainer/portainer-ce:2.39.4-alpine
    container_name: portainer
    restart: unless-stopped
    environment:
      - TZ=Europe/Warsaw
    networks:
      - proxy-20-net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data

networks:
  proxy-20-net:
    external: true
    name: proxy-20-net
EOL

# Create Docker networks
docker network rm proxy-10-net || true # Remove existing network if any
sudo -u debian docker network create \
        --driver bridge \
        --opt com.docker.network.bridge.name=br-proxy-lan \
        proxy-10-net


# Create Docker networks
docker network rm proxy-net || true  # Remove existing network if any
sudo -u debian docker network create \
        --driver bridge \
        --opt com.docker.network.bridge.name=br-proxy-server \
        proxy-20-net

echo "Starting services..."
cd ${NPM_DIR}
sudo -u debian docker compose -f ${NPM_DIR}/docker-compose.yml up -d --remove-orphans
cd ${PORTAINER_DIR}
sudo -u debian docker compose -f ${PORTAINER_DIR}/docker-compose.yml up -d --remove-orphans

# Check the status
echo "Checking container status..."
sudo -u debian docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
sleep 3
# Check logs for potential errors
echo "Checking nginx-proxy-manager logs..."
sudo -u debian docker logs npm

echo "Checking portainer logs..."
sudo -u debian docker logs portainer

echo "Deployment completed."