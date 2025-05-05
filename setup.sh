#!/bin/bash

#=============================================================================
# Raspberry Pi Media Server Setup Script
#
# This script automates the setup of a complete media server solution on
# Raspberry Pi using Docker containers based on the LucasACH/raspberry-pi-media-server
# repository. It includes components like Jellyfin, Deluge, Radarr, Sonarr,
# Jackett, and monitoring tools (Grafana).
#=============================================================================

# --- Configuration ---
# IMPORTANT: Adjust these variables before running the script!
# This script is non-interactive to avoid stdin issues in automated environments.

# System Configuration
TIMEZONE="America/New_York" # Your timezone (e.g., "Europe/London", "Asia/Tokyo") - Use `timedatectl list-timezones` to find yours.
USER_NAME="$USER"           # The username of the non-root user who will run Docker. Defaults to the user running this script.
DATA_PATH="$HOME/media"     # Path where media files and torrents will be stored (e.g., /mnt/usbdrive/media, /home/pi/media)
PUID=$(id -u)               # User ID for Docker containers (defaults to the current user's ID)
PGID=$(id -g)               # Group ID for Docker containers (defaults to the current user's GID)

# Web Stack / Networking Configuration (Used by Nginx Proxy Manager, DuckDNS)
# Only needed if you plan to use the web stack for reverse proxy and dynamic DNS
# If not using the web stack, these can be left as defaults, but the web stack
# deployment will likely be skipped or fail if requirements aren't met.
ENABLE_WEB_STACK=true
DUCKDNS_SUBDOMAIN="your-subdomain" # Your DuckDNS subdomain (e.g., mymediapi) - REQUIRED if using DuckDNS
DUCKDNS_TOKEN="your-duckdns-token" # Your DuckDNS token - REQUIRED if using DuckDNS
MYSQL_USER="npm"                   # MySQL user for Nginx Proxy Manager database
MYSQL_PASSWORD="npm_password"      # MySQL password for Nginx Proxy Manager database - CHANGE THIS!

# --- Terminal colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Variables ---
SCRIPT_START_TIME=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$HOME/media_server_setup_$SCRIPT_START_TIME.log"
REPO_DIR="$HOME/raspberry-pi-media-server"
REPO_URL="https://github.com/LucasACH/raspberry-pi-media-server.git"

# --- Functions ---

# Function to print colored messages to console and log
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}" | tee -a "$LOG_FILE"
}

print_status() {
    print_message "$GREEN" "[INFO] $1"
}

print_warning() {
    print_message "$YELLOW" "[WARNING] $1"
}

print_error() {
    print_message "$RED" "[ERROR] $1"
    exit 1 # Exit on critical error
}

