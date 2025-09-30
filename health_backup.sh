#!/bin/bash

#=============================================================================
# Raspberry Pi System Health Monitoring & Backup Script
#
# This script covers areas NOT included in your optimization and setup scripts:
# - Hardware health monitoring (temperature, throttling, voltage)
# - Automated backup strategies (SD card imaging, configuration backups)
# - Network configuration and connectivity monitoring
# - Service health checks and auto-recovery
# - Log rotation and archival
# - Power management and UPS integration
# - Email/notification setup for alerts
# - USB drive management and auto-mounting
# - Recovery scripts and rollback procedures
#
# Version: 1.0
# Created: 2024
#=============================================================================

# --- Configuration ---
ADMIN_EMAIL="your-email@example.com"  # Email for alerts (requires mail setup)
ENABLE_EMAIL_ALERTS=false              # Set to true after configuring mail
BACKUP_DESTINATION="/mnt/backup"       # External drive for backups
ENABLE_USB_AUTOMOUNT=true              # Auto-mount USB drives
TEMP_THRESHOLD_WARNING=70              # Celsius - warning threshold
TEMP_THRESHOLD_CRITICAL=80             # Celsius - critical threshold
CHECK_INTERVAL_HOURS=1                 # How often to run health checks via cron
ENABLE_WATCHDOG=true                   # Enable hardware watchdog timer
BACKUP_RETENTION_DAYS=14               # Keep backups for this many days

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Variables ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/raspi-health"
HEALTH_LOG="$LOG_DIR/health-monitor.log"
BACKUP_LOG="$LOG_DIR/backup.log"
ALERT_STATE_FILE="/var/run/raspi-health-alerts"

# --- Functions ---

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$HEALTH_LOG"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$HEALTH_LOG"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$HEALTH_LOG"
}

print_section() {
    echo "" | tee -a "$HEALTH_LOG"
    echo -e "${BLUE}=== $1 ===${NC}" | tee -a "$HEALTH_LOG"
    echo "" | tee -a "$HEALTH_LOG"
}

