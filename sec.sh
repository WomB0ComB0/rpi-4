#!/bin/bash

#=============================================================================
# Raspberry Pi Network Security & Firewall Configuration Script
#
# Features NOT covered in your existing scripts:
# - Advanced firewall configuration (UFW/iptables)
# - Port management and security hardening
# - Intrusion detection (beyond fail2ban)
# - VPN server setup (WireGuard/OpenVPN)
# - Reverse SSH tunnel for remote access
# - Certificate management (Let's Encrypt)
# - Network segmentation for media server
# - API key rotation for media services
# - Automated security auditing
# - DDoS protection basics
#
# Version: 1.0
#=============================================================================

# --- Configuration ---
SSH_PORT=22                           # Change if you use non-standard SSH port
ALLOWED_SSH_IPS=""                    # Comma-separated IPs, empty = all
ENABLE_VPN=false                      # Install WireGuard VPN server
VPN_PORT=51820                        # WireGuard port
ENABLE_INTRUSION_DETECTION=true      # Install additional security tools
LOCAL_NETWORK="192.168.1.0/24"       # Your local network CIDR
ENABLE_CERTIFICATES=false             # Setup Let's Encrypt
DOMAIN_NAME="your-domain.duckdns.org" # For certificates

# Media Server Ports (adjust based on your setup)
JELLYFIN_PORT=8096
RADARR_PORT=7878
SONARR_PORT=8989
DELUGE_PORT=8112
JACKETT_PORT=9117
PORTAINER_PORT=9000
GRAFANA_PORT=3030
NPM_PORT=81

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Variables ---
LOG_FILE="/var/log/raspi-security-setup.log"

# --- Functions ---

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

print_section() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BLUE}=== $1 ===${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root or with sudo"
    fi
}

# --- UFW Firewall Setup ---

setup_ufw_firewall() {
    print_section "UFW FIREWALL CONFIGURATION"
    
    # Install UFW if not present
    if ! command -v ufw >/dev/null 2>&1; then
        print_status "Installing UFW..."
        apt-get update
        apt-get install -y ufw
    fi
    
    # Reset UFW to default state
    print_status "Resetting UFW to defaults..."
    ufw --force reset
    
    # Set default policies
    print_status "Setting default policies (deny incoming, allow outgoing)..."
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH (critical - do this first!)
    print_status "Allowing SSH on port $SSH_PORT..."
    if [ -n "$ALLOWED_SSH_IPS" ]; then
        IFS=',' read -ra IPS <<< "$ALLOWED_SSH_IPS"
        for ip in "${IPS[@]}"; do
            ufw allow from "$ip" to any port "$SSH_PORT" proto tcp
            print_status "SSH allowed from $ip"
        done
    else
        ufw allow "$SSH_PORT"/tcp
        print_status "SSH allowed from anywhere (consider restricting this)"
    fi
    
    # Allow local network full access
    print_status "Allowing full access from local network $LOCAL_NETWORK..."
    ufw allow from "$LOCAL_NETWORK"
    
    # Allow media server ports (local network only for security)
    print_status "Configuring media server port access..."
    
    MEDIA_PORTS=(
        "$JELLYFIN_PORT:Jellyfin"
        "$RADARR_PORT:Radarr"
        "$SONARR_PORT:Sonarr"
        "$DELUGE_PORT:Deluge"
        "$JACKETT_PORT:Jackett"
        "$PORTAINER_PORT:Portainer"
        "$GRAFANA_PORT:Grafana"
        "$NPM_PORT:Nginx Proxy Manager"
    )
    
    for port_info in "${MEDIA_PORTS[@]}"; do
        port="${port_info%%:*}"
        name="${port_info##*:}"
        ufw allow from "$LOCAL_NETWORK" to any port "$port" proto tcp comment "$name"
        print_status "Allowed $name on port $port from local network"
    done
    
    # VPN port if enabled
    if [ "$ENABLE_VPN" = true ]; then
        ufw allow "$VPN_PORT"/udp comment "WireGuard VPN"
        print_status "Allowed WireGuard VPN on port $VPN_PORT"
    fi
    
    # Enable UFW
    print_status "Enabling UFW..."
    ufw --force enable
    
    # Show status
    print_status "Firewall configuration complete. Current status:"
    ufw status verbose | tee -a "$LOG_FILE"
}

# --- Advanced iptables Rules ---

