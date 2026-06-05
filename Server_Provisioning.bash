#!/bin/bash

set -e

SSH_PORT="62247"
NODE_EXPORTER_PORT="9100"
NEW_USER="netadmin"
NEW_USER_PASSWORD='&*ujfjf9JU9if9' 

ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

echo "Starting server provisioning..."

###################################################
# 1. Install Pre-requisites (curl, tar, and dos2unix)
###################################################
echo "Checking and installing pre-requisites..."

if [ -f /etc/debian_version ]; then
    apt-get update -y
    for pkg in curl tar dos2unix; do
        if ! command -v $pkg >/dev/null 2>&1; then
            apt-get install -y $pkg
        fi
    done
else
    for pkg in curl tar dos2unix; do
        if ! command -v $pkg >/dev/null 2>&1; then
            dnf install -y $pkg || yum install -y $pkg
        fi
    done
fi

# Self-heal line endings dynamically in case of Windows copy-paste issues
dos2unix "$0" >/dev/null 2>&1 || true
chmod +x "$0"

###################################################
# Timezone
###################################################
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Kolkata || true
fi

###################################################
# Disable SELinux
###################################################
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    if command -v setenforce >/dev/null 2>&1; then
        setenforce 0 || true
    fi
fi

###################################################
# Create User & Set Passwords
###################################################
if ! id "$NEW_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$NEW_USER"
fi

echo "${NEW_USER}:${NEW_USER_PASSWORD}" | chpasswd
echo "root:${ROOT_PASSWORD}" | chpasswd

###################################################
# Configure SSH Port & Validate
###################################################
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.pre-prov
sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config

if sshd -t >/dev/null 2>&1; then
    echo "SSH configuration validated successfully. Restarting sshd..."
    systemctl restart sshd || systemctl restart ssh || true
else
    echo "Invalid SSH configuration! Restoring backup."
    cp /etc/ssh/sshd_config.pre-prov /etc/ssh/sshd_config
fi

###################################################
# Firewall Rules
###################################################
if [ -f /etc/debian_version ]; then
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y ufw
    fi
    ufw allow ${SSH_PORT}/tcp
    ufw allow ${NODE_EXPORTER_PORT}/tcp
    ufw --force enable

elif [ -f /etc/redhat-release ]; then
    if ! rpm -q firewalld >/dev/null 2>&1; then
        dnf install -y firewalld || yum install -y firewalld
    fi
    systemctl enable firewalld --now
    firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    firewall-cmd --permanent --add-port=${NODE_EXPORTER_PORT}/tcp
    firewall-cmd --reload
fi

###################################################
# Create graf.bash
###################################################
cat > /home/${NEW_USER}/graf.bash << 'EOF'
#!/bin/bash

adding_firewall_rules(){
    if [ -f /etc/debian_version ]; then
        echo -e "Debian-based system detected. Updating UFW..."
        ufw allow "$port"/tcp
    elif [ -f /etc/redhat-release ] || { [ -f /etc/os-release ] && grep -qi "suse" /etc/os-release; }; then
        echo -e "RedHat/Suse-based system detected. Updating Firewalld..."
        firewall-cmd --permanent --add-port="$port"/tcp && firewall-cmd --reload
    else
        echo -e "Unknown firewall setup. Skipping automated rule addition..."
    fi
}

node_exporter(){
    url="https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz"
    
    mkdir -p /etc/node_exporter
    cd /etc/node_exporter

    curl -L -o node_exporter.tar.gz "$url"
    tar -zxvf node_exporter.tar.gz --strip-components=1
    rm -f node_exporter.tar.gz

    cat > restart_scripts << 'EOS'
#!/bin/bash
pkill -x node_exporter || true 
/etc/node_exporter/node_exporter > /dev/null 2>&1 &
EOS

    chmod +x restart_scripts
    ./restart_scripts

    port=9100
    adding_firewall_rules
}

blackbox_exporter(){
    url="https://github.com/prometheus/blackbox_exporter/releases/download/v0.25.0/blackbox_exporter-0.25.0.linux-amd64.tar.gz"
    
    mkdir -p /etc/blackbox_exporter
    cd /etc/blackbox_exporter

    curl -L -o blackbox_exporter.tar.gz "$url"
    tar -zxvf blackbox_exporter.tar.gz --strip-components=1
    rm -f blackbox_exporter.tar.gz

    cat > restart_scripts << 'EOS'
#!/bin/bash
pkill -x blackbox_exporter || true
/etc/blackbox_exporter/blackbox_exporter --config.file=/etc/blackbox_exporter/blackbox.yml > /dev/null 2>&1 &
EOS

    chmod +x restart_scripts
    ./restart_scripts

    port=9115
    adding_firewall_rules
}

if [ "$1" == "node_exporter" ]; then
    node_exporter
elif [ "$1" == "blackbox_exporter" ]; then
    blackbox_exporter
fi
EOF

# Standardize line endings inside generated inner file too
dos2unix /home/${NEW_USER}/graf.bash >/dev/null 2>&1 || true
chmod +x /home/${NEW_USER}/graf.bash
chown ${NEW_USER}:${NEW_USER} /home/${NEW_USER}/graf.bash

###################################################
# Execute graf.bash & Setup Cron
###################################################
bash /home/${NEW_USER}/graf.bash node_exporter

(
crontab -l 2>/dev/null | grep -v "/etc/node_exporter/restart_scripts" || true
echo "@reboot /bin/bash /etc/node_exporter/restart_scripts"
) | crontab -

###################################################
# Clear History Traces
###################################################
history -c 2>/dev/null || true
history -w 2>/dev/null || true

unset HISTFILE
export HISTSIZE=0
export HISTFILESIZE=0

rm -f /root/.bash_history
rm -f /home/${NEW_USER}/.bash_history

###################################################
# Final Output
###################################################
echo ""
echo "========================================="
echo "Provisioning Completed Safely"
echo "========================================="
echo "SSH Port      : ${SSH_PORT}"
echo "Username      : ${NEW_USER}"
echo "User Password : ${NEW_USER_PASSWORD}"
echo "Root Password : ${ROOT_PASSWORD}"
echo "Timezone      : Asia/Kolkata"
echo "========================================="