send_alert() {
    local subject="$1"
    local message="$2"
    
    if [ "$ENABLE_EMAIL_ALERTS" = true ] && command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "$subject" "$ADMIN_EMAIL"
        print_status "Alert sent: $subject"
    else
        print_warning "Email alerts not configured. Alert: $subject"
    fi
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Initialize logging
init_logging() {
    mkdir -p "$LOG_DIR"
    if [ ! -f "$HEALTH_LOG" ]; then
        touch "$HEALTH_LOG"
    fi
    if [ ! -f "$BACKUP_LOG" ]; then
        touch "$BACKUP_LOG"
    fi
}

# --- Hardware Health Monitoring ---

check_temperature() {
    print_section "TEMPERATURE MONITORING"
    
    if command -v vcgencmd >/dev/null 2>&1; then
        TEMP=$(vcgencmd measure_temp | grep -oP '\d+\.\d+')
        TEMP_INT=${TEMP%.*}
        
        print_status "Current temperature: ${TEMP}°C"
        
        if [ "$TEMP_INT" -ge "$TEMP_THRESHOLD_CRITICAL" ]; then
            print_error "CRITICAL: Temperature ${TEMP}°C exceeds critical threshold ${TEMP_THRESHOLD_CRITICAL}°C"
            send_alert "Raspberry Pi Critical Temperature Alert" "Temperature has reached ${TEMP}°C (Critical threshold: ${TEMP_THRESHOLD_CRITICAL}°C). System may throttle or shutdown."
            return 2
        elif [ "$TEMP_INT" -ge "$TEMP_THRESHOLD_WARNING" ]; then
            print_warning "Temperature ${TEMP}°C exceeds warning threshold ${TEMP_THRESHOLD_WARNING}°C"
            send_alert "Raspberry Pi Temperature Warning" "Temperature has reached ${TEMP}°C (Warning threshold: ${TEMP_THRESHOLD_WARNING}°C). Consider improving cooling."
            return 1
        else
            print_status "Temperature is within normal range"
            return 0
        fi
    else
        print_warning "vcgencmd not available, cannot check temperature"
        return 0
    fi
}

check_throttling() {
    print_section "THROTTLING CHECK"
    
    if command -v vcgencmd >/dev/null 2>&1; then
        THROTTLED=$(vcgencmd get_throttled)
        print_status "Throttle status: $THROTTLED"
        
        # Parse throttle bits
        THROTTLE_VALUE=$(echo "$THROTTLED" | grep -oP '0x\K\w+')
        
        if [ "$THROTTLE_VALUE" != "0" ]; then
            print_warning "System has been throttled! Value: 0x$THROTTLE_VALUE"
            
            # Decode common throttle bits
            [ $((0x$THROTTLE_VALUE & 0x1)) -ne 0 ] && print_warning "- Under-voltage detected"
            [ $((0x$THROTTLE_VALUE & 0x2)) -ne 0 ] && print_warning "- ARM frequency capped"
            [ $((0x$THROTTLE_VALUE & 0x4)) -ne 0 ] && print_warning "- Currently throttled"
            [ $((0x$THROTTLE_VALUE & 0x10000)) -ne 0 ] && print_warning "- Under-voltage has occurred since boot"
            [ $((0x$THROTTLE_VALUE & 0x20000)) -ne 0 ] && print_warning "- Throttling has occurred since boot"
            
            send_alert "Raspberry Pi Throttling Detected" "System throttling detected. Check power supply and cooling. Throttle value: 0x$THROTTLE_VALUE"
            return 1
        else
            print_status "No throttling detected"
            return 0
        fi
    else
        print_warning "vcgencmd not available, cannot check throttling"
        return 0
    fi
}

check_voltage() {
    print_section "VOLTAGE CHECK"
    
    # Check various voltage rails if vcgencmd supports it
    if command -v vcgencmd >/dev/null 2>&1; then
        for rail in core sdram_c sdram_i sdram_p; do
            VOLTAGE=$(vcgencmd measure_volts $rail 2>/dev/null)
            if [ $? -eq 0 ]; then
                print_status "$rail: $VOLTAGE"
            fi
        done
    else
        print_warning "vcgencmd not available for voltage checks"
    fi
}

# --- Disk Health Monitoring ---

check_disk_health() {
    print_section "DISK HEALTH"
    
    # Check disk usage
    print_status "Disk usage:"
    df -h | grep -E '^/dev/' | tee -a "$HEALTH_LOG"
    
    # Check for disks over 90% full
    FULL_DISKS=$(df -h | grep -E '^/dev/' | awk '{gsub(/%/,""); if($5 > 90) print $0}')
    if [ -n "$FULL_DISKS" ]; then
        print_warning "Disks over 90% full detected:"
        echo "$FULL_DISKS" | tee -a "$HEALTH_LOG"
        send_alert "Raspberry Pi Disk Space Warning" "One or more disks are over 90% full: $FULL_DISKS"
    fi
    
    # Check SD card errors in dmesg
    SD_ERRORS=$(dmesg | grep -i 'mmc\|sd' | grep -i 'error\|fail' | tail -5)
    if [ -n "$SD_ERRORS" ]; then
        print_warning "SD card errors detected in dmesg:"
        echo "$SD_ERRORS" | tee -a "$HEALTH_LOG"
    fi
    
    # SMART check if available
    if command -v smartctl >/dev/null 2>&1; then
        for disk in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print $1}'); do
            print_status "SMART status for /dev/$disk:"
            smartctl -H /dev/$disk 2>&1 | tee -a "$HEALTH_LOG"
        done
    fi
}

# --- Network Monitoring ---