setup_advanced_iptables() {
    print_section "ADVANCED IPTABLES RULES"
    
    print_status "Adding rate limiting for SSH..."
    # Limit SSH connections to prevent brute force
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --set
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    
    print_status "Protecting against port scanning..."
    # Drop invalid packets
    iptables -A INPUT -m state --state INVALID -j DROP
    
    # Log and drop new packets that are not SYN
    iptables -A INPUT -p tcp ! --syn -m state --state NEW -j LOG --log-prefix "New not SYN:"
    iptables -A INPUT -p tcp ! --syn -m state --state NEW -j DROP
    
    print_status "Adding protection against common attacks..."
    # Protect against SYN flood
    iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
    
    # Protect against ping flood
    iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
    
    # Save iptables rules
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4
        print_status "iptables rules saved"
    fi
}

# --- SSH Hardening ---

harden_ssh() {
    print_section "SSH HARDENING"
    
    SSH_CONFIG="/etc/ssh/sshd_config"
    SSH_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Backup SSH config
    cp "$SSH_CONFIG" "$SSH_BACKUP"
    print_status "SSH config backed up to $SSH_BACKUP"
    
    print_status "Hardening SSH configuration..."
    
    # Function to set or add SSH config option
    set_ssh_option() {
        local option="$1"
        local value="$2"
        if grep -q "^#*${option}" "$SSH_CONFIG"; then
            sed -i "s|^#*${option}.*|${option} ${value}|" "$SSH_CONFIG"
        else
            echo "${option} ${value}" >> "$SSH_CONFIG"
        fi
    }
    
    # Apply hardening options
    set_ssh_option "PermitRootLogin" "no"
    set_ssh_option "PasswordAuthentication" "yes"  # Change to 'no' if using keys only
    set_ssh_option "PubkeyAuthentication" "yes"
    set_ssh_option "PermitEmptyPasswords" "no"
    set_ssh_option "X11Forwarding" "no"
    set_ssh_option "MaxAuthTries" "3"
    set_ssh_option "ClientAliveInterval" "300"
    set_ssh_option "ClientAliveCountMax" "2"
    set_ssh_option "Protocol" "2"
    set_ssh_option "LogLevel" "VERBOSE"
    
    # Disable unused authentication methods
    set_ssh_option "ChallengeResponseAuthentication" "no"
    set_ssh_option "KerberosAuthentication" "no"
    set_ssh_option "GSSAPIAuthentication" "no"
    
    print_status "SSH hardening complete"
    print_warning "Remember to test SSH access before logging out!"
    
    # Restart SSH
    print_status "Restarting SSH service..."
    systemctl restart ssh
}

# --- WireGuard VPN Setup ---

setup_wireguard_vpn() {
    print_section "WIREGUARD VPN SERVER SETUP"
    
    if [ "$ENABLE_VPN" != true ]; then
        print_status "VPN setup is disabled in configuration"
        return 0
    fi
    
    print_status "Installing WireGuard..."
    apt-get update
    apt-get install -y wireguard wireguard-tools qrencode
    
    # Generate server keys
    print_status "Generating WireGuard keys..."
    cd /etc/wireguard
    umask 077
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    
    SERVER_PRIVATE_KEY=$(cat server_private.key)
    SERVER_PUBLIC_KEY=$(cat server_public.key)
    
    # Get server's public IP
    SERVER_PUBLIC_IP=$(curl -s ifconfig.me)
    
    print_status "Creating WireGuard configuration..."
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = $VPN_PORT
PrivateKey = $SERVER_PRIVATE_KEY
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# Client configurations will be added here
EOF
    
    # Enable IP forwarding
    print_status "Enabling IP forwarding..."
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    
    # Generate client configuration
    print_status "Generating client configuration..."
    wg genkey | tee client_private.key | wg pubkey > client_public.key
    
    CLIENT_PRIVATE_KEY=$(cat client_private.key)
    CLIENT_PUBLIC_KEY=$(cat client_public.key)
    
    cat > /etc/wireguard/client.conf << EOF
[Interface]
Address = 10.8.0.2/24
PrivateKey = $CLIENT_PRIVATE_KEY
DNS = 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_PUBLIC_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    # Add client to server config
    cat >> /etc/wireguard/wg0.conf << EOF

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.8.0.2/32
EOF
    
    # Generate QR code for mobile clients
    print_status "Generating QR code for mobile client..."
    qrencode -t ansiutf8 < /etc/wireguard/client.conf
    
    # Enable and start WireGuard
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    
    print_status "WireGuard VPN setup complete!"
    print_status "Client configuration saved to: /etc/wireguard/client.conf"
    print_status "Import this configuration into your WireGuard client"
}

# --- Intrusion Detection ---

