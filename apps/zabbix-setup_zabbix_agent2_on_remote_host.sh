#!/bin/bash

##############################
##  This script will setup already installed zabbix agent 2 on remote hosts
##  Script will ask for private key to get access to hosts
##  I assumed that there is the same user and port on all hosts, if not run script multiple times
##############################


### Input pre-config
PRIVATE_KEY=""
SSH_USER=""
PORT=""
ZABBIX_ADDRESS=""


echo "Warning: This script MUST be run from local host"
echo "Warning: You will be asked for path to SSH private key"
read -rp "Do you wish to continue? (y/N): " confirmation
if [[ "$confirmation" != "y" ]]; then
    echo "Operation canceled."
    exit 1
fi

echo "Enter IPs of all hosts to install Zabbix Agent on. Press ENTER when finished..."
# Remove the file if it exists
rm -f IP_LIST

while true; do
    read -p "IP: " IP
    # Break the loop if input is empty
    if [ -z "$IP" ]; then
        echo "No more IPs to add. Exiting."
        break
    fi
    # Append the IP to the file
    echo "$IP" >> IP_LIST
done

echo "The following IPs have been added to IP_LIST:"
cat IP_LIST

if [ -z "$PRIVATE_KEY" ]; then
    read -p "Enter path to private key: " PRIVATE_KEY
fi

if [ -z "$SSH_USER" ]; then
    read -p "Enter ssh user common for all hosts: " SSH_USER
fi

if [ -z "$PORT" ]; then
    read -p "Enter ssh port common for all hosts: " PORT
fi

if [ -z "$ZABBIX_ADDRESS" ]; then
    read -p "Enter zabbix proxy / server address (port): " ZABBIX_ADDRESS
fi

while IFS= read -r HOST; do
    if [ -n "$HOST" ]; then
        echo "Connecting to $HOST..."

        ssh -i "$PRIVATE_KEY" -p "$PORT" -o StrictHostKeyChecking=no $SSH_USER@$HOST "bash -s" <<EOF
#!/bin/bash

# Create required directory and set permissions
sudo mkdir -p /var/lib/zabbix > /dev/null 2>&1
sudo chown -R zabbix:zabbix /var/lib/zabbix

# Remove old config files
sudo rm -rf /etc/zabbix/*.conf

# Create new Zabbix Agent 2 config file
cat <<EOL | sudo tee /etc/zabbix/zabbix_agent2.conf
BufferSend=5
BufferSize=100
EnablePersistentBuffer=1
HostMetadata=linux
HostnameItem=system.hostname
PersistentBufferFile=/var/lib/zabbix/zabbix_agent2.db
PersistentBufferPeriod=30d
ControlSocket=/run/zabbix/agent.sock
Include=/etc/zabbix/zabbix_agent2.d/*.conf
Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
PidFile=/var/run/zabbix/zabbix_agent2.pid
PluginSocket=/run/zabbix/agent.plugin.sock
Timeout=10
DebugLevel=3
Server=0.0.0.0/0
ServerActive=${ZABBIX_ADDRESS}
EOL

sudo systemctl restart zabbix-agent2
if [ $? -eq 0 ]; then
    echo "Zabbix Agent restarted successfully on ${HOST}."
else
    echo "Failed to restart Zabbix Agent on ${HOST}."
fi
EOF

        if [ $? -eq 0 ]; then
            echo "Script executed successfully on $HOST."
        else
            echo "Failed to execute script on $HOST."
        fi
    fi
done < IP_LIST

echo "Done."
