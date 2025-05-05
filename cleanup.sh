#!/bin/bash

# Raspberry Pi Media Server Optimization Script
# This script optimizes Raspberry Pi specifically for media server usage
# and script execution environment.
# It performs cleanup, disables unnecessary services, optimizes kernel and
# filesystem settings, installs monitoring tools, sets up maintenance tasks,
# and applies basic security enhancements.
# Created: 2024-07-29 (Updated)
# Version: 2.1

# --- Configuration ---
# Set to true to automatically install recommended media server packages
INSTALL_MEDIA_SERVER_SOFTWARE=false # Set to true and edit the list below to auto-install

# List of media server packages to install if INSTALL_MEDIA_SERVER_SOFTWARE is true
# Uncomment or add packages relevant to you (e.g., minidlna, plexmediaserver, jellyfin, transmission-daemon)
# Note: Plex and Jellyfin may have specific installation instructions not fully covered by apt
MEDIA_SERVER_PACKAGES=(
    #"minidlna"
    #"transmission-daemon"
    #"samba" # If you need network shares (SMB/CIFS)
    #"nfs-kernel-server" # If you need network shares (NFS)
    # "plexmediaserver" # Often requires manual download/install
    # "jellyfin" # Often requires manual setup of repositories
)

# --- Colors for better readability ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Variables ---
SCRIPT_START_TIME=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="/root/system_backup_$SCRIPT_START_TIME" # Backup to /root as script runs as root
LOG_FILE="/var/log/rpi-media-server-optimization_$SCRIPT_START_TIME.log"

# --- Functions ---

# Function to print colored status messages
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1 # Exit on critical error
}

print_section() {
    echo
    echo -e "${BLUE}=== $1 ===${NC}"
    echo | tee -a "$LOG_FILE"
    echo "=== $1 ===" | tee -a "$LOG_FILE"
    echo
}

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

# Function to safely edit a file using a temporary file
# $1: File to edit
# $2: sed command(s)
safe_edit_file() {
    local file="$1"
    local sed_cmd="$2"
    local tmp_file="${file}.tmp.$$"

    if [ ! -f "$file" ]; then
        print_warning "File not found, cannot edit: $file"
        return 1
    fi

    # Use awk to preserve permissions and ownership better than cp -p
    awk '1' "$file" > "$tmp_file"
    if ! sed -i "$sed_cmd" "$tmp_file"; then
        print_error "Failed to apply sed command to $file. Original file untouched. Command: $sed_cmd"
        rm -f "$tmp_file"
        return 1
    fi

    # Atomically replace the original file
    if ! mv -f "$tmp_file" "$file"; then
        print_error "Failed to replace original file $file. Temporary file remains at $tmp_file"
        return 1
    fi

    print_status "Successfully modified $file"
    return 0
}

# --- Error Handling Trap ---
trap 'print_error "An unexpected error occurred. Script aborted."' ERR

# --- Initial Checks ---

print_section "INITIAL CHECKS"

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges."
fi

# Ensure apt is not locked
print_status "Checking for existing apt locks..."
if fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
    print_error "Another process is using apt. Please close other package managers (apt, apt-get, aptitude, synaptic) and try again."
fi

# --- System Information ---
print_section "SYSTEM INFORMATION"

# Get Raspberry Pi model information more robustly
PI_MODEL=$(grep -oP 'Model\s*:\s*\K(.*)' /proc/cpuinfo | head -1 || echo "Unknown")
PI_REVISION=$(grep -oP 'Revision\s*:\s*\K(.*)' /proc/cpuinfo | head -1 || echo "Unknown")
PI_MEMORY=$(free -h | awk '/^Mem:/ {print $2}' || echo "Unknown") # Use awk for clarity
OS_PRETTY_NAME=$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release || echo "Unknown")
KERNEL_VERSION=$(uname -r)
ARCH=$(uname -m)

echo "Raspberry Pi Model: $PI_MODEL"
echo "Hardware Revision: $PI_REVISION"
echo "Architecture: $ARCH"
echo "Total Memory: $PI_MEMORY"
echo "Operating System: $OS_PRETTY_NAME"
echo "Kernel Version: $KERNEL_VERSION"

# Check if this is likely a Raspberry Pi OS installation
if [[ "$OS_PRETTY_NAME" != *"Raspberry Pi OS"* && "$OS_PRETTY_NAME" != *"Raspbian"* ]]; then
    print_warning "This script is designed for Raspberry Pi OS/Raspbian. It might work on other Debian-based systems, but proceed with caution."
    if ! ask_yes_no "Continue anyway?"; then
        print_status "Script aborted by user."
        exit 0
    fi
fi


# --- Backup ---
print_section "BACKUP"
print_status "Creating backup directory at $BACKUP_DIR..."
if ! mkdir -p "$BACKUP_DIR"; then
    print_error "Failed to create backup directory: $BACKUP_DIR"
fi

# Backup key system files
print_status "Backing up key system configuration files..."
# Using `cp -p` to preserve permissions and ownership where possible
if ! cp -p /etc/fstab "$BACKUP_DIR/" || \
   ! cp -p /etc/rc.local "$BACKUP_DIR/" || \
   ! cp -p /boot/config.txt "$BACKUP_DIR/" || \
   ! cp -p /boot/cmdline.txt "$BACKUP_DIR/" || \
   ! cp -p /etc/sysctl.conf "$BACKUP_DIR/" || \
   ! cp -p /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config"; then
   # Note: /etc/rc.local is deprecated, but good to back up if it exists
   print_warning "Some key configuration files could not be backed up."
fi


# Create a list of currently installed packages
print_status "Creating list of currently installed packages..."
if ! dpkg --get-selections > "$BACKUP_DIR/installed_packages.txt"; then
    print_warning "Failed to create installed packages list."
fi

# --- Configuration Options ---
print_section "CONFIGURATION OPTIONS"
print_status "Please answer the following questions to configure the optimization:"

if ask_yes_no "Do you want to remove GUI and desktop packages (recommended for headless media server)?"; then
    REMOVE_GUI=true
else
    REMOVE_GUI=false
fi

if ask_yes_no "Do you want to disable wireless services (WiFi/Bluetooth) - select NO if you need WiFi?"; then
    DISABLE_WIRELESS=true
else
    DISABLE_WIRELESS=false
fi

if ask_yes_no "Do you want to optimize for maximum performance (may use more power, potentially hotter)?"; then
    MAX_PERFORMANCE=true
else
    MAX_PERFORMANCE=false
fi

if ask_yes_no "Do you want to set up automatic security updates?"; then
    SECURITY_UPDATES=true
else
    SECURITY_UPDATES=false
fi

# --- Confirmation Step ---
print_section "REVIEW AND CONFIRM"
echo -e "${BLUE}Please review your selected options:${NC}"
echo "- Remove GUI: $([ "$REMOVE_GUI" = true ] && echo "${GREEN}Yes${NC}" || echo "${RED}No${NC}")"
echo "- Disable Wireless: $([ "$DISABLE_WIRELESS" = true ] && echo "${GREEN}Yes${NC}" || echo "${RED}No${NC}")"
echo "- Optimize for Performance: $([ "$MAX_PERFORMANCE" = true ] && echo "${GREEN}Max Performance${NC}" || echo "${YELLOW}Balanced${NC}")"
echo "- Automatic Security Updates: $([ "$SECURITY_UPDATES" = true ] && echo "${GREEN}Enabled${NC}" || echo "${YELLOW}Disabled (Manual updates required)${NC}")"