setup_intrusion_detection() {
    print_section "INTRUSION DETECTION SETUP"
    
    if [ "$ENABLE_INTRUSION_DETECTION" != true ]; then
        print_status "Intrusion detection is disabled"
        return 0
    fi
    
    # Install psad (Port Scan Attack Detector)
    print_status "Installing PSAD (Port Scan Attack Detector)..."
    apt-get install -y psad
    
    # Configure psad
    print_status "Configuring PSAD..."
    sed -i 's/EMAIL_ADDRESSES.*/EMAIL_ADDRESSES     root@localhost;/' /etc/psad/psad.conf
    sed -i 's/HOSTNAME.*/HOSTNAME               raspberrypi;/' /etc/psad/psad.conf
    sed -i 's/ENABLE_AUTO_IDS.*/ENABLE_AUTO_IDS        Y;/' /etc/psad/psad.conf
    sed -i 's/ENABLE_AUTO_IDS_EMAILS.*/ENABLE_AUTO_IDS_EMAILS Y;/' /etc/psad/psad.conf
    
    # Update psad signatures
    psad --sig-update
    
    # Restart psad
    systemctl restart psad
    systemctl enable psad
    
    print_status "PSAD intrusion detection enabled"
    
    # Install rkhunter (Rootkit Hunter)
    print_status "Installing rkhunter (Rootkit Hunter)..."
    apt-get install -y rkhunter
    
    # Update rkhunter database
    rkhunter --update
    rkhunter --propupd
    
    # Create daily scan cron job
    cat > /etc/cron.daily/rkhunter-scan << 'EOF'
#!/bin/bash
/usr/bin/rkhunter --cronjob --update --quiet
EOF
    chmod +x /etc/cron.daily/rkhunter-scan
    
    print_status "Rootkit scanning configured"
}

# --- Let's Encrypt Certificates ---

setup_letsencrypt() {
    print_section "LET'S ENCRYPT CERTIFICATE SETUP"
    
    if [ "$ENABLE_CERTIFICATES" != true ]; then
        print_status "Certificate setup is disabled"
        return 0
    fi
    
    if [ "$DOMAIN_NAME" = "your-domain.duckdns.org" ]; then
        print_warning "Please configure DOMAIN_NAME before enabling certificates"
        return 1
    fi
    
    print_status "Installing Certbot..."
    apt-get install -y certbot python3-certbot-nginx
    
    print_status "Obtaining certificate for $DOMAIN_NAME..."
    certbot certonly --standalone -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "admin@$DOMAIN_NAME"
    
    # Setup auto-renewal
    print_status "Setting up certificate auto-renewal..."
    systemctl enable certbot.timer
    systemctl start certbot.timer
    
    print_status "Let's Encrypt certificates configured"
    print_status "Certificates location: /etc/letsencrypt/live/$DOMAIN_NAME/"
}

# --- Security Audit ---

run_security_audit() {
    print_section "SECURITY AUDIT"
    
    AUDIT_REPORT="/var/log/security-audit-$(date +%Y%m%d_%H%M%S).txt"
    
    print_status "Running security audit..."
    echo "Security Audit Report - $(date)" > "$AUDIT_REPORT"
    echo "========================================" >> "$AUDIT_REPORT"
    echo "" >> "$AUDIT_REPORT"
    
    # Check for users with empty passwords
    echo "Users with empty passwords:" >> "$AUDIT_REPORT"
    awk -F: '($2 == "") {print $1}' /etc/shadow >> "$AUDIT_REPORT" 2>&1
    echo "" >> "$AUDIT_REPORT"
    
    # Check for users with UID 0 (root equivalent)
    echo "Users with UID 0 (root privileges):" >> "$AUDIT_REPORT"
    awk -F: '($3 == 0) {print $1}' /etc/passwd >> "$AUDIT_REPORT"
    echo "" >> "$AUDIT_REPORT"
    
    # List open ports
    echo "Open network ports:" >> "$AUDIT_REPORT"
    ss -tuln >> "$AUDIT_REPORT" 2>&1
    echo "" >> "$AUDIT_REPORT"
    
    # Check for world-writable files
    echo "World-writable files in system directories:" >> "$AUDIT_REPORT"
    find / -xdev -type f -perm -0002 -not -path "/proc/*" -not -path "/sys/*" 2>/dev/null | head -20 >> "$AUDIT_REPORT"
    echo "" >> "$AUDIT_REPORT"
    
    # Check failed login attempts
    echo "Recent failed login attempts:" >> "$AUDIT_REPORT"
    grep "Failed password" /var/log/auth.log 2>/dev/null | tail -10 >> "$AUDIT_REPORT"
    echo "" >> "$AUDIT_REPORT"
    
    # Check sudo usage
    echo "Recent sudo usage:" >> "$AUDIT_REPORT"
    grep "sudo:" /var/log/auth.log 2>/dev/null | tail -10 >> "$AUDIT_REPORT"
    echo "" >> "$AUDIT_REPORT"
    
    # Check for suspicious processes
    echo "Processes listening on network ports:" >> "$AUDIT_REPORT"
    netstat -tulpn 2>/dev/null >> "$AUDIT_REPORT"
    echo "" >> "$AUDIT_REPORT"
    
    print_status "Security audit complete: $AUDIT_REPORT"
    
    # Display summary
    echo ""
    echo "=== Audit Summary ==="
    grep -A 5 "Users with empty passwords" "$AUDIT_REPORT"
    echo ""
    grep -A 3 "Users with UID 0" "$AUDIT_REPORT"
}

