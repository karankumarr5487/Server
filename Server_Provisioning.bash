```bash
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
# Verify Ubuntu
###################################################
if [ ! -f /etc/debian_version ]; then
    echo "This script is intended for Ubuntu systems only."
    exit 1
fi

###################################################
# Install Required Packages
###################################################
echo "Installing required packages..."

apt-get update -y
apt-get install -y \
    curl \
    wget \
    tar \
    sudo \
    ufw

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
usermod -aG sudo "$NEW_USER"

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

ufw allow ${SSH_PORT}/tcp
ufw allow 10050/tcp
ufw --force enable

###################################################
# Install Zabbix Agent 7.0
###################################################
echo "Installing Zabbix Agent..."

cd /tmp

wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-1+ubuntu24.04_all.deb

dpkg -i zabbix-release_7.0-1+ubuntu24.04_all.deb

apt-get update -y

apt-get install -y zabbix-agent

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

systemctl enable zabbix-agent
systemctl restart zabbix-agent

###################################################
# Cleanup
###################################################
rm -f /tmp/zabbix-release_7.0-1+ubuntu24.04_all.deb

###################################################
# Completed
###################################################
echo ""
echo "========================================="
echo "Provisioning Completed Successfully"
echo "========================================="
echo "SSH Port      : ${SSH_PORT}"
echo "Username      : ${NEW_USER}"
echo "User Password : ${NEW_USER_PASSWORD}"
echo "Root Password : ${ROOT_PASSWORD}"
echo "Timezone      : Asia/Kolkata"
echo "Zabbix Server : ${ZABBIX_SERVER}"
echo "========================================="
```
