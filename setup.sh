#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Define variables
TIMEZONE="America/New_York"
DUCKDNS_SUBDOMAIN="your-subdomain"       # Replace with your DuckDNS subdomain
DUCKDNS_TOKEN="your-duckdns-token"       # Replace with your DuckDNS token
MYSQL_USER="npm"
MYSQL_PASSWORD="npm"
PUID=1000
PGID=1000
USER_NAME="pi"

# Update and upgrade the system
echo "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y

# Install Docker
echo "Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Install Docker Compose
echo "Installing Docker Compose..."
sudo apt-get install -y docker-compose

# Add current user to the docker group
echo "Adding user to docker group..."
sudo usermod -aG docker $USER

# Clone the repository
echo "Cloning the media server repository..."
cd ~
git clone https://github.com/LucasACH/raspberry-pi-media-server.git
cd raspberry-pi-media-server

# Configure .env files for each stack
echo "Configuring environment variables..."

# Tools stack
cat <<EOF > tools/.env
USER=$USER_NAME
TZ=$TIMEZONE
EOF

# Monitoring stack
cat <<EOF > monitoring/.env
USER=$USER_NAME
EOF

# Seedbox stack
cat <<EOF > seedbox/.env
USER=$USER_NAME
PUID=$PUID
PGID=$PGID
TZ=$TIMEZONE
EOF

# Web stack
cat <<EOF > web/.env
USER=$USER_NAME
PUID=$PUID
PGID=$PGID
TZ=$TIMEZONE
SUBDOMAINS=$DUCKDNS_SUBDOMAIN
DUCKDNS_TOKEN=$DUCKDNS_TOKEN
DB_MYSQL_USER=$MYSQL_USER
DB_MYSQL_PASSWORD=$MYSQL_PASSWORD
EOF

# Create necessary directories for media storage
echo "Creating media directories..."
sudo mkdir -p /data/torrents /data/movies /data/tv
sudo chown -R $USER_NAME:$USER_NAME /data

# Deploy Docker stacks
echo "Deploying Docker stacks..."

# Tools stack
cd tools
docker-compose up -d
cd ..

# Monitoring stack
cd monitoring
docker-compose up -d
cd ..

# Seedbox stack
cd seedbox
docker-compose up -d
cd ..

# Web stack
cd web
docker-compose up -d
cd ..

echo "Media server setup complete!"
echo "Access your services at the following URLs (replace <your_pi_ip> with your Raspberry Pi's IP address):"
echo "Portainer: http://<your_pi_ip>:9000"
echo "Grafana: http://<your_pi_ip>:3030"
echo "Deluge: http://<your_pi_ip>:8112"
echo "Jackett: http://<your_pi_ip>:9117"
echo "Radarr: http://<your_pi_ip>:7878"
echo "Sonarr: http://<your_pi_ip>:8989"
echo "Jellyfin: http://<your_pi_ip>:8096"
echo "Nginx Proxy Manager: http://<your_pi_ip>:81"