print_section() {
    echo | tee -a "$LOG_FILE"
    print_message "$BLUE" "=== $1 ==="
    echo | tee -a "$LOG_FILE"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to create backup of existing configs
backup_config() {
    if [ -d "$REPO_DIR" ]; then
        print_status "Creating backup of current configuration directory ($REPO_DIR)..."
        BACKUP_DIR="$HOME/raspberry-pi-media-server_backup_$(date +%Y%m%d_%H%M%S)"
        if cp -r "$REPO_DIR" "$BACKUP_DIR"; then
            print_status "Backup created at: $BACKUP_DIR"
            echo "Backup of $REPO_DIR created at $BACKUP_DIR" >> "$LOG_FILE"
        else
            print_warning "Failed to create backup of $REPO_DIR."
            echo "Failed to create backup of $REPO_DIR." >> "$LOG_FILE"
        fi
    fi
}

# --- Error Handling Trap ---
# Exit immediately if a command exits with a non-zero status
set -e
# Call print_error on any command failure
trap 'print_error "An unexpected error occurred. Script aborted. Check $LOG_FILE for details."' ERR

# --- Welcome banner ---
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
print_message "$BLUE" "Script started at $SCRIPT_START_TIME"
echo ""

# --- Setup Logging ---
# Ensure log directory exists if not in home
LOG_DIR=$(dirname "$LOG_FILE")
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR" || print_error "Failed to create log directory $LOG_DIR"
fi
print_status "Logs will be saved to $LOG_FILE"
# Redirect stdout and stderr to tee, which writes to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1
# Enable verbose mode after setting up logging
set -x
print_message "$YELLOW" "Enabled verbose logging mode."
echo "" # Add a newline after the verbose mode message

# --- Initial Checks ---
print_section "INITIAL CHECKS"

# Check if running as root - this script should run as the *target user*
if [ "$(id -u)" -eq 0 ]; then
    print_error "This script should NOT be run directly as root!"
    print_message "$YELLOW" "Please run it with a non-root user (e.g., 'pi') who will manage the Docker containers."
    print_message "$YELLOW" "The script will use 'sudo' automatically when needed."
fi

# Check system - requires Debian-based distribution
if ! command_exists apt-get; then
    print_error "This script requires a Debian-based distribution (like Raspberry Pi OS). 'apt-get' command not found."
fi

# Check for essential commands
print_status "Checking for essential commands..."
ESSENTIAL_COMMANDS=("curl" "git" "wget" "awk" "grep" "sed" "tee")
for cmd in "${ESSENTIAL_COMMANDS[@]}"; do
    if ! command_exists "$cmd"; then
        print_error "Essential command '$cmd' not found. Please install it."
    fi
done
print_status "Essential commands found."

# --- Configuration Review ---
print_section "CONFIGURATION REVIEW"
print_message "$YELLOW" "Reviewing configuration variables (defined at the top of the script):"
echo "Timezone: $TIMEZONE"
echo "Username for Docker: $USER_NAME (UID: $PUID, GID: $PGID)"
echo "Media/Data Path: $DATA_PATH"
echo "Enable Web Stack (Nginx Proxy Manager, DuckDNS etc.): $([ "$ENABLE_WEB_STACK" = true ] && echo "Yes" || echo "No")"
if [ "$ENABLE_WEB_STACK" = true ]; then
    echo "DuckDNS Subdomain: $DUCKDNS_SUBDOMAIN"
    echo "DuckDNS Token: ${DUCKDNS_TOKEN:0:4}..." # Mask token
    echo "MySQL User: $MYSQL_USER"
    echo "MySQL Password: ${MYSQL_PASSWORD:0:1}..." # Mask password
    if [ "$DUCKDNS_SUBDOMAIN" = "your-subdomain" ] || [ "$DUCKDNS_TOKEN" = "your-duckdns-token" ]; then
        print_warning "DuckDNS subdomain or token still set to default. Web stack may fail unless you edit the script variables."
    fi
    if [ "$MYSQL_PASSWORD" = "npm_password" ]; then
         print_warning "MySQL password for Nginx Proxy Manager is still the default 'npm_password'. CHANGE THIS!"
    fi
else
    print_warning "Web stack deployment is disabled. Services relying on it (like Nginx Proxy Manager for reverse proxy) will not be deployed."
fi

print_message "$GREEN" "Starting installation process..."
echo ""

# --- Update and Upgrade the system ---
print_section "SYSTEM UPDATE"
print_status "Updating system package lists..."
if ! sudo apt update; then
    print_error "Failed to update system package lists."
fi
print_status "Upgrading system packages..."
if ! sudo apt upgrade -y; then
    print_warning "System upgrade failed or completed with errors. Continuing with script."
fi
print_status "System update and upgrade complete."

# --- Install required packages ---
print_section "INSTALLING REQUIRED PACKAGES"
print_status "Installing essential packages..."
ESSENTIAL_APT_PACKAGES="apt-transport-https ca-certificates curl gnupg lsb-release unzip jq" # Added jq
for pkg in $ESSENTIAL_APT_PACKAGES; do
    if ! command_exists "$pkg" && [ "$pkg" != "apt-transport-https" ] && [ "$pkg" != "ca-certificates" ] && [ "$pkg" != "lsb-release" ] && [ "$pkg" != "gnupg" ]; then # Check if primary command exists
        print_status "Checking if $pkg is installed..."
        if dpkg -s "$pkg" &>/dev/null; then
             print_status "$pkg is already installed."
        else
            print_status "Installing $pkg..."
            if ! sudo apt install -y "$pkg"; then
                print_warning "Failed to install package: $pkg. Script may continue but might have issues."
            fi
        fi
    else
        # Handle packages that don't have a primary command or check anyway
        if dpkg -s "$pkg" &>/dev/null; then
             print_status "$pkg is already installed."
        else
            print_status "Installing $pkg..."
            if ! sudo apt install -y "$pkg"; then
                print_warning "Failed to install package: $pkg. Script may continue but might have issues."
            fi
        fi
    fi
done
print_status "Essential packages installation attempt complete."

# --- Install Docker ---
print_section "INSTALLING DOCKER"
if command_exists docker; then
    print_status "Docker is already installed!"
else
    print_status "Installing Docker using official repository method..."
    # Add Docker's official GPG key
    if ! sudo mkdir -p /etc/apt/keyrings; then print_error "Failed to create /etc/apt/keyrings directory."; fi
    if ! curl -fsSL https://download.docker.com/linux/raspbian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        print_error "Failed to download or save Docker GPG key."
    fi
    if ! sudo chmod a+r /etc/apt/keyrings/docker.gpg; then print_warning "Failed to set permissions for Docker GPG key."; fi

    # Add Docker repository
    ARCH=$(dpkg --print-architecture) # Get architecture (e.g., armhf, arm64)
    if ! echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/raspbian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null; then
        print_error "Failed to add Docker repository."
    fi

    # Update apt cache and install Docker packages
    print_status "Updating apt cache with new Docker repository..."
    if ! sudo apt update; then
        print_error "Failed to update apt cache after adding Docker repository."
    fi

    print_status "Installing docker-ce, docker-ce-cli, containerd.io..."
    if ! sudo apt install -y docker-ce docker-ce-cli containerd.io; then
         print_error "Failed to install Docker packages."
    fi
    print_status "Docker installation complete."
fi

# --- Install Docker Compose ---
print_section "INSTALLING DOCKER COMPOSE"
# Check for both docker-compose (v1) and docker compose (v2)
if command_exists docker-compose; then
    print_status "Docker Compose (v1) is already installed!"
elif command_exists docker && docker compose version &>/dev/null; then
    print_status "Docker Compose (v2) is already installed (as 'docker compose')!"
else
    print_status "Installing Docker Compose (v1) via apt..."
    # Install v1 via apt, which is common on RPi OS
    if ! sudo apt install -y docker-compose; then
        print_warning "Failed to install docker-compose via apt. Attempting manual install (might fail on some architectures)."
        # Fallback: Manual install of latest v1 compose (might need architecture checks)
        COMPOSE_VERSION=$(git ls-remote https://github.com/docker/compose --tags | grep -oP 'v\K\d+\.\d+\.\d+' | head -1)
        print_status "Attempting to download Docker Compose v$COMPOSE_VERSION..."
        if ! sudo curl -L "https://github.com/docker/compose/releases/download/v$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose; then
             print_error "Failed to download Docker Compose binary."
        fi
        if ! sudo chmod +x /usr/local/bin/docker-compose; then
             print_error "Failed to make Docker Compose binary executable."
        fi
        print_status "Manual Docker Compose v1 installation complete."
    fi
fi
print_status "Docker Compose installation attempt complete."


# Add current user to the docker group
print_section "DOCKER GROUP MEMBERSHIP"
print_status "Adding user '$USER_NAME' to the 'docker' group..."
if sudo usermod -aG docker "$USER_NAME"; then
    print_status "User '$USER_NAME' added to the 'docker' group."
    print_message "$YELLOW" "NOTE: You may need to log out and log back in for group changes to take effect before running docker commands without sudo."
else
    print_warning "Failed to add user '$USER_NAME' to the 'docker' group. You may need to run docker commands with sudo, or check user existence/permissions."
fi

# Verify docker access for the user (will still require log out/in)
print_status "Verifying docker access (requires re-login)..."
if groups "$USER_NAME" | grep -q '\bdocker\b'; then
    print_status "User '$USER_NAME' is in the 'docker' group."
else
    print_warning "User '$USER_NAME' is NOT yet in the 'docker' group (might need re-login)."
fi


# Check Docker status before proceeding
print_section "DOCKER STATUS CHECK"
print_status "Checking if Docker service is running..."
if sudo systemctl is-active --quiet docker; then
    print_status "Docker service is active and running."
else
    print_warning "Docker service is not active. Attempting to start it..."
    if sudo systemctl start docker; then
        print_status "Docker service started successfully."
        # Give it a moment to become fully ready
        sleep 5
        if ! sudo systemctl is-active --quiet docker; then
             print_error "Docker service failed to start or is not stable. Check 'sudo systemctl status docker'."
        fi
    else
        print_error "Failed to start Docker service. Check 'sudo systemctl status docker' and $LOG_FILE for details."
    fi
fi

# Check if the user can run docker commands (might fail if not re-logged in)
print_status "Testing docker command access for user '$USER_NAME' (may require re-login)..."
if docker ps > /dev/null 2>&1; then
     print_status "Docker commands work without sudo for user '$USER_NAME'."
else
     print_warning "Docker commands require 'sudo' for user '$USER_NAME'. Re-login may be required."
     print_status "Proceeding by prepending 'sudo' to docker-compose commands in deployment step."
     DOCKER_COMPOSE_CMD="sudo docker-compose" # Use sudo for compose commands
     DOCKER_CMD="sudo docker" # Use sudo for other docker commands
fi

# If DOCKER_COMPOSE_CMD is not set, use standard command
if [ -z "$DOCKER_COMPOSE_CMD" ]; then
    if command_exists docker-compose; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif command_exists docker && docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose" # Use v2 command if v1 not found
        print_status "Using Docker Compose v2 ('docker compose') command."
    else
        print_error "Neither 'docker-compose' (v1) nor 'docker compose' (v2) command found."
    fi
fi

# If DOCKER_CMD is not set, use standard command
if [ -z "$DOCKER_CMD" ]; then
    DOCKER_CMD="docker"
fi


# --- Backup existing configuration ---
print_section "BACKUP"
backup_config

# --- Clone or update the repository ---
print_section "REPOSITORY SETUP"
print_status "Setting up media server repository ($REPO_URL) in $REPO_DIR..."

if [ -d "$REPO_DIR" ]; then
    print_status "Existing repository found at $REPO_DIR. Attempting to update..."
    cd "$REPO_DIR" || print_error "Failed to change directory to $REPO_DIR."
    # Check for local changes first
    if [ -n "$(${DOCKER_CMD} --git-dir=.git --work-tree=. status --porcelain)" ]; then
        print_warning "Local changes detected in $REPO_DIR. Stash or commit them before pulling."
        print_warning "Skipping git pull to avoid conflicts."
    else
        if ${DOCKER_CMD} --git-dir=.git --work-tree=. pull; then
            print_status "Repository updated successfully."
        else
            print_warning "Failed to pull latest changes for $REPO_DIR. Continuing with existing code."
        fi
    fi
else
    print_status "Cloning repository $REPO_URL to $REPO_DIR..."
    cd "$HOME" || print_error "Failed to change directory to $HOME."
    if git clone "$REPO_URL" "$REPO_DIR"; then
        print_status "Repository cloned successfully."
        cd "$REPO_DIR" || print_error "Failed to change directory to $REPO_DIR."
    else
        print_error "Failed to clone repository $REPO_URL."
    fi
fi

# Verify repository contents structure
print_status "Verifying repository structure in $REPO_DIR..."
REQUIRED_STACK_DIRS=("tools" "monitoring" "seedbox")
if [ "$ENABLE_WEB_STACK" = true ]; then
    REQUIRED_STACK_DIRS+=("web")
fi

for dir in "${REQUIRED_STACK_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        print_error "Error: Required directory '$dir' not found in repository ($REPO_DIR). Repository structure is not as expected. Aborting."
    fi
    if [ ! -f "$dir/docker-compose.yml" ]; then
        print_error "Error: docker-compose.yml not found in '$dir' directory ($REPO_DIR/$dir). Repository structure is not as expected. Aborting."
    fi
done
print_status "Repository structure verified."

# --- Configure .env files for each stack ---
print_section "CONFIGURING ENVIRONMENT VARIABLES"
print_status "Creating/Updating .env files in $REPO_DIR/..."

# Tools stack
print_status "Configuring tools/.env..."
cat <<EOF > tools/.env
USER=$USER_NAME
TZ=$TIMEZONE
EOF
print_status "Created tools/.env"

# Monitoring stack
print_status "Configuring monitoring/.env..."
cat <<EOF > monitoring/.env
USER=$USER_NAME
EOF
print_status "Created monitoring/.env"

# Seedbox stack
print_status "Configuring seedbox/.env..."
cat <<EOF > seedbox/.env
USER=$USER_NAME
PUID=$PUID
PGID=$PGID
TZ=$TIMEZONE
# Optional: Add specific environment variables for seedbox containers if needed by the repo
EOF
print_status "Created seedbox/.env"

# Web stack (only if enabled)
if [ "$ENABLE_WEB_STACK" = true ]; then
    print_status "Configuring web/.env..."
    cat <<EOF > web/.env
USER=$USER_NAME
PUID=$PUID
PGID=$PGID
TZ=$TIMEZONE
SUBDOMAINS=$DUCKDNS_SUBDOMAIN
DUCKDNS_TOKEN=$DUCKDNS_TOKEN
DB_MYSQL_USER=$MYSQL_USER
DB_MYSQL_PASSWORD=$MYSQL_PASSWORD
# Optional: Add specific environment variables for web containers if needed by the repo
EOF
    print_status "Created web/.env"
else
    print_status "Web stack is disabled, skipping web/.env configuration."
fi
print_status "Environment variable configuration complete."

# --- Create necessary directories for media storage ---
print_section "CREATING MEDIA DIRECTORIES"
print_status "Ensuring media/data directories exist at $DATA_PATH..."
# Use sudo as DATA_PATH might be outside the user's home, like /mnt
if sudo mkdir -p "$DATA_PATH/torrents" "$DATA_PATH/movies" "$DATA_PATH/tv" "$DATA_PATH/anime" "$DATA_PATH/downloads"; then
    print_status "Media directories created/exist."
else
    print_error "Failed to create media directories at $DATA_PATH."
fi

print_status "Setting ownership for $DATA_PATH to $PUID:$PGID ($USER_NAME:$USER_NAME)..."
# Use sudo for chown as DATA_PATH might be root-owned initially
if sudo chown -R "$PUID":"$PGID" "$DATA_PATH"; then
    print_status "Ownership set successfully."
else
    print_warning "Failed to set ownership for $DATA_PATH. Permissions might be incorrect for Docker containers."
fi

print_status "Checking final directory permissions for $DATA_PATH:"
sudo ls -la "$DATA_PATH" # Use sudo to ensure permissions are visible

# --- Deploy Docker stacks ---
print_section "DEPLOYING DOCKER STACKS"

# Function to deploy a stack
deploy_stack() {
    local stack_name="$1"
    local compose_dir="$REPO_DIR/$stack_name"
    print_status "Deploying $stack_name stack from $compose_dir..."

    if [ "$stack_name" = "web" ] && [ "$ENABLE_WEB_STACK" = false ]; then
        print_status "Web stack deployment is disabled by configuration. Skipping."
        return 0 # Return success even if skipped
    fi

    if [ ! -d "$compose_dir" ]; then
        print_warning "Directory $compose_dir not found. Skipping $stack_name stack."
        return 1 # Indicate failure (directory not found)
    fi

    cd "$compose_dir" || print_error "Failed to change directory to $compose_dir."

    # Validate docker-compose file syntax
    print_status "Validating docker-compose configuration for $stack_name..."
    if ! ${DOCKER_COMPOSE_CMD} config >/dev/null 2>&1; then
        print_error "Docker-compose configuration for $stack_name is invalid. Check syntax in $compose_dir/docker-compose.yml"
    fi
    print_status "Docker-compose configuration for $stack_name is valid."

    # Deploy containers
    print_status "Running '${DOCKER_COMPOSE_CMD} up -d' for $stack_name stack..."
    if ${DOCKER_COMPOSE_CMD} up -d --remove-orphans; then # Add --remove-orphans to clean up old containers
        print_message "$GREEN" "✅ $stack_name stack deployed successfully!"
        # Optional: Wait a moment for containers to start (adjust as needed)
        # sleep 10
    else
        print_message "$RED" "❌ Failed to deploy $stack_name stack."
        print_warning "Checking logs for $stack_name stack containers..."
        # Show logs for services in this compose file
        if ${DOCKER_COMPOSE_CMD} logs; then
             echo "See logs above or in $LOG_FILE for details on $stack_name failure."
        else
            echo "Could not retrieve docker-compose logs for $stack_name. Check $LOG_FILE for details."
        fi
        # Exit immediately on stack deployment failure
        exit 1
    fi

    # Go back to repo root or home
    cd "$REPO_DIR" || print_error "Failed to change directory back to $REPO_DIR."
}

# Deploy all stacks
print_status "Starting stack deployments..."
deploy_stack "tools"
deploy_stack "monitoring"
deploy_stack "seedbox"
deploy_stack "web" # Only deploys if ENABLE_WEB_STACK is true and directory exists

print_status "All selected stacks deployment attempts completed."

# --- Final Checks and Summary ---
print_section "SETUP COMPLETE"
print_message "$GREEN" "==================================================="
print_message "$GREEN" "🎉 Raspberry Pi Media Server Setup Complete! 🎉"
print_message "$GREEN" "==================================================="
echo ""

# Get Raspberry Pi's IP address (handle multiple IPs)
PI_IPS=$(hostname -I)
# Get primary non-loopback IP if possible
PRIMARY_IP=$(echo "$PI_IPS" | awk '{print $1}')
if [ -z "$PRIMARY_IP" ]; then
    PRIMARY_IP="Unknown (Check 'hostname -I')"
fi


print_message "$BLUE" "Your Raspberry Pi IP Address(es): $PI_IPS"
echo ""
print_message "$BLUE" "Potential Service Access URLs (using primary IP: $PRIMARY_IP):"
echo ""

# List services with typical ports (adjust based on the repo's docker-compose files if necessary)
echo "🔧 MANAGEMENT"
echo "• Portainer (Docker Management): http://$PRIMARY_IP:9000"
if [ "$ENABLE_WEB_STACK" = true ]; then
    echo "• Nginx Proxy Manager (Reverse Proxy): http://$PRIMARY_IP:81"
    echo "  (Initial NPM Login: admin@example.com / changeme - CHANGE THIS!)"
    if [ "$DUCKDNS_SUBDOMAIN" != "your-subdomain" ] && [ "$DUCKDNS_TOKEN" != "your-duckdns-token" ] && command_exists curl; then
        echo ""
        print_message "$BLUE" "Testing DuckDNS update:"
        curl "https://www.duckdns.org/update?domains=$DUCKDNS_SUBDOMAIN&token=$DUCKDNS_TOKEN&ip="
        echo ""
        print_message "$GREEN" "DuckDNS update attempted. Verify it updated correctly via duckdns.org."
    fi
fi
echo ""
echo "📊 MONITORING"
echo "• Grafana (Dashboards): http://$PRIMARY_IP:3030"
echo "  (Initial Grafana Login: admin / admin - CHANGE THIS!)"
echo ""
echo "📥 DOWNLOAD"
echo "• Deluge (Torrent Client): http://$PRIMARY_IP:8112"
echo "  (Initial Deluge Password: deluge - CHANGE THIS!)"
echo "• Jackett (Torrent Indexer): http://$PRIMARY_IP:9117"
echo ""
echo "🎬 MEDIA AUTOMATION"
echo "• Radarr (Movies): http://$PRIMARY_IP:7878"
echo "• Sonarr (TV Shows): http://$PRIMARY_IP:8989"
echo ""
echo "🎞️ MEDIA SERVER"
echo "• Jellyfin (Media Streaming): http://$PRIMARY_IP:8096"
echo ""
print_message "$RED" "==================================================="
print_message "$RED" "⚠️  SECURITY ALERT: Change all default passwords immediately!"
print_message "$RED" "==================================================="
echo ""
print_message "$YELLOW" "Next Steps:"
echo "1. IMPORTANT: If you weren't prompted for sudo password for 'docker ps', you must LOG OUT AND LOG BACK IN for the docker group changes to take effect."
echo "2. Access the services listed above."
echo "3. Configure storage paths within Jellyfin, Radarr, Sonarr, Deluge etc. to point to your $DATA_PATH subdirectories."
echo "4. Configure Jackett indexers."
echo "5. (Optional) Configure Nginx Proxy Manager for secure access (HTTPS) and set up DNS records."
echo "6. Review the configuration variables at the top of the script ($0) and the .env files ($REPO_DIR/*/.env)."
echo ""
print_message "$BLUE" "For troubleshooting and detailed output, check the log file: $LOG_FILE"
print_message "$BLUE" "You can also check container logs using: $DOCKER_CMD logs <container_name>"
echo ""

# Create a simple README file
README_PATH="$HOME/MEDIA_SERVER_SETUP_README.txt"
print_status "Creating summary README file at $README_PATH..."
cat <<EOF > "$README_PATH"
Raspberry Pi Media Server Setup Summary

Setup completed on: $(date)
Log file: $LOG_FILE
Repository directory: $REPO_DIR
Media/Data directory: $DATA_PATH
User for Docker: $USER_NAME (UID: $PUID, GID: $PGID)

Potential Service Access URLs (using primary IP: $PRIMARY_IP):

MANAGEMENT:
- Portainer: http://$PRIMARY_IP:9000
- Nginx Proxy Manager (if enabled): http://$PRIMARY_IP:81

MONITORING:
- Grafana: http://$PRIMARY_IP:3030

DOWNLOAD:
- Deluge: http://$PRIMARY_IP:8112
- Jackett: http://$PRIMARY_IP:9117

MEDIA AUTOMATION:
- Radarr: http://$PRIMARY_IP:7878
- Sonarr: http://$PRIMARY_IP:8989

MEDIA SERVER:
- Jellyfin: http://$PRIMARY_IP:8096

IMPORTANT: Change default passwords for services (Grafana, Deluge, NPM)!

Review the script file ($0) and .env files in $REPO_DIR for full configuration.
Check container status: $DOCKER_CMD ps
Check container logs: $DOCKER_CMD logs <container_name>
EOF
if ! chmod 644 "$README_PATH"; then
    print_warning "Failed to set permissions for $README_PATH."
fi
print_status "README file created."

print_message "$GREEN" "Script finished."

exit 0
