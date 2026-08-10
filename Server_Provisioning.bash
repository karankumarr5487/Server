#!/bin/bash

set -e

SSH_PORT="62247"
NEW_USER="netadmin"
NEW_USER_PASSWORD='&*ujfjf9JU9if9'
ZABBIX_SERVER="160.25.62.70"

ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

echo "========================================="
echo "Starting Server Provisioning..."
echo "========================================="

###################################################
# Detect OS
###################################################
if [ -f /etc/os-release ]; then
    . /etc/os-release
fi

if [ -f /etc/debian_version ]; then
    OS_FAMILY="debian"
    OS_VERSION="${VERSION_ID:-}"

    case "$OS_VERSION" in
        20.04|22.04|24.04)
            ;;
        *)
            echo "This script supports Ubuntu 20.04, 22.04, and 24.04 only."
            echo "Detected Ubuntu version: ${OS_VERSION:-unknown}"
            exit 1
            ;;
    esac
elif [ -f /etc/almalinux-release ] || grep -qi "alma" /etc/os-release 2>/dev/null; then
    OS_FAMILY="rhel"
    # VERSION_ID for AlmaLinux is like "8.10" or "9.4"; keep only the major version
    OS_VERSION="${VERSION_ID%%.*}"

    case "$OS_VERSION" in
        8|9)
            ;;
        *)
            echo "This script supports AlmaLinux 8 and 9 only."
            echo "Detected AlmaLinux version: ${VERSION_ID:-unknown}"
            exit 1
            ;;
    esac
else
    echo "This script supports Ubuntu (20.04/22.04/24.04) and AlmaLinux (8/9) only."
    exit 1
fi

echo "Detected OS family : ${OS_FAMILY}"
echo "Detected OS version: ${OS_VERSION}"

###################################################
# Install Required Packages
###################################################
echo "Installing required packages..."

if [ "$OS_FAMILY" = "debian" ]; then
    apt-get update -y
    apt-get install -y curl wget tar sudo ufw
else
    dnf install -y curl wget tar sudo firewalld
    systemctl enable --now firewalld
fi

###################################################
# Set Timezone
###################################################
echo "Setting timezone..."
timedatectl set-timezone Asia/Kolkata || true

###################################################
# Create User
###################################################
echo "Creating user..."

if ! id "$NEW_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$NEW_USER"
fi

echo "${NEW_USER}:${NEW_USER_PASSWORD}" | chpasswd
echo "root:${ROOT_PASSWORD}" | chpasswd

###################################################
# Grant Sudo Privileges
###################################################
if [ "$OS_FAMILY" = "debian" ]; then
    usermod -aG sudo "$NEW_USER"
else
    usermod -aG wheel "$NEW_USER"
fi

cat >/etc/sudoers.d/${NEW_USER} <<EOF
${NEW_USER} ALL=(ALL) NOPASSWD: ALL
EOF

chmod 440 /etc/sudoers.d/${NEW_USER}
visudo -cf /etc/sudoers.d/${NEW_USER}

###################################################
# Configure SSH
###################################################
echo "Configuring SSH..."

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config

if [ "$OS_FAMILY" = "rhel" ]; then
    # AlmaLinux SSH often needs SELinux updated for a non-standard port
    if command -v semanage >/dev/null 2>&1; then
        semanage port -a -t ssh_port_t -p tcp ${SSH_PORT} 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp ${SSH_PORT} 2>/dev/null || true
    else
        dnf install -y policycoreutils-python-utils
        semanage port -a -t ssh_port_t -p tcp ${SSH_PORT} 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp ${SSH_PORT} 2>/dev/null || true
    fi
fi

if sshd -t >/dev/null 2>&1; then
    systemctl restart ssh || systemctl restart sshd
else
    echo "SSH configuration invalid. Restoring backup..."
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
fi

###################################################
# Configure Firewall
###################################################
echo "Configuring firewall..."

if [ "$OS_FAMILY" = "debian" ]; then
    ufw allow ${SSH_PORT}/tcp
    ufw allow 10050/tcp
    ufw --force enable
else
    firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    firewall-cmd --permanent --add-port=10050/tcp
    firewall-cmd --reload
fi

###################################################
# Install Zabbix Agent 7.0
###################################################
echo "Installing Zabbix Agent..."

cd /tmp

if [ "$OS_FAMILY" = "debian" ]; then
    ZABBIX_DEB="zabbix-release_7.0-1+ubuntu${OS_VERSION}_all.deb"
    wget "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/${ZABBIX_DEB}"
    dpkg -i "${ZABBIX_DEB}"
    apt-get update -y
    apt-get install -y zabbix-agent
else
    ZABBIX_RPM="zabbix-release-latest-7.0.el${OS_VERSION}.noarch.rpm"
    rpm -Uvh "https://repo.zabbix.com/zabbix/7.0/rhel/${OS_VERSION}/x86_64/${ZABBIX_RPM}"
    dnf clean all
    dnf install -y zabbix-agent
fi

###################################################
# Configure Zabbix Agent
###################################################
echo "Configuring Zabbix Agent..."

sed -i "s/^Server=.*/Server=${ZABBIX_SERVER}/" /etc/zabbix/zabbix_agentd.conf

if grep -q "^ServerActive=" /etc/zabbix/zabbix_agentd.conf; then
    sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER}/" /etc/zabbix/zabbix_agentd.conf
else
    echo "ServerActive=${ZABBIX_SERVER}" >> /etc/zabbix/zabbix_agentd.conf
fi

if grep -q "^Hostname=" /etc/zabbix/zabbix_agentd.conf; then
    sed -i "s/^Hostname=.*/Hostname=$(hostname)/" /etc/zabbix/zabbix_agentd.conf
else
    echo "Hostname=$(hostname)" >> /etc/zabbix/zabbix_agentd.conf
fi

if [ "$OS_FAMILY" = "rhel" ]; then
    # SELinux: allow zabbix agent to run user-defined/remote checks if needed
    setsebool -P zabbix_can_network on 2>/dev/null || true
fi

systemctl enable zabbix-agent
systemctl restart zabbix-agent

###################################################
# Cleanup
###################################################
if [ "$OS_FAMILY" = "debian" ]; then
    rm -f "/tmp/${ZABBIX_DEB}" 2>/dev/null || true
else
    rm -f "/tmp/${ZABBIX_RPM}" 2>/dev/null || true
fi

###################################################
# Completed
###################################################
echo ""
echo "========================================="
echo "Provisioning Completed Successfully"
echo "========================================="
echo "OS Family     : ${OS_FAMILY}"
echo "OS Version    : ${OS_VERSION}"
echo "SSH Port      : ${SSH_PORT}"
echo "Username      : ${NEW_USER}"
echo "User Password : ${NEW_USER_PASSWORD}"
echo "Root Password : ${ROOT_PASSWORD}"
echo "Timezone      : Asia/Kolkata"
echo "Zabbix Server : ${ZABBIX_SERVER}"
echo "========================================="