if [ "$REMOVE_GUI" = true ]; then
    print_warning "Removing GUI packages is a significant change and requires command-line proficiency. You will need to interact via SSH or serial after reboot."
fi

if ask_yes_no "${YELLOW}Do you want to proceed with these changes? This is your last chance to cancel.${NC}"; then
    print_status "Proceeding with optimization..."
else
    print_status "Optimization aborted by user."
    exit 0
fi

# --- Disable Unnecessary Services ---
print_section "DISABLING UNNECESSARY SERVICES"
print_status "Disabling non-essential services for a media server..."

# Core list of services to disable (regardless of user choices)
# Check if service exists before attempting to disable/stop
SERVICES_TO_DISABLE=(
    "triggerhappy.service"       # Keyboard event handler
    "piwiz.service"              # First-run wizard (often runs only once, but good to disable)
    "raspi-config.service"       # Configuration tool service (not needed at boot)
    "plymouth.service"           # Boot splash screen (optional)
    "cups.service"               # Printing system
    "cups-browsed.service"       # Printer discovery
    "keyboard-setup.service"     # Keyboard setup (not needed on headless)
    "rsync.service"              # Remote sync (if not explicitly needed)
    "saned.service"              # Scanner service
    "ModemManager.service"       # Modem management (unlikely on Pi)
    "dphys-swapfile.service"     # Swap file management (we'll configure swappiness manually)
)

# Add GUI related services if removing GUI
if [ "$REMOVE_GUI" = true ]; then
    SERVICES_TO_DISABLE+=(
        "lightdm.service"            # Display manager
        # Services often pulled in by GUI, might need explicit removal
        # "x11-common.service"       # This is often a core dependency, removing might break things
        # "xserver-xorg.service"     # Same as above
    )
fi

# Add wireless services if disabling wireless
if [ "$DISABLE_WIRELESS" = true ]; then
    SERVICES_TO_DISABLE+=(
        "bluetooth.service"          # Bluetooth
        "bluealsa.service"           # Bluetooth audio
        "hciuart.service"            # Bluetooth UART
        "wpa_supplicant.service"     # Wireless
        "avahi-daemon.service"       # Zeroconf/Bonjour (often related to network discovery like AirPrint, useful for some media servers)
    )
fi

for service in "${SERVICES_TO_DISABLE[@]}"; do
    print_status "Checking $service..."
    if systemctl list-unit-files --type=service | grep -q "^$service"; then # Check if service file exists
        if systemctl is-active --quiet "$service"; then
             print_status "Stopping $service..."
             if ! systemctl stop "$service"; then
                 print_warning "Failed to stop $service. Continuing."
             fi
        fi
        if systemctl is-enabled --quiet "$service"; then
            print_status "Disabling $service..."
            if ! systemctl disable "$service"; then
                 print_warning "Failed to disable $service. Continuing."
             else
                 print_status "$service disabled."
            fi
        else
            print_status "$service is already disabled."
        fi
    else
        print_status "$service does not exist or is not a service unit file."
    fi
done

# --- Package Removal ---
print_section "REMOVING UNNECESSARY PACKAGES"
print_status "Removing packages not typically needed for a media server..."

# Base packages to remove (regardless of options)
PACKAGES_TO_REMOVE=(
    "wolfram-engine"
    "minecraft-pi"
    "sonic-pi"
    "scratch scratch2"
    "greenfoot"
    "bluej"
    "nodered"
    "geany"
    "python-games"
    "plymouth"
    "libreoffice*" # Often included by default, remove if not needed
    "vlc*"         # If you don't need local media playback
    "chromium-browser" # If you don't need a browser
)

# Add GUI packages if removing GUI
if [ "$REMOVE_GUI" = true ]; then
    PACKAGES_TO_REMOVE+=(
        "thonny"
        "pulseaudio" # Often related to desktop audio
        # Be cautious with desktop environment meta-packages.
        # Removing them *can* break core libraries if dependencies are complex.
        # Explicitly listing known desktop components is often safer.
        "gnome-*" # If any gnome components are present
        "lxde-* lxappearance lxinput lxtask" # LXDE components
        "realvnc-vnc-server" # VNC server
        "rpi-recommended" # Meta-package, can remove many things
        "xserver-xorg*" # X server components
        "x11-*" # X11 components (caution!)
        "pi-greeter" # LightDM greeter
        "raspberrypi-ui-mods" # Custom RPi UI
        "desktop-base" # Base files for the desktop
        # You might need to add others depending on your specific RPi OS image
    )
fi

# Add wireless packages if disabling wireless
if [ "$DISABLE_WIRELESS" = true ]; then
    PACKAGES_TO_REMOVE+=(
        "bluez" # Core bluetooth library
        "bluez-firmware"
        "bluetooth"
        "pi-bluetooth"
        # avahi-daemon handled via service disable, removing package might be too aggressive
    )
fi

# Remove packages
# Use apt with -y and check command success
print_status "Running apt update before package removal..."
if ! apt update; then
    print_warning "Failed to update package lists. Package removal might not be optimal."
fi

for package in "${PACKAGES_TO_REMOVE[@]}"; do
    print_status "Attempting to remove $package..."
    if apt remove --purge -y "$package"; then
        print_status "Successfully removed $package"
    else
        print_warning "Failed to remove $package. It might not be installed or an error occurred."
    fi
done

print_status "Cleaning up dependencies..."
if ! apt autoremove --purge -y; then
    print_warning "Failed to run apt autoremove."
fi

# Final package list check (optional, can be noisy)
# print_status "Checking for remaining potentially unnecessary packages..."
# apt list --installed | grep -E '^(task-|xserver-|lxde-|gnome-|vnc-|realvnc-|libreoffice-|chromium-|scratch|wolfram|minecraft|sonic|greenfoot|bluej|nodered)' # Example patterns

# --- Update Management ---
print_section "UPDATE MANAGEMENT"

if [ "$SECURITY_UPDATES" = true ]; then
    print_status "Setting up automatic security updates only using unattended-upgrades..."

    # Install unattended-upgrades and apt-listchanges if not already installed
    if ! apt install -y unattended-upgrades apt-listchanges; then
         print_warning "Failed to install unattended-upgrades. Automatic updates not configured."
    else
        # Configure for security updates only
        UNATTENDED_CONFIG="/etc/apt/apt.conf.d/50unattended-upgrades"
        AUTO_UPGRADES_CONFIG="/etc/apt/apt.conf.d/20auto-upgrades"

        print_status "Configuring $UNATTENDED_CONFIG..."
        cat > "$UNATTENDED_CONFIG" << 'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Raspbian,codename=${distro_codename},label=Raspbian-Security";
    // Add other security origins here if needed, e.g. Ubuntu security
};

