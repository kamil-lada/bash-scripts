#!/bin/bash

############################
#
# Check interface name, line 101
#
############################

# Define directories and Docker Compose files
NPM_DIR="/data/npm"
PORTAINER_DIR="/data/portainer"

# Stop services
echo "Stopping and removing existing containers..."
docker compose -f ${NPM_DIR}/docker-compose.yml down
docker compose -f ${PORTAINER_DIR}/docker-compose.yml down


# Define variables
BACKUP_DIR="/data/_backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Create the compressed backup, including all files and hidden files
tar -czvf "$BACKUP_DIR/backup_portainer_$TIMESTAMP.tar.gz" -C ${PORTAINER_DIR} . >/dev/null
tar -czvf "$BACKUP_DIR/backup_npm_$TIMESTAMP.tar.gz" -C ${NPM_DIR} . >/dev/null

# Optional: Remove old backups (e.g., keep only the last 7 backups)
find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +7 -exec rm {} \;

echo "Backup completed: $BACKUP_FILE"



# Create necessary directories
mkdir -p ${NPM_DIR} ${PORTAINER_DIR}

# Create Docker Compose files
cat > ${NPM_DIR}/docker-compose.yml <<EOL
services:
  npm:
    image: jc21/nginx-proxy-manager:2.11.3
    container_name: npm
    restart: unless-stopped
    networks:
      - app-net
      - proxy-net
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      - DB_SQLITE_FILE=/data/database.sqlite
    ports:
      - 81:81
      - 80:80
      - 443:443

networks:
  app-net:
    external: true
    name: app-net

  proxy-net:
    external: true
    name: proxy-net
EOL

cat > ${PORTAINER_DIR}/docker-compose.yml <<EOL
services:
  portainer:
    image: portainer/portainer-ce:2.20.3
    container_name: portainer
    restart: unless-stopped
    networks:
      - app-net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data

networks:
  app-net:
    external: true
    name: app-net
EOL

# Create Docker networks
docker network rm app-net || true # Remove existing network if any
docker network create \
        --driver bridge \
        --opt com.docker.network.bridge.name=br-app \
        app-net


# Create Docker networks
docker network rm proxy-net || true  # Remove existing network if any
docker network create \
        --driver bridge \
        --opt com.docker.network.bridge.name=br-proxy \
        -o parent=eth0 \
        proxy-net

echo "Starting services..."
docker compose -f ${NPM_DIR}/docker-compose.yml up -d --remove-orphans
docker compose -f ${PORTAINER_DIR}/docker-compose.yml up -d --remove-orphans

# Check the status
echo "Checking container status..."
docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
sleep 3
# Check logs for potential errors
echo "Checking nginx-proxy-manager logs..."
docker logs npm

echo "Checking portainer logs..."
docker logs portainer

echo "Deployment completed."