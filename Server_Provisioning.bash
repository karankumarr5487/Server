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
if [ -f /etc/debian_version ]; then
    OS_FAMILY="debian"
elif [ -f /etc/almalinux-release ] || grep -qi "alma" /etc/os-release 2>/dev/null; then
    OS_FAMILY="rhel"
else
    echo "This script supports Ubuntu (Debian-based) and AlmaLinux only."
    exit 1
fi

echo "Detected OS family: ${OS_FAMILY}"

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
    wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-1+ubuntu24.04_all.deb
    dpkg -i zabbix-release_7.0-1+ubuntu24.04_all.deb
    apt-get update -y
    apt-get install -y zabbix-agent
else
    # AlmaLinux 9 release package; adjust the "9" below if you're on AlmaLinux 8
    rpm -Uvh https://repo.zabbix.com/zabbix/7.0/rhel/9/x86_64/zabbix-release-latest-7.0.el9.noarch.rpm
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
rm -f /tmp/zabbix-release_7.0-1+ubuntu24.04_all.deb 2>/dev/null || true
rm -f /tmp/zabbix-release-latest-7.0.el9.noarch.rpm 2>/dev/null || true

###################################################
# Completed
###################################################
echo ""
echo "========================================="
echo "Provisioning Completed Successfully"
echo "========================================="
echo "OS Family     : ${OS_FAMILY}"
echo "SSH Port      : ${SSH_PORT}"
echo "Username      : ${NEW_USER}"
echo "User Password : ${NEW_USER_PASSWORD}"
echo "Root Password : ${ROOT_PASSWORD}"
echo "Timezone      : Asia/Kolkata"
echo "Zabbix Server : ${ZABBIX_SERVER}"
echo "========================================="