// Automatically upgrade packages from these origins
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
    // "${distro_id}:${distro_codename}-proposed-updates";
    // "${distro_id}:${distro_codename}-backports";
};

// Do not automatically upgrade packages from these origins
Unattended-Upgrade::Package-Blacklist {};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Automatic-Reboot "false"; // Don't reboot automatically
Unattended-Upgrade::Remove-Unused-Dependencies "true"; // Remove old dependencies
Unattended-Upgrade::SyslogEnable "true";
// Send email notifications if apt-listchanges is installed and configured
// Unattended-Upgrade::Mail "root";
// Unattended-Upgrade::MailOnlyOnError "true";
EOF
        print_status "Configuring $AUTO_UPGRADES_CONFIG for daily checks..."
        cat > "$AUTO_UPGRADES_CONFIG" << 'EOF'
APT::Periodic::Update-Package-Lists "1"; // Update lists daily
APT::Periodic::Unattended-Upgrade "1"; // Run unattended-upgrade daily
APT::Periodic::AutocleanInterval "7"; // Clean cache weekly
EOF
        print_status "Automatic security updates have been configured."
    fi
else
    print_status "Disabling automatic updates for maximum stability..."
    # Mask and disable timers to prevent automatic runs
    if systemctl status apt-daily.timer &>/dev/null; then
        systemctl mask apt-daily-upgrade.timer
        systemctl disable apt-daily-upgrade.timer
        systemctl mask apt-daily.timer
        systemctl disable apt-daily.timer
        print_status "apt-daily timers masked and disabled."
    else
         print_warning "apt-daily timers not found. Automatic updates might not be active anyway."
    fi

    # Remove existing auto-upgrade config files if they exist
    print_status "Removing unattended-upgrades configuration files..."
    rm -f /etc/apt/apt.conf.d/20auto-upgrades
    rm -f /etc/apt/apt.conf.d/50unattended-upgrades

    # Create a manual update script that you can run when needed
    MANUAL_UPDATE_SCRIPT="/usr/local/bin/manual-update.sh"
    print_status "Creating manual update script at $MANUAL_UPDATE_SCRIPT..."
    cat > "$MANUAL_UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
# Manual update script - run this when you specifically want to update
echo "Starting manual system update..."
# Use tee to log output while also printing to console
apt update | tee /var/log/manual-update.log
apt upgrade -y | tee -a /var/log/manual-update.log
apt autoremove -y | tee -a /var/log/manual-update.log
apt autoclean -y | tee -a /var/log/manual-update.log
echo "System update completed on $(date)" | tee -a /var/log/manual-update.log
EOF
    if ! chmod +x "$MANUAL_UPDATE_SCRIPT"; then
        print_warning "Failed to make $MANUAL_UPDATE_SCRIPT executable."
    fi
    print_status "Created manual update script: $MANUAL_UPDATE_SCRIPT"
fi

# --- Memory Optimization ---
print_section "MEMORY OPTIMIZATION"
print_status "Applying media server optimized memory settings..."

# Create or update sysctl configuration file for media server
SYSCTL_CONFIG="/etc/sysctl.d/99-media-server.conf"
print_status "Configuring sysctl settings in $SYSCTL_CONFIG..."

cat > "$SYSCTL_CONFIG" << EOF
# Recommended sysctl settings for servers and performance:

# Memory management optimizations
# swappiness=1: Kernel will try to avoid swapping as much as possible (higher value = more swapping)
vm.swappiness=1
# vfs_cache_pressure=50: Controls tendency of kernel to reclaim memory used for caching of directory and inode objects. Lower values prefer to retain cache. 50 is a good balance.
vm.vfs_cache_pressure=50
# dirty_ratio=80: Percentage of system memory that can be filled with 'dirty' pages (data written but not yet on disk) before processes are forced to write them out. High value (80) allows more writes to buffer.
vm.dirty_ratio=80
# dirty_background_ratio=20: Percentage of system memory filled with dirty pages before background writeback kicks in. High value (20) allows more buffering before background writes start.
vm.dirty_background_ratio=20
# min_free_kbytes=65536: Minimum amount of free memory (in KB) the system tries to keep available. Helps avoid OOM situations under heavy load. 64MB is a common value for 1GB+ systems.
vm.min_free_kbytes=65536

# Disable IPv6 if not needed (can slightly reduce network overhead and attack surface)
# Set to 0 if you need IPv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1

# Network optimizations for media streaming/serving (larger buffers)
# rmem_max, rmem_default: Max/Default TCP receive buffer size
net.core.rmem_max=16777216
net.core.rmem_default=1048576
# wmem_max, wmem_default: Max/Default TCP send buffer size
net.core.wmem_max=16777216
net.core.wmem_default=1048576
# tcp_rmem: Min, Default, Max TCP receive buffer auto-tuning values
net.ipv4.tcp_rmem=4096 1048576 16777216
# tcp_wmem: Min, Default, Max TCP send buffer auto-tuning values
net.ipv4.tcp_wmem=4096 1048576 16777216
# tcp_slow_start_after_idle=0: Disable TCP slow start after an idle period. Useful for long-lived connections like streaming.
net.ipv4.tcp_slow_start_after_idle=0
# somaxconn=4096: Max number of pending connections for a listener socket. Increase for servers handling many connections.
net.core.somaxconn=4096
# tcp_tw_reuse=1: Allow reusing sockets in TIME_WAIT state. Can help under high connection churn (less common for media server).
net.ipv4.tcp_tw_reuse=1
EOF

# Apply sysctl settings
print_status "Applying new sysctl settings..."
if ! sysctl -p "$SYSCTL_CONFIG"; then
    print_warning "Failed to apply sysctl settings. Check $SYSCTL_CONFIG for errors."
fi

# --- Filesystem Optimization ---
print_section "FILESYSTEM OPTIMIZATION"
print_status "Optimizing filesystem for media server performance..."

# Add noatime to all ext4 partitions to reduce writes
# Use safe_edit_file for fstab modification
print_status "Modifying /etc/fstab to add noatime,nodiratime..."
# Check if options already exist to avoid duplication
if ! grep -q " noatime," /etc/fstab; then
    safe_edit_file "/etc/fstab" 's/\(ext4.*defaults\)/\1,noatime,nodiratime/'
else
    print_status "/etc/fstab already contains noatime/nodiratime options for ext4 partitions."
fi


# Update tmp to use tmpfs if not already mounted as tmpfs
# Check actual mount first, then fstab
if mountpoint -q /tmp && grep -q "tmpfs /tmp" /proc/mounts; then
    print_status "/tmp is already mounted as tmpfs."
else
    if grep -q "tmpfs /tmp tmpfs" /etc/fstab; then
         print_status "/tmp is configured as tmpfs in fstab, will be active after reboot."
    else
        print_status "Adding tmpfs /tmp to /etc/fstab..."
        # Append only if not already present
        if ! grep -q "^tmpfs /tmp tmpfs" /etc/fstab; then
            echo "tmpfs /tmp tmpfs defaults,nosuid,size=200M 0 0" | tee -a /etc/fstab
            print_status "Added tmpfs /tmp to /etc/fstab. Will be active after reboot."
        else
             print_status "tmpfs /tmp entry already exists in /etc/fstab."
        fi
    fi
