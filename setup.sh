#!/bin/bash

#=============================================================================
# Raspberry Pi Media Server Setup Script
#
# This script automates the setup of a complete media server solution on
# Raspberry Pi with Docker containers for Jellyfin, Deluge, Radarr, Sonarr,
# Jackett, and more with monitoring tools.
#=============================================================================

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Exit immediately if a command exits with a non-zero status
set -e

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to create backup of existing configs
backup_config() {
    if [ -d "raspberry-pi-media-server" ]; then
        print_message "$YELLOW" "Creating backup of current configuration..."
        BACKUP_DIR="raspberry-pi-media-server_backup_$(date +%Y%m%d_%H%M%S)"
        cp -r raspberry-pi-media-server "$BACKUP_DIR"
        print_message "$GREEN" "Backup created at: $BACKUP_DIR"
    fi
}

# Function to get user input with default value
get_input() {
    local prompt=$1
    local default=$2
    local input
    
    echo -e "${BLUE}$prompt [$default]: ${NC}"
    read -r input
    echo "${input:-$default}"
}

# Welcome banner
clear
cat << "EOF"
 _____              _               _____  _   __  __          _ _       _____                          
|  __ \            | |             |  __ \(_) |  \/  |        | (_)     / ____|                         
| |__) |__ _ ___ _ | |__   ___ _ __| |__) |_  | \  / | ___  __| |_ __ _| (___   ___ _ ____   _____ _ __ 
|  _  // _` / __| '_ \ \ / / '_ \  ___/ | | | |\/| |/ _ \/ _` | / _` |\___ \ / _ \ '__\ \ / / _ \ '__|
| | \ \ (_| \__ \ |_) \ V /| |_) | |   | | | |  | |  __/ (_| | | (_| |____) |  __/ |   \ V /  __/ |   
|_|  \_\__,_|___/_.__/ \_/ | .__/|_|   |_| |_|  |_|\___|\__,_|_|\__,_|_____/ \___|_|    \_/ \___|_|   
                          | |                                                                         
                          |_|                                                                         
EOF
print_message "$GREEN" "Welcome to the Raspberry Pi Media Server Setup Script!"
echo ""

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
    print_message "$RED" "This script should not be run directly as root!"
    print_message "$YELLOW" "Please run without sudo, the script will ask for sudo password when needed."
    exit 1
fi

# Check system
print_message "$BLUE" "Checking system prerequisites..."
if ! command_exists apt-get; then
    print_message "$RED" "This script requires a Debian-based distribution (like Raspberry Pi OS)."
    exit 1
fi

# Get user configuration
print_message "$BLUE" "Setting up configuration with default values..."
print_message "$YELLOW" "NOTICE: This is a non-interactive version to avoid stdin hang issues"
echo ""

# Define default values
DEFAULT_TIMEZONE="America/New_York"
DEFAULT_DUCKDNS_SUBDOMAIN="your-subdomain"
DEFAULT_DUCKDNS_TOKEN="your-duckdns-token"
DEFAULT_MYSQL_USER="npm"
DEFAULT_MYSQL_PASSWORD="npm"
DEFAULT_PUID=$(id -u)
DEFAULT_PGID=$(id -g)
DEFAULT_USER_NAME="$USER"
DEFAULT_DATA_PATH="/data"

# Auto-configure with default values to avoid input issues
print_message "$YELLOW" "Using default configuration (modify the script to change values):"
TIMEZONE="$DEFAULT_TIMEZONE"
echo "Timezone: $TIMEZONE"
DUCKDNS_SUBDOMAIN="$DEFAULT_DUCKDNS_SUBDOMAIN"
echo "DuckDNS Subdomain: $DUCKDNS_SUBDOMAIN"
DUCKDNS_TOKEN="$DEFAULT_DUCKDNS_TOKEN"
echo "DuckDNS Token: ${DUCKDNS_TOKEN:0:4}****"
MYSQL_USER="$DEFAULT_MYSQL_USER"
echo "MySQL User: $MYSQL_USER"
MYSQL_PASSWORD="$DEFAULT_MYSQL_PASSWORD"
echo "MySQL Password: ${MYSQL_PASSWORD:0:1}*****"
PUID="$DEFAULT_PUID"
echo "PUID: $PUID"
PGID="$DEFAULT_PGID"
echo "PGID: $PGID"
USER_NAME="$DEFAULT_USER_NAME"
echo "Username: $USER_NAME"
DATA_PATH="$DEFAULT_DATA_PATH"
echo "Data Path: $DATA_PATH"
echo ""

# Skip confirmation to avoid potential stdin issues
print_message "$GREEN" "Proceeding with installation..."

# Create log file
LOG_FILE="media_server_setup_$(date +%Y%m%d_%H%M%S).log"
print_message "$BLUE" "Logs will be saved to $LOG_FILE"

# Update and upgrade the system
print_message "$BLUE" "Updating system packages..."
{
    sudo apt-get update 
    sudo apt-get upgrade -y
} >> "$LOG_FILE" 2>&1 || {
    print_message "$RED" "Failed to update system. Check $LOG_FILE for details."
    exit 1
}

# Install required packages
print_message "$BLUE" "Installing required packages..."
{
    sudo apt-get install -y \
        curl \
        git \
        wget \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        unzip
} >> "$LOG_FILE" 2>&1 || {
    print_message "$RED" "Failed to install required packages. Check $LOG_FILE for details."
    exit 1
}

# Install Docker if not already installed
if ! command_exists docker; then
    print_message "$BLUE" "Installing Docker..."
    {
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
    } >> "$LOG_FILE" 2>&1 || {
        print_message "$RED" "Failed to install Docker. Check $LOG_FILE for details."
        exit 1
    }
else
    print_message "$GREEN" "Docker is already installed!"
fi

# Install Docker Compose if not already installed
if ! command_exists docker-compose; then
    print_message "$BLUE" "Installing Docker Compose..."
    {
        sudo apt-get install -y docker-compose
    } >> "$LOG_FILE" 2>&1 || {
        print_message "$RED" "Failed to install Docker Compose. Check $LOG_FILE for details."
        exit 1
    }
else
    print_message "$GREEN" "Docker Compose is already installed!"
fi

# Add current user to the docker group
print_message "$BLUE" "Adding user to docker group..."
{
    sudo usermod -aG docker "$USER_NAME"
} >> "$LOG_FILE" 2>&1 || {
    print_message "$RED" "Failed to add user to docker group. Check $LOG_FILE for details."
    exit 1
}

# Create backup of existing configuration
backup_config

# Clone the repository
print_message "$BLUE" "Cloning the media server repository..."
{
    cd ~
    if [ -d "raspberry-pi-media-server" ]; then
        cd raspberry-pi-media-server
        git pull
    else
        git clone https://github.com/LucasACH/raspberry-pi-media-server.git
        cd raspberry-pi-media-server
    fi
} >> "$LOG_FILE" 2>&1 || {
    print_message "$RED" "Failed to clone repository. Check $LOG_FILE for details."
    exit 1
}

# Configure .env files for each stack
print_message "$BLUE" "Configuring environment variables..."

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
print_message "$BLUE" "Creating media directories..."
{
    sudo mkdir -p "$DATA_PATH/torrents" "$DATA_PATH/movies" "$DATA_PATH/tv" "$DATA_PATH/anime" "$DATA_PATH/downloads"
    sudo chown -R "$USER_NAME":"$USER_NAME" "$DATA_PATH"
} >> "$LOG_FILE" 2>&1 || {
    print_message "$RED" "Failed to create media directories. Check $LOG_FILE for details."
    exit 1
}

# Deploy Docker stacks
print_message "$BLUE" "Deploying Docker stacks..."

# Get Raspberry Pi's IP address
PI_IP=$(hostname -I | awk '{print $1}')

# Function to deploy a stack with progress indicator
deploy_stack() {
    local stack_name=$1
    print_message "$YELLOW" "Deploying $stack_name stack..."
    
    cd "$stack_name"
    if docker-compose up -d >> "$LOG_FILE" 2>&1; then
        print_message "$GREEN" "✅ $stack_name stack deployed successfully!"
    else
        print_message "$RED" "❌ Failed to deploy $stack_name stack. Check $LOG_FILE for details."
    fi
    cd ..
}

# Deploy all stacks
deploy_stack "tools"
deploy_stack "monitoring"
deploy_stack "seedbox"
deploy_stack "web"

# Final message
print_message "$GREEN" "==================================================="
print_message "$GREEN" "🎉 Media server setup complete! 🎉"
print_message "$GREEN" "==================================================="
echo ""
print_message "$BLUE" "Access your services at the following URLs:"
echo ""
echo "🔧 MANAGEMENT"
echo "• Portainer (Docker management): http://$PI_IP:9000"
echo "• Nginx Proxy Manager: http://$PI_IP:81"
echo ""
echo "📊 MONITORING"
echo "• Grafana (Dashboards): http://$PI_IP:3030"
echo ""
echo "📥 DOWNLOAD"
echo "• Deluge (Torrent client): http://$PI_IP:8112"
echo "• Jackett (Torrent indexer): http://$PI_IP:9117"
echo ""
echo "🎬 MEDIA AUTOMATION"
echo "• Radarr (Movies): http://$PI_IP:7878"
echo "• Sonarr (TV Shows): http://$PI_IP:8989"
echo ""
echo "🎞️ MEDIA SERVER"
echo "• Jellyfin (Media streaming): http://$PI_IP:8096"
echo ""
print_message "$YELLOW" "Default login credentials for services:"
echo "• Portainer: Create on first login"
echo "• Grafana: admin/admin"
echo "• Deluge: admin/deluge"
echo "• Nginx Proxy Manager: admin@example.com/changeme"
echo ""
print_message "$RED" "IMPORTANT: Please change all default passwords immediately!"
echo ""
print_message "$YELLOW" "Next Steps:"
echo "1. You may need to log out and back in for the docker group changes to take effect."
echo "2. Configure each service according to your needs."
echo "3. Set up Nginx Proxy Manager for secure external access."
echo "4. Validate DuckDNS configuration if you're using it for external access."
echo ""
print_message "$BLUE" "For troubleshooting and details, check the log file: $LOG_FILE"
echo ""

# Warn about Docker group
if ! groups "$USER_NAME" | grep -q '\bdocker\b'; then
    print_message "$YELLOW" "⚠️  You need to log out and back in for docker group changes to take effect."
fi