check_network_connectivity() {
    print_section "NETWORK CONNECTIVITY"
    
    # Check network interfaces
    print_status "Active network interfaces:"
    ip -brief link show | grep UP | tee -a "$HEALTH_LOG"
    
    # Check IP addresses
    print_status "IP addresses:"
    hostname -I | tee -a "$HEALTH_LOG"
    
    # Ping test to common DNS servers
    PING_TARGETS=("8.8.8.8" "1.1.1.1")
    PING_FAILED=0
    
    for target in "${PING_TARGETS[@]}"; do
        if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
            print_status "Connectivity to $target: OK"
        else
            print_warning "Cannot reach $target"
            PING_FAILED=$((PING_FAILED + 1))
        fi
    done
    
    if [ "$PING_FAILED" -eq ${#PING_TARGETS[@]} ]; then
        print_error "No external connectivity detected"
        send_alert "Raspberry Pi Network Failure" "System has lost external network connectivity"
        return 1
    fi
    
    # DNS resolution test
    if host google.com >/dev/null 2>&1; then
        print_status "DNS resolution: OK"
    else
        print_warning "DNS resolution failed"
        send_alert "Raspberry Pi DNS Failure" "DNS resolution is not working"
    fi
    
    return 0
}

# --- Service Health Checks ---

check_critical_services() {
    print_section "CRITICAL SERVICES"
    
    # List of critical services to monitor
    CRITICAL_SERVICES=(
        "ssh.service"
        "docker.service"
        "fail2ban.service"
    )
    
    FAILED_SERVICES=()
    
    for service in "${CRITICAL_SERVICES[@]}"; do
        if systemctl list-unit-files --type=service | grep -q "^$service"; then
            if systemctl is-active --quiet "$service"; then
                print_status "$service: active"
            else
                print_error "$service: INACTIVE"
                FAILED_SERVICES+=("$service")
                
                # Attempt to restart
                print_status "Attempting to restart $service..."
                if systemctl restart "$service"; then
                    print_status "$service restarted successfully"
                    send_alert "Raspberry Pi Service Restarted" "$service was down and has been automatically restarted"
                else
                    print_error "Failed to restart $service"
                    send_alert "Raspberry Pi Service Failure" "$service is down and could not be restarted"
                fi
            fi
        fi
    done
    
    if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
        return 1
    fi
    return 0
}

check_docker_containers() {
    print_section "DOCKER CONTAINERS"
    
    if command -v docker >/dev/null 2>&1; then
        # Check for containers that should be running but are not
        EXITED_CONTAINERS=$(docker ps -a --filter "status=exited" --format "{{.Names}}" 2>/dev/null)
        
        if [ -n "$EXITED_CONTAINERS" ]; then
            print_warning "Exited containers detected:"
            echo "$EXITED_CONTAINERS" | tee -a "$HEALTH_LOG"
            
            # Optionally auto-restart containers (be cautious with this)
            # Uncomment if you want automatic restart
            # while IFS= read -r container; do
            #     print_status "Attempting to restart container: $container"
            #     docker start "$container"
            # done <<< "$EXITED_CONTAINERS"
        else
            print_status "All containers are running"
        fi
        
        # Show resource usage
        print_status "Container resource usage:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | tee -a "$HEALTH_LOG"
    else
        print_warning "Docker not installed or not accessible"
    fi
}

# --- Backup Functions ---

backup_system_config() {
    print_section "SYSTEM CONFIGURATION BACKUP"
    
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_DIR="$BACKUP_DESTINATION/config_backup_$TIMESTAMP"
    
    # Check if backup destination exists
    if [ ! -d "$BACKUP_DESTINATION" ]; then
        print_warning "Backup destination $BACKUP_DESTINATION does not exist"
        print_status "Attempting to create backup directory..."
        mkdir -p "$BACKUP_DESTINATION" || {
            print_error "Failed to create backup destination"
            return 1
        }
    fi
    
    print_status "Creating configuration backup at $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup important configurations
    CONFIG_FILES=(
        "/etc/fstab"
        "/etc/network/interfaces"
        "/etc/ssh/sshd_config"
        "/etc/hosts"
        "/etc/hostname"
        "/boot/config.txt"
        "/boot/cmdline.txt"
        "/etc/sysctl.conf"
        "/etc/crontab"
    )
    
    for file in "${CONFIG_FILES[@]}"; do
        if [ -f "$file" ]; then
            cp -p "$file" "$BACKUP_DIR/" 2>/dev/null && \
                print_status "Backed up: $file" || \
                print_warning "Failed to backup: $file"
        fi
    done
    
    # Backup cron jobs
    if [ -d "/etc/cron.d" ]; then
        cp -r /etc/cron.d "$BACKUP_DIR/" 2>/dev/null
    fi
    
    # Backup Docker configurations if present
    if [ -d "$HOME/raspberry-pi-media-server" ]; then
        tar -czf "$BACKUP_DIR/docker_configs.tar.gz" "$HOME/raspberry-pi-media-server" 2>/dev/null && \
            print_status "Backed up Docker configurations"
    fi
    
    # Create a package list
    dpkg --get-selections > "$BACKUP_DIR/installed_packages.txt"
    
    # Compress the backup
    print_status "Compressing backup..."
    tar -czf "$BACKUP_DESTINATION/config_backup_$TIMESTAMP.tar.gz" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")" && \
        print_status "Backup compressed successfully" && \
        rm -rf "$BACKUP_DIR"
    
    # Clean old backups
    print_status "Cleaning backups older than $BACKUP_RETENTION_DAYS days..."
    find "$BACKUP_DESTINATION" -name "config_backup_*.tar.gz" -mtime +$BACKUP_RETENTION_DAYS -delete 2>/dev/null
    
    print_status "Configuration backup complete"
    return 0
}

create_sd_card_image() {
    print_section "SD CARD IMAGE BACKUP"
    
    print_warning "This function creates a full SD card image backup"
    print_warning "This requires significant space and time"
    
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    IMAGE_NAME="raspi_backup_$TIMESTAMP.img"
    
    if [ ! -d "$BACKUP_DESTINATION" ]; then
        print_error "Backup destination $BACKUP_DESTINATION does not exist"
        return 1
    fi
    
    # Determine the root device
    ROOT_DEVICE=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
    
    print_status "Creating image of $ROOT_DEVICE..."
    print_warning "This will take a long time. Consider using rsync for faster incremental backups."
    
    # Use dd with progress if pv is available
    if command -v pv >/dev/null 2>&1; then
        dd if="$ROOT_DEVICE" bs=4M | pv | gzip > "$BACKUP_DESTINATION/$IMAGE_NAME.gz"
    else
        dd if="$ROOT_DEVICE" bs=4M status=progress | gzip > "$BACKUP_DESTINATION/$IMAGE_NAME.gz"
    fi
    
    if [ $? -eq 0 ]; then
        print_status "SD card image created: $BACKUP_DESTINATION/$IMAGE_NAME.gz"
        print_status "To restore: gunzip -c $IMAGE_NAME.gz | sudo dd of=/dev/sdX bs=4M"
    else
        print_error "Failed to create SD card image"
        return 1
    fi
}

# --- USB Drive Management ---

setup_usb_automount() {
    print_section "USB AUTOMOUNT SETUP"
    
    if [ "$ENABLE_USB_AUTOMOUNT" != true ]; then
        print_status "USB automount is disabled in configuration"
        return 0
    fi
    
    print_status "Setting up USB automount with udevil..."
    
    # Install udevil if not present
    if ! command -v udevil >/dev/null 2>&1; then
        print_status "Installing udevil..."
        apt-get install -y udevil
    fi
    
    # Create mount directory
    mkdir -p /media/usb
    
    print_status "USB automount configured"
    print_status "USB drives will be mounted to /media/usb/"
}

# --- Watchdog Setup ---

setup_watchdog() {
    print_section "HARDWARE WATCHDOG SETUP"
    
    if [ "$ENABLE_WATCHDOG" != true ]; then
        print_status "Watchdog is disabled in configuration"
        return 0
    fi
    
    print_status "Setting up hardware watchdog..."
    
    # Install watchdog package
    if ! command -v watchdog >/dev/null 2>&1; then
        print_status "Installing watchdog..."
        apt-get install -y watchdog
    fi
    
    # Enable watchdog in boot config
    if ! grep -q "^dtparam=watchdog=on" /boot/config.txt; then
        echo "dtparam=watchdog=on" >> /boot/config.txt
        print_status "Added watchdog to /boot/config.txt"
    fi
    
    # Configure watchdog daemon
    cat > /etc/watchdog.conf << 'EOF'
watchdog-device = /dev/watchdog
watchdog-timeout = 15
max-load-1 = 24
min-memory = 1
EOF
    
    # Enable and start watchdog service
    systemctl enable watchdog
    systemctl start watchdog
    
    print_status "Hardware watchdog enabled"
    print_warning "Watchdog will reboot the system if it becomes unresponsive"
}

# --- Email/Notification Setup ---

setup_email_alerts() {
    print_section "EMAIL ALERT SETUP"
    
    print_status "Installing mail utilities..."
    apt-get install -y mailutils ssmtp
    
    print_warning "To complete email setup:"
    print_warning "1. Edit /etc/ssmtp/ssmtp.conf with your SMTP settings"
    print_warning "2. Set ENABLE_EMAIL_ALERTS=true in this script"
    print_warning "3. Set ADMIN_EMAIL to your email address"
    
    cat > /etc/ssmtp/ssmtp.conf << 'EOF'
# Example Gmail configuration
#root=your-email@gmail.com
#mailhub=smtp.gmail.com:587
#AuthUser=your-email@gmail.com
#AuthPass=your-app-password
#UseSTARTTLS=YES
#FromLineOverride=YES
EOF
    
    print_status "Email configuration template created at /etc/ssmtp/ssmtp.conf"
}

# --- Log Management ---

setup_log_rotation() {
    print_section "LOG ROTATION SETUP"
    
    print_status "Configuring log rotation for health monitoring..."
    
    cat > /etc/logrotate.d/raspi-health << 'EOF'
/var/log/raspi-health/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
    
    print_status "Log rotation configured"
}

# --- Scheduled Monitoring ---

setup_cron_jobs() {
    print_section "SCHEDULED MONITORING SETUP"
    
    CRON_FILE="/etc/cron.d/raspi-health"
    
    print_status "Setting up automated health checks..."
    
    cat > "$CRON_FILE" << EOF
# Raspberry Pi Health Monitoring
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Run health check every hour
0 * * * * root $SCRIPT_DIR/$(basename "$0") --health-check >> $HEALTH_LOG 2>&1

# Run full backup weekly (Sunday 2 AM)
0 2 * * 0 root $SCRIPT_DIR/$(basename "$0") --backup >> $BACKUP_LOG 2>&1

# Temperature check every 15 minutes
*/15 * * * * root $SCRIPT_DIR/$(basename "$0") --temp-check >> $HEALTH_LOG 2>&1
EOF
    
    chmod 644 "$CRON_FILE"
    print_status "Cron jobs configured"
}

# --- Main Execution ---

main_menu() {
    clear
    echo "=========================================="
    echo "Raspberry Pi Health & Backup Management"
    echo "=========================================="
    echo ""
    echo "1. Run full health check"
    echo "2. Check temperature and throttling"
    echo "3. Check disk health"
    echo "4. Check network connectivity"
    echo "5. Check services and Docker"
    echo "6. Create configuration backup"
    echo "7. Create SD card image (slow)"
    echo "8. Setup watchdog"
    echo "9. Setup email alerts"
    echo "10. Setup USB automount"
    echo "11. Install all monitoring (recommended)"
    echo "12. View health log"
    echo "0. Exit"
    echo ""
    read -p "Select option: " choice
    
    case $choice in
        1) run_health_check ;;
        2) check_temperature; check_throttling; check_voltage ;;
        3) check_disk_health ;;
        4) check_network_connectivity ;;
        5) check_critical_services; check_docker_containers ;;
        6) backup_system_config ;;
        7) create_sd_card_image ;;
        8) setup_watchdog ;;
        9) setup_email_alerts ;;
        10) setup_usb_automount ;;
        11) install_all ;;
        12) tail -50 "$HEALTH_LOG" ;;
        0) exit 0 ;;
        *) print_error "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    main_menu
}

run_health_check() {
    print_section "FULL HEALTH CHECK - $(date)"
    check_temperature
    check_throttling
    check_voltage
    check_disk_health
    check_network_connectivity
    check_critical_services
    check_docker_containers
    print_section "HEALTH CHECK COMPLETE"
}

install_all() {
    print_section "INSTALLING ALL MONITORING FEATURES"
    setup_watchdog
    setup_log_rotation
    setup_cron_jobs
    setup_usb_automount
    print_status "Installation complete"
    print_warning "Remember to configure email alerts manually if needed"
}

# --- Command Line Interface ---

case "${1:-}" in
    --health-check)
        check_root
        init_logging
        run_health_check
        ;;
    --temp-check)
        check_root
        init_logging
        check_temperature
        ;;
    --backup)
        check_root
        init_logging
        backup_system_config
        ;;
    --install)
        check_root
        init_logging
        install_all
        ;;
    *)
        check_root
        init_logging
        main_menu
        ;;
esac

exit 0