fi


# Configure tmpfs for log directory only if user chose max performance
if [ "$MAX_PERFORMANCE" = true ]; then
    if mountpoint -q /var/log && grep -q "tmpfs /var/log" /proc/mounts; then
        print_status "/var/log is already mounted as tmpfs."
    else
        if grep -q "tmpfs /var/log tmpfs" /etc/fstab; then
             print_status "/var/log is configured as tmpfs in fstab, will be active after reboot."
        else
            print_warning "Configuring /var/log on tmpfs will make logs non-persistent across reboots. Only enable if you understand the implications."
            if ask_yes_no "Do you want to place /var/log on tmpfs (logs lost on reboot)?"; then
                 print_status "Adding tmpfs /var/log to /etc/fstab..."
                # Backup current logs before configuring tmpfs for /var/log
                mkdir -p "$BACKUP_DIR/logs"
                print_status "Backing up current logs to $BACKUP_DIR/logs/..."
                if ! cp -r /var/log/* "$BACKUP_DIR/logs/"; then
                    print_warning "Failed to backup current logs."
                fi

                # Append only if not already present
                if ! grep -q "^tmpfs /var/log tmpfs" /etc/fstab; then
                    echo "tmpfs /var/log tmpfs defaults,nosuid,size=50M 0 0" | tee -a /etc/fstab
                    print_status "Added tmpfs /var/log to /etc/fstab. Will be active after reboot."
                else
                     print_status "tmpfs /var/log entry already exists in /etc/fstab."
                fi
            else
                print_status "/var/log will not be placed on tmpfs."
            fi
        fi
    fi
else
    print_status "/var/log will remain on persistent storage (tmpfs for /var/log skipped based on performance option)."
fi


# Set up periodic TRIM for SSD if present
if [ -x "$(command -v fstrim)" ]; then
    print_status "Setting up weekly TRIM for SSD health if an SSD is used..."
    TRIM_CRON="/etc/cron.weekly/fstrim"
    if [ ! -f "$TRIM_CRON" ]; then
        cat > "$TRIM_CRON" << 'EOF'
#!/bin/sh
# Trim all mounted filesystems that support it.
# Add --verbose (-v) for detailed output in cron logs.
fstrim -av
EOF
        if ! chmod +x "$TRIM_CRON"; then
            print_warning "Failed to make $TRIM_CRON executable."
        fi
         print_status "Created weekly fstrim cron job."
    else
        print_status "Weekly fstrim cron job already exists."
    fi
else
    print_warning "fstrim command not found. Skipping TRIM setup. Install 'util-linux' package if needed."
fi

# Update I/O scheduler for better performance with large files
print_status "Setting I/O scheduler to mq-deadline and optimizing queue depth/readahead..."
# Iterate over block devices that are not loop or ram disks, and have a scheduler tunable
for disk in $(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" {print $1}'); do
    SCHEDULER_PATH="/sys/block/$disk/queue/scheduler"
    NR_REQUESTS_PATH="/sys/block/$disk/queue/nr_requests"
    READ_AHEAD_PATH="/sys/block/$disk/queue/read_ahead_kb"

    if [ -f "$SCHEDULER_PATH" ]; then
        print_status "Configuring I/O scheduler for /dev/$disk..."
        # Try to set mq-deadline if available
        if grep -q "mq-deadline" "$SCHEDULER_PATH"; then
            echo mq-deadline > "$SCHEDULER_PATH" 2>/dev/null || print_warning "Failed to set mq-deadline for /dev/$disk"
        elif grep -q "deadline" "$SCHEDULER_PATH"; then
             echo deadline > "$SCHEDULER_PATH" 2>/dev/null || print_warning "Failed to set deadline for /dev/$disk"
        else
            print_warning "Neither mq-deadline nor deadline scheduler available for /dev/$disk"
        fi

        # Increase queue depth and readahead
        if [ -f "$NR_REQUESTS_PATH" ]; then
            echo 1024 > "$NR_REQUESTS_PATH" 2>/dev/null || print_warning "Failed to set nr_requests for /dev/$disk"
        fi
         if [ -f "$READ_AHEAD_PATH" ]; then
            echo 256 > "$READ_AHEAD_PATH" 2>/dev/null || print_warning "Failed to set read_ahead_kb for /dev/$disk"
        fi
    else
        print_status "No I/O scheduler path found for /dev/$disk (e.g., /sys/block/$disk/queue/scheduler), skipping."
    fi
done

# --- Install Utilities ---
print_section "INSTALLING UTILITIES"
print_status "Installing essential utilities for media server monitoring and management..."

UTILITIES_TO_INSTALL=(
    "smartmontools" # Disk health monitoring (smartctl)
    "htop"          # Interactive process viewer
    "iotop"         # I/O monitor
    "nload"         # Network usage monitor
    "iftop"         # Bandwidth monitor
    "cpufrequtils"  # To manage CPU governor settings
    "jq"            # Useful for parsing JSON output from some services/APIs
)

for util in "${UTILITIES_TO_INSTALL[@]}"; do
    if ! command -v $(echo "$util" | awk '{print $1}') &>/dev/null; then # Check if the primary command of the package exists
        print_status "Installing $util..."
        if ! apt install -y "$util"; then
            print_warning "Failed to install $util. Some monitoring features may not work."
        fi
    else
        print_status "$util is already installed."
    fi
done

# --- CPU Governor Settings ---
print_section "CPU GOVERNOR SETTINGS"

CPU_GOVERNOR_SERVICE="/etc/systemd/system/cpu-governor.service"

if [ "$MAX_PERFORMANCE" = true ]; then
    print_status "Configuring CPU governor to performance mode..."
    GOVERNOR="performance"
else
    print_status "Configuring CPU governor to ondemand mode for power efficiency..."
    GOVERNOR="ondemand"
fi

# Create a service to set CPU governor at boot
print_status "Creating systemd service to set CPU governor at boot ($GOVERNOR)..."
cat > "$CPU_GOVERNOR_SERVICE" << EOF
[Unit]
Description=CPU Governor Service
After=multi-user.target

[Service]
Type=oneshot
# Set governor for all online CPUs
ExecStart=/bin/sh -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do if [ -f "\$cpu" ]; then echo $GOVERNOR > "\$cpu"; fi; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

if ! systemctl daemon-reload; then
    print_warning "Failed to reload systemd daemon."
fi

if ! systemctl enable --now cpu-governor.service; then
     print_warning "Failed to enable and start cpu-governor.service. CPU governor might not be set correctly at boot."
else
    print_status "CPU governor service enabled and started ($GOVERNOR)."
fi

# --- Install Media Server Software (Optional) ---
if [ "$INSTALL_MEDIA_SERVER_SOFTWARE" = true ] && [ ${#MEDIA_SERVER_PACKAGES[@]} -gt 0 ]; then
    print_section "INSTALLING MEDIA SERVER SOFTWARE"
    print_status "Attempting to install selected media server packages via apt..."
    for pkg in "${MEDIA_SERVER_PACKAGES[@]}"; do
        print_status "Installing $pkg..."
        if apt install -y "$pkg"; then
            print_status "Successfully installed $pkg."
        else
            print_warning "Failed to install $pkg. You may need to add repositories or install manually."
        fi
    done
    print_status "Note: Some media servers (like Plex, Jellyfin) may require manual steps or repository configuration."
fi


# --- Create Maintenance Scripts ---
print_section "CREATING MAINTENANCE SCRIPTS"
print_status "Creating essential maintenance and monitoring scripts..."

# Create comprehensive system monitoring script
STATUS_SCRIPT="/usr/local/bin/media-server-status.sh"
print_status "Creating status script at $STATUS_SCRIPT..."
cat > "$STATUS_SCRIPT" << 'EOF'
#!/bin/bash

# Set terminal colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print header
echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}     RASPBERRY PI MEDIA SERVER STATUS         ${NC}"
echo -e "${BLUE}===============================================${NC}"
echo

# System information
echo -e "${GREEN}SYSTEM INFORMATION:${NC}"
echo "Date & Time: $(date)"
echo "Uptime: $(uptime -p)"
echo "Load Average: $(uptime | awk -F'load average:' '{print $2}')"
echo

# CPU information
echo -e "${GREEN}CPU STATUS:${NC}"
if command -v vcgencmd &>/dev/null; then
    echo "Temperature: $(vcgencmd measure_temp | cut -d '=' -f2)"
fi
GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A (check /sys/devices/system/cpu/)")
echo "CPU Governor: $GOVERNOR"
if command -v vcgencmd &>/dev/null; then
    echo "CPU Frequency: $(vcgencmd measure_clock arm | awk -F'=' '{printf "%.0f MHz\n", $2/1000000}')"
fi
echo "CPU Usage:"
# Use a short sample with mpstat if available, otherwise use top
if command -v mpstat &>/dev/null; then
    mpstat -P ALL 1 1 | tail -n +4 | head -n -1 # All CPUs, 1 sec sample, skip header/footer
else
    # Fallback for basic top output
    top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/Idle: \1%/"
fi
echo

# Memory usage
echo -e "${GREEN}MEMORY USAGE:${NC}"
free -h

# Swap usage
echo -e "\n${GREEN}SWAP USAGE:${NC}"
free -h | grep Swap

# Disk usage
echo -e "\n${GREEN}DISK USAGE:${NC}"
df -h -x tmpfs -x devtmpfs

# Network status
echo -e "\n${GREEN}NETWORK STATUS:${NC}"
IP_ADDR=$(hostname -I | awk '{print $1}')
echo "IP Address: $IP_ADDR"
echo "Active Network Connections: $(netstat -an | grep ESTABLISHED | wc -l)"
echo "Network Interface Statistics (Example - adjust interface if needed, e.g., eth0, wlan0):"
if command -v nload &>/dev/null; then
    echo "Run 'nload' or 'iftop' for real-time network monitoring."
elif command -v vnstat &>/dev/null; then
    vnstat -i eth0 # Example, assumes eth0. Install vnstat if desired.
else
    echo "Install nload, iftop, or vnstat for more detailed network stats."
fi
echo

# Running services (Illustrative examples - adjust list as needed)
echo -e "${GREEN}POTENTIALLY INTERESTING SERVICE STATUS (Examples):${NC}"
SERVICES_TO_CHECK=(
    "ssh.service" # SSH server
    "smbd.service" # Samba/SMB server
    "nfs-server.service" # NFS server
    "minidlna.service" # MiniDLNA server
    "plexmediaserver.service" # Plex Media Server
    "emby-server.service" # Emby Server
    "jellyfin.service" # Jellyfin Server
    "transmission-daemon.service" # Transmission BitTorrent client
    "sonarr.service" # Sonarr
    "radarr.service" # Radarr
    "docker.service" # Docker (if running containers)
)

for SERVICE in "${SERVICES_TO_CHECK[@]}"; do
    # Check if the service unit file exists before querying state
    if systemctl list-unit-files --type=service | grep -q "^$SERVICE"; then
        if systemctl is-active --quiet "$SERVICE"; then
            echo -e "$SERVICE: ${GREEN}active (running)${NC}"
        elif systemctl is-enabled --quiet "$SERVICE"; then
            echo -e "$SERVICE: ${RED}inactive (dead)${NC} (but enabled to start at boot)"
        else
             echo -e "$SERVICE: ${YELLOW}inactive (dead)${NC} (and disabled)"
        fi
    else
        # Service unit file does not exist
        echo -e "$SERVICE: ${YELLOW}not found${NC} (likely not installed)"
    fi
done

echo -e "\n${BLUE}===============================================${NC}"
EOF
if ! chmod +x "$STATUS_SCRIPT"; then
    print_warning "Failed to make $STATUS_SCRIPT executable."
fi


# Create comprehensive maintenance script
MAINTENANCE_SCRIPT="/usr/local/bin/media-server-maintenance.sh"
print_status "Creating maintenance script at $MAINTENANCE_SCRIPT..."
cat > "$MAINTENANCE_SCRIPT" << 'EOF'
#!/bin/bash

# Set up logging
LOG_FILE="/var/log/media-server-maintenance.log"
echo "=== Media Server Maintenance Run: $(date) ===" | tee -a "$LOG_FILE"

# Perform system cleanup
echo "--- Performing system cleanup ---" | tee -a "$LOG_FILE"
echo "Running apt autoremove, autoclean, clean..." | tee -a "$LOG_FILE"
apt update >> "$LOG_FILE" 2>&1 # Update lists first for better autoremove
apt autoremove -y >> "$LOG_FILE" 2>&1
apt autoclean -y >> "$LOG_FILE" 2>&1
apt clean -y >> "$LOG_FILE" 2>&1
echo "System cleanup complete." | tee -a "$LOG_FILE"

# Clear old logs using journalctl vacuum
echo "--- Clearing old logs ---" | tee -a "$LOG_FILE"
# Keep logs for 7 days, remove older
if command -v journalctl &>/dev/null; then
    echo "Vacuuming journal logs (keeping 7 days)..." | tee -a "$LOG_FILE"
    journalctl --vacuum-time=7d >> "$LOG_FILE" 2>&1 || echo "journalctl vacuum failed." | tee -a "$LOG_FILE"
else
    echo "journalctl command not found, skipping journal vacuum." | tee -a "$LOG_FILE"
fi
# Find and remove compressed/old log files
echo "Removing old compressed/rotated log files..." | tee -a "$LOG_FILE"
find /var/log -type f -name "*.gz" -delete -print >> "$LOG_FILE" 2>&1 || true
find /var/log -type f -name "*.1" -delete -print >> "$LOG_FILE" 2>&1 || true
find /var/log -type f -name "*.old" -delete -print >> "$LOG_FILE" 2>&1 || true
echo "Log cleanup complete." | tee -a "$LOG_FILE"


# Clear temporary files older than 1 day
echo "--- Clearing temporary files ---" | tee -a "$LOG_FILE"
echo "Removing files older than 1 day in /tmp and /var/tmp..." | tee -a "$LOG_FILE"
find /tmp -type f -atime +1 -delete -print >> "$LOG_FILE" 2>&1 || true
find /var/tmp -type f -atime +1 -delete -print >> "$LOG_FILE" 2>&1 || true
echo "Temporary file cleanup complete." | tee -a "$LOG_FILE"

# Drop cache to free up memory
echo "--- Freeing up memory cache ---" | tee -a "$LOG_FILE"
echo "Dropping caches..." | tee -a "$LOG_FILE"
sync # Ensure all writes are committed
if echo 3 > /proc/sys/vm/drop_caches; then
    echo "Memory caches dropped." | tee -a "$LOG_FILE"
else
     echo "Failed to drop memory caches (requires root)." | tee -a "$LOG_FILE"
fi


# Check for system updates without installing
echo "--- Checking for available updates ---" | tee -a "$LOG_FILE"
echo "Running apt update..." | tee -a "$LOG_FILE"
apt update >> "$LOG_FILE" 2>&1
UPDATES=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)
if [ "$UPDATES" -gt 0 ]; then
    echo "There are $UPDATES updates available." | tee -a "$LOG_FILE"
    echo "Run 'sudo apt upgrade' to install them." | tee -a "$LOG_FILE"
    apt list --upgradable >> "$LOG_FILE" 2>&1
else
    echo "System is up to date." | tee -a "$LOG_FILE"
fi
echo "Update check complete." | tee -a "$LOG_FILE"

# Check disk health using smartctl
echo "--- Checking disk health ---" | tee -a "$LOG_FILE"
if command -v smartctl &>/dev/null; then
    DRIVES=$(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" {print $1}') # Get only disk devices
    if [ -z "$DRIVES" ]; then
        echo "No disk devices found to check with smartctl." | tee -a "$LOG_FILE"
    else
        echo "Checking SMART status for disk(s): $DRIVES" | tee -a "$LOG_FILE"
        for drive in $DRIVES; do
            echo "Checking /dev/$drive:" | tee -a "$LOG_FILE"
            if smartctl -H /dev/$drive >> "$LOG_FILE" 2>&1; then
                echo "SMART Health Test Result for /dev/$drive: PASS" | tee -a "$LOG_FILE"
            else
                echo "SMART Health Test Result for /dev/$drive: FAIL or not available/supported." | tee -a "$LOG_FILE"
                echo "Run 'sudo smartctl -a /dev/$drive' for details." | tee -a "$LOG_FILE"
            fi
        done
    fi
else
    echo "smartctl not installed, skipping SMART checks. Install 'smartmontools' package." | tee -a "$LOG_FILE"
fi
echo "Disk health check complete." | tee -a "$LOG_FILE"

# Check file system status (non-destructive)
echo "--- Checking file system status (non-destructive) ---" | tee -a "$LOG_FILE"
echo "Running e2fsck -n on mounted ext* partitions (read-only check)..." | tee -a "$LOG_FILE"
# Find mounted ext2, ext3, ext4 partitions that are not root or swap or snapshots
MOUNTED_EXT_PARTITIONS=$(findmnt -l -t ext2,ext3,ext4 -o SOURCE,TARGET -n | grep -v -E '^rootfs|/boot' | awk '{print $1}') # Exclude rootfs (checked by systemd on boot), /boot
if [ -z "$MOUNTED_EXT_PARTITIONS" ]; then
     echo "No suitable mounted ext* partitions found for non-destructive check." | tee -a "$LOG_FILE"
else
    for partition in $MOUNTED_EXT_PARTITIONS; do
        echo "Checking $partition:" | tee -a "$LOG_FILE"
        # e2fsck -n is read-only, safe on mounted partitions
        e2fsck -n "$partition" >> "$LOG_FILE" 2>&1 || echo "e2fsck -n for $partition reported issues or encountered errors. Check log for details." | tee -a "$LOG_FILE"
    done
fi
echo "File system check complete." | tee -a "$LOG_FILE"


echo "=== Maintenance completed at $(date) ===" | tee -a "$LOG_FILE"

# Print a summary to the console
echo
echo -e "${GREEN}Media server maintenance completed.${NC}"
echo "Log file: $LOG_FILE"
echo "Last 20 lines of log:"
tail -n 20 "$LOG_FILE"
echo
EOF
if ! chmod +x "$MAINTENANCE_SCRIPT"; then
    print_warning "Failed to make $MAINTENANCE_SCRIPT executable."
fi

# Create a script to optimize for script execution
OPTIMIZE_SCRIPT="/usr/local/bin/optimize-for-scripts.sh"
print_status "Creating optimization script for script execution at $OPTIMIZE_SCRIPT..."
cat > "$OPTIMIZE_SCRIPT" << 'EOF'
#!/bin/bash
# Temporarily optimize system for script execution
# Run this before executing resource-intensive scripts (e.g., large file operations, transcoding)

echo "Optimizing system for script execution..."
# Drop caches
echo "Dropping caches..."
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || echo "Failed to drop caches (requires root)."

# Set CPU governor to performance temporarily
echo "Setting CPU governor to performance..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    if [ -f "$cpu" ]; then
        echo performance > "$cpu" 2>/dev/null || echo "Warning: Failed to set performance governor for $cpu."
    fi
done

# Minimize swapping temporarily
echo "Setting swappiness to 0..."
echo 0 > /proc/sys/vm/swappiness 2>/dev/null || echo "Failed to set swappiness (requires root)."

echo "System optimized for script execution. Run your scripts now."
echo "After completion, run 'sudo /usr/local/bin/restore-normal-operation.sh' to restore normal settings."
EOF
if ! chmod +x "$OPTIMIZE_SCRIPT"; then
    print_warning "Failed to make $OPTIMIZE_SCRIPT executable."
fi

# Create restoration script
RESTORE_SCRIPT="/usr/local/bin/restore-normal-operation.sh"
print_status "Creating restoration script at $RESTORE_SCRIPT..."
cat > "$RESTORE_SCRIPT" << 'EOF'
#!/bin/bash
# Restore normal operation settings
# Run this after your intensive scripts complete

echo "Restoring normal operation settings..."

# Restore CPU governor to the setting configured by the service
# If the service is enabled, starting/restarting it applies its configured governor (ondemand or performance from optimization script)
echo "Restoring CPU governor via systemd service..."
CPU_GOVERNOR_SERVICE="/etc/systemd/system/cpu-governor.service"
if systemctl list-unit-files --type=service | grep -q "^cpu-governor.service"; then
    if systemctl is-enabled --quiet cpu-governor.service; then
        systemctl start cpu-governor.service 2>/dev/null || echo "Warning: Failed to start cpu-governor.service to restore governor."
    else
         echo "Warning: cpu-governor.service is not enabled. Governor not automatically restored."
         echo "Consider running 'sudo systemctl enable --now cpu-governor.service' or setting it manually."
         # Fallback to setting ondemand if service is not enabled
         echo "Attempting to set governor to ondemand as fallback..."
         for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
             if [ -f "$cpu" ]; then
                echo ondemand > "$cpu" 2>/dev/null || echo "Warning: Failed to set ondemand governor for $cpu."
            fi
         done
    fi
else
     echo "Warning: cpu-governor.service not found. Governor not automatically restored."
     # Fallback to setting ondemand if service doesn't exist
     echo "Attempting to set governor to ondemand as fallback..."
     for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
         if [ -f "$cpu" ]; then
            echo ondemand > "$cpu" 2>/dev/null || echo "Warning: Failed to set ondemand governor for $cpu."
        fi
     done
fi


# Restore swappiness to the setting configured by sysctl (default is 60, script sets 1)
echo "Restoring swappiness..."
SWAPPINESS_SYSCTL=$(sysctl -n vm.swappiness 2>/dev/null)
if [ -n "$SWAPPINESS_SYSCTL" ]; then
    echo "$SWAPPINESS_SYSCTL" > /proc/sys/vm/swappiness 2>/dev/null || echo "Failed to set swappiness to $SWAPPINESS_SYSCTL (requires root)."
else
    echo "Warning: Could not read vm.swappiness sysctl value. Defaulting swappiness to 1."
    echo 1 > /proc/sys/vm/swappiness 2>/dev/null || echo "Failed to set swappiness to 1 (requires root)."
fi

echo "Normal settings restored (check logs for warnings)."
EOF
if ! chmod +x "$RESTORE_SCRIPT"; then
    print_warning "Failed to make $RESTORE_SCRIPT executable."
fi

# Create a disk usage monitoring script
DISK_USAGE_SCRIPT="/usr/local/bin/check-disk-usage.sh"
print_status "Creating disk usage monitoring script at $DISK_USAGE_SCRIPT..."
cat > "$DISK_USAGE_SCRIPT" << 'EOF'
#!/bin/bash
THRESHOLD=85
# Check usage for the root partition '/'
USAGE=$(df -P / | awk 'NR==2 {gsub(/%/, ""); print $5}') # Use -P for POSIX format, safer parsing
DISK="/dev/$(df -P / | awk 'NR==2 {print $1}' | sed 's/\/dev\///')" # Get device name

if [ -z "$USAGE" ]; then
    echo "Error: Could not determine disk usage for /"
    exit 1
fi

echo "Disk usage for $DISK (mounted at /): $USAGE%"

if [ "$USAGE" -gt "$THRESHOLD" ]; then
    echo "WARNING: Disk usage for $DISK is at $USAGE%, which is above the $THRESHOLD% threshold."
    
    echo -e "\nTop 10 largest directories in / (excluding /proc, /sys, /dev, /run, /mnt, /media, /tmp, /var/tmp):"
    # Use du -h --max-depth=1 on / excluding common non-persistent or external mount points
    # Add -x to stay on the same filesystem as / if needed, but excluding specific paths is often more useful
    du -h --max-depth=1 / \
        --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/mnt --exclude=/media --exclude=/tmp --exclude=/var/tmp \
        2>/dev/null | sort -hr | head -11 # head -11 to get the top 10 plus the total

    # Check for large log files
    echo -e "\nLarge log files (>50MB) in /var/log:"
    find /var/log -type f -size +50M -exec ls -lh {} \; 2>/dev/null || echo "No large logs found or search failed."
    
    # Check for large files (>500MB) in home directories (can adjust size)
    echo -e "\nLarge files (>500MB) in home directories:"
    find /home -type f -size +500M -exec ls -lh {} \; 2>/dev/null || echo "No large files in home found or search failed."

    echo -e "\nConsider deleting unnecessary files or expanding storage."
fi
EOF
if ! chmod +x "$DISK_USAGE_SCRIPT"; then
    print_warning "Failed to make $DISK_USAGE_SCRIPT executable."
fi

# Add to daily cron if not already present
print_status "Setting up daily cron job for disk usage check..."
DAILY_CRON_LINK="/etc/cron.daily/check-disk-usage"
if [ ! -f "$DAILY_CRON_LINK" ]; then
    if ! ln -s "$DISK_USAGE_SCRIPT" "$DAILY_CRON_LINK"; then
        print_warning "Failed to create daily cron link for disk usage script."
    else
        print_status "Daily disk usage check scheduled via $DAILY_CRON_LINK."
    fi
else
    print_status "Daily disk usage cron link already exists."
fi


# Create a weekly cron job for maintenance
print_status "Setting up weekly scheduled maintenance task..."
CRON_D_FILE="/etc/cron.d/media-server-maintenance"
echo "# Run media server maintenance weekly (e.g., 3:00 AM Monday)" > "$CRON_D_FILE"
echo "0 3 * * 1 root $MAINTENANCE_SCRIPT" >> "$CRON_D_FILE"
if ! chmod 644 "$CRON_D_FILE"; then # cron.d files need specific permissions
    print_warning "Failed to set permissions for $CRON_D_FILE."
fi
print_status "Weekly maintenance scheduled via $CRON_D_FILE."


# --- Security Enhancements ---
print_section "SECURITY ENHANCEMENTS"
print_status "Applying basic security enhancements..."

# Install fail2ban to protect SSH
if ! command -v fail2ban-client &>/dev/null; then
    print_status "Installing fail2ban..."
    if ! apt install -y fail2ban; then
        print_warning "Failed to install fail2ban. Skipping fail2ban configuration."
    else
        print_status "Configuring fail2ban for SSH..."
        FAIL2BAN_JAIL="/etc/fail2ban/jail.local"
        # Check if sshd section already exists to avoid duplication
        if ! grep -q "\[sshd\]" "$FAIL2BAN_JAIL" 2>/dev/null; then
             cat >> "$FAIL2BAN_JAIL" << 'EOF'

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600 ; 1 hour
findtime = 600 ; 10 minutes
EOF
            print_status "Added sshd jail configuration to $FAIL2BAN_JAIL."
        else
            print_status "sshd jail configuration already present in $FAIL2BAN_JAIL."
        fi
        # Enable and restart fail2ban service
        if systemctl list-unit-files --type=service | grep -q "^fail2ban.service"; then
            if ! systemctl enable --now fail2ban.service; then
                 print_warning "Failed to enable and start fail2ban service."
            else
                print_status "fail2ban service enabled and started."
            fi
        else
             print_warning "fail2ban.service not found. Check fail2ban installation."
        fi
    fi
else
    print_status "fail2ban is already installed."
    # Ensure it's enabled if already installed
    if systemctl list-unit-files --type=service | grep -q "^fail2ban.service"; then
        if ! systemctl is-enabled --quiet fail2ban.service; then
             print_status "Enabling fail2ban service..."
             if ! systemctl enable --now fail2ban.service; then
                 print_warning "Failed to enable and start fail2ban service."
             else
                 print_status "fail2ban service enabled and started."
             fi
        else
            print_status "fail2ban service is already enabled."
        fi
    fi
fi


# Set up SSH hardening if SSH is installed
SSH_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSH_CONFIG" ]; then
    print_status "Hardening SSH configuration in $SSH_CONFIG..."

    # Use safe_edit_file for sshd_config
    safe_edit_file "$SSH_CONFIG" '
        /^#*PermitRootLogin/ { s/^.*$/PermitRootLogin no/ };
        /^#*Protocol/ { s/^.*$/Protocol 2/ };
        /^#*PermitEmptyPasswords/ { s/^.*$/PermitEmptyPasswords no/ };
        /^#*X11Forwarding/ { s/^.*$/X11Forwarding no/ };
        /^#*LoginGraceTime/ { s/^.*$/LoginGraceTime 30/ }
    '

    # Restart SSH service
    print_status "Restarting SSH service..."
    if systemctl list-unit-files --type=service | grep -q "^ssh.service"; then
        if ! systemctl restart ssh.service; then
            print_warning "Failed to restart SSH service. You may need to do this manually for changes to take effect."
        else
             print_status "SSH service restarted."
        fi
    else
        print_warning "ssh.service not found. Skipping SSH service restart."
    fi
else
    print_warning "$SSH_CONFIG not found. SSH hardening skipped."
fi

# --- Create Helpful README file ---
print_section "CREATING DOCUMENTATION"
README_FILE="/root/MEDIA_SERVER_README.md" # Save README in /root as script runs as root
print_status "Creating README file with system information at $README_FILE..."

cat > "$README_FILE" << EOF
# Raspberry Pi Media Server - System Information

This Raspberry Pi has been optimized as a media server on $(date).

## System Information
- Model: $PI_MODEL
- Memory: $PI_MEMORY
- Operating System: $OS_PRETTY_NAME
- Kernel: $KERNEL_VERSION
- Architecture: $ARCH

## Optimizations Applied
- System packages optimized for media server usage
- Unnecessary services disabled (see script log \`/var/log/rpi-media-server-optimization_$SCRIPT_START_TIME.log\` for details)
- Memory and network settings tuned for media streaming (\`/etc/sysctl.d/99-media-server.conf\`)
- File system optimized (noatime on ext4, tmpfs for /tmp)
- $([ "$MAX_PERFORMANCE" = true ] && echo "/var/log placed on tmpfs (logs are non-persistent across reboots)" || echo "/var/log remains on persistent storage")
- I/O scheduler settings adjusted for better disk performance
- Maintenance scripts installed (\`/usr/local/bin/\`)
- $([ "$INSTALL_MEDIA_SERVER_SOFTWARE" = true ] && echo "Attempted to install packages: ${MEDIA_SERVER_PACKAGES[*]}" || echo "No media server packages were automatically installed by this script")
- $([ "$REMOVE_GUI" = true ] && echo "GUI packages removed" || echo "GUI packages retained")
- $([ "$DISABLE_WIRELESS" = true ] && echo "Wireless services disabled" || echo "Wireless services retained")
- $([ "$MAX_PERFORMANCE" = true ] && echo "System optimized for maximum performance (performance CPU governor)" || echo "System optimized for balanced performance (ondemand CPU governor)")
- $([ "$SECURITY_UPDATES" = true ] && echo "Automatic security updates enabled (\`/etc/apt/apt.conf.d/50unattended-upgrades\`)" || echo "Automatic updates disabled, manual updates recommended periodically (\`/usr/local/bin/manual-update.sh\`)")

## Available Maintenance Tools (run with \`sudo\`)

### System Status
- Check comprehensive system status: \`/usr/local/bin/media-server-status.sh\`

### Maintenance
- Run manual maintenance tasks (cleanup, log clear, disk check): \`/usr/local/bin/media-server-maintenance.sh\`
- Check disk usage and report large files: \`/usr/local/bin/check-disk-usage.sh\` (Runs daily via cron)
- $([ "$SECURITY_UPDATES" = false ] && echo "Update system manually: \`/usr/local/bin/manual-update.sh\`" || echo "Security updates run automatically daily")

### Performance Optimization
- Optimize system temporarily for script execution (e.g., transcoding): \`/usr/local/bin/optimize-for-scripts.sh\`
- Restore normal settings after running intensive scripts: \`/usr/local/bin/restore-normal-operation.sh\`

## Scheduled Tasks
- Weekly Maintenance (\`/usr/local/bin/media-server-maintenance.sh\`) scheduled via \`/etc/cron.d/media-server-maintenance\`
- Daily Disk Usage Check (\`/usr/local/bin/check-disk-usage.sh\`) scheduled via \`/etc/cron.daily/check-disk-usage\`
- $([ "$SECURITY_UPDATES" = true ] && echo "Daily Automatic Security Updates via unattended-upgrades" || echo "")

## Security
- fail2ban configured to protect SSH (\`/etc/fail2ban/jail.local\`)
- SSH hardened (e.g., root login disabled, Protocol 2 only) (\`/etc/ssh/sshd_config\`)

## System Backup
A backup of your system configuration was created before optimization:
\`$BACKUP_DIR\`
This includes key configuration files and a list of installed packages.

## Important Notes
- **Reboot:** It is strongly recommended to reboot your system after the script finishes to apply all kernel, filesystem, and service changes.
- **Temperature:** Monitor system temperature during heavy loads (\`vcgencmd measure_temp\` or \`/sys/class/thermal/thermal_zone*/temp\`).
- **Disk Health:** Check disk health regularly with \`sudo smartctl -H /dev/sda\` (replace \`sda\` with your actual device, check \`lsblk\`). The weekly maintenance script performs a basic check.
- **Logs:** If you encounter issues, check the script's log file (\`$LOG_FILE\`) and system journal (\`sudo journalctl -xe\`).
- **tmpfs /var/log:** If enabled, logs in \`/var/log\` will be lost on every reboot. Consider using a remote log server or other persistence methods if full log history is required.

---
Created by Raspberry Pi Media Server Optimization Script v2.1
Review the script source (\`$(realpath "$0")\`) for full details.
EOF

if ! chmod 644 "$README_FILE"; then
    print_warning "Failed to set permissions for $README_FILE."
fi

# --- Final System Cleanup ---
print_section "FINAL SYSTEM CLEANUP"
print_status "Performing final system cleanup and updating package lists..."
if ! apt update; then
    print_warning "Failed to run final apt update."
fi
if ! apt autoremove -y; then
    print_warning "Failed to run final apt autoremove."
fi
if ! apt autoclean -y; then
    print_warning "Failed to run final apt autoclean."
fi
if ! apt clean -y; then
    print_warning "Failed to run final apt clean."
fi
if command -v journalctl &>/dev/null; then
     print_status "Vacuuming journal logs again (keeping 7 days)..."
     journalctl --vacuum-time=7d >> "$LOG_FILE" 2>&1 || print_warning "Final journalctl vacuum failed."
else
    print_warning "journalctl command not found, skipping final journal vacuum."
fi


# --- Summary and Reboot ---
print_section "OPTIMIZATION COMPLETE"
print_status "System optimization script finished."
print_status "Backup files are stored in $BACKUP_DIR"
print_status "A summary of changes and tools is in $README_FILE"
print_status "The full script log is available at $LOG_FILE"
echo

print_warning "It's highly recommended to reboot your system now to apply all changes (kernel, filesystem, tmpfs, service masks)."
echo

# Ask for reboot
if ask_yes_no "Would you like to reboot your system now?"; then
    print_status "Rebooting system..."
    # Use systemctl reboot for clean shutdown
    systemctl reboot
else
    print_status "Remember to reboot your system later ('sudo reboot') to apply all changes."
fi

print_status "Script execution finished."

exit 0 # Explicitly exit with success code
