#!/bin/bash

# Raspberry Pi Optimization Script
# This script improves system performance while maintaining stability
# Created: May 4, 2025

# Colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print colored status messages
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges"
    exit 1
fi

# Create backup directory
BACKUP_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="/home/pi/system_backup_$BACKUP_DATE"

print_status "Creating backup directory at $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"

# Backup key system files
print_status "Backing up key system configuration files..."
cp /etc/fstab "$BACKUP_DIR/"
cp /etc/rc.local "$BACKUP_DIR/"
cp /boot/config.txt "$BACKUP_DIR/"
cp /boot/cmdline.txt "$BACKUP_DIR/"

# Create a list of currently installed packages
print_status "Creating list of currently installed packages..."
dpkg --get-selections > "$BACKUP_DIR/installed_packages.txt"

# Ask user which optimizations they want to perform
echo
echo "========== RASPBERRY PI OPTIMIZATION OPTIONS =========="
echo

# Function to ask yes/no questions
ask_yes_no() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

# Remove Bluetooth
if ask_yes_no "Remove Bluetooth services and packages?"; then
    print_status "Disabling and removing Bluetooth..."
    systemctl disable bluetooth.service
    systemctl disable hciuart.service
    apt remove --purge -y bluez
    apt autoremove --purge -y
fi

# Remove Avahi daemon
if ask_yes_no "Remove Avahi daemon (mDNS/zero-configuration networking)?"; then
    print_status "Removing Avahi daemon..."
    apt remove --purge -y avahi-daemon
    apt autoremove --purge -y
fi

# Remove ModemManager
if ask_yes_no "Remove ModemManager (cellular modem support)?"; then
    print_status "Removing ModemManager..."
    apt remove --purge -y modemmanager
    apt autoremove --purge -y
fi

# Remove other common bloat packages
if ask_yes_no "Remove other common unused packages (games, office tools, etc.)?"; then
    print_status "Removing additional unused packages..."
    apt remove --purge -y wolfram-engine
    apt remove --purge -y libreoffice*
    apt remove --purge -y minecraft-pi
    apt remove --purge -y sonic-pi
    apt remove --purge -y scratch scratch2
    apt remove --purge -y greenfoot
    apt remove --purge -y bluej
    apt remove --purge -y nodered
    apt remove --purge -y geany
    apt autoremove --purge -y
fi

# Configure auto-updates
if ask_yes_no "Modify automatic update behavior (instead of disabling completely)?"; then
    print_status "Configuring controlled updates..."
    
    # Create a custom apt configuration file
    cat > /etc/apt/apt.conf.d/10periodic << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "0";
EOF

    print_status "Auto-updates configured to check but not install automatically"
else
    print_status "Disabling automatic updates completely..."
    systemctl mask apt-daily-upgrade
    systemctl mask apt-daily
    systemctl disable apt-daily-upgrade.timer
    systemctl disable apt-daily.timer
fi

# System memory management optimizations
if ask_yes_no "Apply memory management optimizations?"; then
    print_status "Applying memory optimizations..."
    
    # Add or update swappiness and cache pressure settings
    if grep -q "vm.swappiness" /etc/sysctl.conf; then
        sed -i 's/^vm.swappiness.*/vm.swappiness=10/' /etc/sysctl.conf
    else
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi
    
    if grep -q "vm.vfs_cache_pressure" /etc/sysctl.conf; then
        sed -i 's/^vm.vfs_cache_pressure.*/vm.vfs_cache_pressure=50/' /etc/sysctl.conf
    else
        echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    fi
    
    # Apply changes
    sysctl -p
fi

# Disable unnecessary services
if ask_yes_no "Disable commonly unused services for better performance?"; then
    print_status "Disabling unused services..."
    
    # List of services to disable
    SERVICES_TO_DISABLE=(
        "triggerhappy.service"       # Keyboard event handler
        "dphys-swapfile.service"     # Swap file service (if using external swap)
        "piwiz.service"              # First-run wizard
        "raspi-config.service"       # Configuration tool service
    )
    
    for service in "${SERVICES_TO_DISABLE[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            systemctl disable "$service"
            print_status "Disabled $service"
        else
            print_warning "$service is already disabled or doesn't exist"
        fi
    done
fi

# Clean up the system
print_status "Performing system cleanup..."
apt-get update
apt-get autoremove -y
apt-get autoclean -y
apt-get clean -y
journalctl --vacuum-time=7d

# Create a maintenance script for regular cleanup
cat > /usr/local/bin/system-cleanup.sh << 'EOF'
#!/bin/bash
apt-get update
apt-get autoremove -y
apt-get autoclean -y
apt-get clean -y
journalctl --vacuum-time=7d
echo "System cleanup completed on $(date)"
EOF

chmod +x /usr/local/bin/system-cleanup.sh

# Create a weekly cron job for cleanup
if ask_yes_no "Set up a weekly automatic cleanup task?"; then
    print_status "Setting up weekly cleanup task..."
    echo "0 2 * * 0 root /usr/local/bin/system-cleanup.sh" > /etc/cron.d/system-cleanup
    chmod 644 /etc/cron.d/system-cleanup
fi

# Optimize filesystem
if ask_yes_no "Optimize filesystems for better performance and longevity?"; then
    print_status "Optimizing filesystem parameters..."
    
    # Add noatime to all ext4 partitions to reduce writes
    sed -i 's/\(ext4.*defaults\)/\1,noatime/' /etc/fstab
    
    # Update tmp to use tmpfs if not already
    if ! grep -q "tmpfs /tmp tmpfs" /etc/fstab; then
        echo "tmpfs /tmp tmpfs defaults,nosuid,size=100M 0 0" >> /etc/fstab
    fi
fi

# Summary of changes
echo
echo "========== OPTIMIZATION COMPLETE =========="
echo
print_status "System optimizations have been applied."
print_status "Backup files are stored in $BACKUP_DIR"
print_status "Manual system cleanup can be run anytime with: sudo /usr/local/bin/system-cleanup.sh"
echo
print_warning "It's recommended to reboot your system now to apply all changes."
echo

# Ask for reboot
if ask_yes_no "Would you like to reboot now?"; then
    print_status "Rebooting system..."
    reboot
else
    print_status "Remember to reboot your system later to apply all changes."
fi