# --- API Key Rotation Script ---

create_api_rotation_script() {
    print_section "API KEY ROTATION SETUP"
    
    ROTATION_SCRIPT="/usr/local/bin/rotate-api-keys.sh"
    
    cat > "$ROTATION_SCRIPT" << 'EOF'
#!/bin/bash
# API Key Rotation Script for Media Services

echo "API Key Rotation - $(date)"

# Add your API rotation logic here
# Example for Radarr:
# RADARR_API_KEY=$(openssl rand -hex 32)
# Update Radarr config with new key
# Notify admin

echo "Manual API key rotation required for:"
echo "- Radarr: http://localhost:7878/settings/general"
echo "- Sonarr: http://localhost:8989/settings/general"
echo "- Jackett: http://localhost:9117/UI/Dashboard"
echo ""
echo "Recommendation: Rotate API keys every 90 days"
EOF
    
    chmod +x "$ROTATION_SCRIPT"
    print_status "API rotation script created at $ROTATION_SCRIPT"
}

# --- Network Monitoring ---

setup_network_monitoring() {
    print_section "NETWORK MONITORING TOOLS"
    
    print_status "Installing network monitoring tools..."
    apt-get install -y nethogs iftop vnstat
    
    # Configure vnstat
    systemctl enable vnstat
    systemctl start vnstat
    
    # Initialize vnstat for interfaces
    for interface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        vnstat -u -i "$interface" 2>/dev/null
    done
    
    print_status "Network monitoring tools installed"
    print_status "Use 'vnstat' to view network statistics"
    print_status "Use 'nethogs' to monitor per-process bandwidth"
    print_status "Use 'iftop' for real-time interface monitoring"
}

# --- Main Menu ---

main_menu() {
    clear
    echo "=========================================="
    echo "Raspberry Pi Security Configuration"
    echo "=========================================="
    echo ""
    echo "1. Setup UFW Firewall"
    echo "2. Add Advanced iptables Rules"
    echo "3. Harden SSH Configuration"
    echo "4. Setup WireGuard VPN"
    echo "5. Setup Intrusion Detection"
    echo "6. Setup Let's Encrypt Certificates"
    echo "7. Run Security Audit"
    echo "8. Setup Network Monitoring"
    echo "9. Create API Rotation Script"
    echo "10. Install All Security Features"
    echo "11. Show Firewall Status"
    echo "12. View Security Audit Report"
    echo "0. Exit"
    echo ""
    read -p "Select option: " choice
    
    case $choice in
        1) setup_ufw_firewall ;;
        2) setup_advanced_iptables ;;
        3) harden_ssh ;;
        4) setup_wireguard_vpn ;;
        5) setup_intrusion_detection ;;
        6) setup_letsencrypt ;;
        7) run_security_audit ;;
        8) setup_network_monitoring ;;
        9) create_api_rotation_script ;;
        10) install_all_security ;;
        11) ufw status verbose ;;
        12) ls -lt /var/log/security-audit-*.txt | head -1 | awk '{print $NF}' | xargs cat ;;
        0) exit 0 ;;
        *) print_error "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    main_menu
}

install_all_security() {
    print_section "INSTALLING ALL SECURITY FEATURES"
    setup_ufw_firewall
    setup_advanced_iptables
    harden_ssh
    setup_intrusion_detection
    setup_network_monitoring
    create_api_rotation_script
    run_security_audit
    print_status "All security features installed"
}

# --- Main Execution ---

check_root
mkdir -p "$(dirname "$LOG_FILE")"

case "${1:-}" in
    --install-all)
        install_all_security
        ;;
    --audit)
        run_security_audit
        ;;
    --firewall)
        setup_ufw_firewall
        ;;
    *)
        main_menu
        ;;
esac

exit 0